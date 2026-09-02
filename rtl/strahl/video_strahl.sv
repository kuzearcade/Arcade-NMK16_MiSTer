// strahl-family (Family B/macross) video pipeline — the fourth Tier 2
// NMK004-board game to get a real video pipeline, after
// rtl/mustang/video_mustang.sv, rtl/bioship/video_bioship.sv, and
// rtl/blkheart/video_blkheart.sv (those modules' own headers cover the
// shared tile-decode/palette/sprite-FSM architecture in full; this
// header only covers what's genuinely different for strahl).
//
// strahl's own 3-layer shape (BG0 opaque + BG1 transparent + TX
// transparent, then sprites) is the SAME compositing structure bioship
// established (`screen_update_strahl` — literally the same MAME
// function name both games use, not a coincidence), but strahl is
// simpler in one real way: **both BG layers are plain VRAM tilemaps**
// (`VIDEO_START_MEMBER(nmk16_state,strahl)`: `VIDEO_START_CALL_MEMBER
// (macross)` for BG0, then a second `common_get_bg_tile_info<1,3>`
// tilemap for BG1) — no ROM-tile-index/bank-select complexity at all
// (bioship's own BG0 is ROM-based; strahl has no `tilerom`, no
// `bioship_bank_w`-equivalent register). Real differences from
// video_bioship.sv:
//
//   - BG0 reads from live VRAM (`bg0vram_addr`/`bg0vram_data`, fed by
//     strahl_core.sv's own `bg0vram` array) instead of a static
//     `tilerom` — same page-mapped 16x16/256x32 addressing math as
//     every prior BG layer, just no ROM-lookup/bank-select stage.
//   - Different GFXDECODE color bases (`gfx_strahl`): TX(fgtile)=0x000,
//     BG0(bgtile)=0x300, sprites=0x100, BG1(bg2tile)=0x200 — all four
//     different from bioship's own `gfx_bioship` bases, confirmed
//     directly from the source rather than assumed to match.
//   - Sprite RAM lives at mainram *word* offset 0x7800 here
//     (`m_sprdma_base=0xf000` bytes, set in `VIDEO_START_MEMBER
//     (strahl)`), not the family's usual 0x4000 (`m_sprdma_base`'s own
//     default, 0x8000 bytes) — the sprite-snapshot FSM's own
//     `mainram_addr` base constant reflects this.
//   - Graphics ROM sizes are all genuinely different from bioship's own
//     (fgtile 0x20000 declared/0x10000 populated — same half-populated
//     pattern as bioship's; bgtile 0x40000; bg2tile 0x80000; sprites
//     0x180000, three plain-concatenated 0x80000 chips rather than
//     bioship's single one) — array sizes and truncation widths sized
//     accordingly, same `group16_pixel()`/`fgtile_pixel()` addressing
//     functions otherwise unchanged (nmk16spr.cpp's own sprite `code`
//     field is a full 16-bit value regardless of ROM size, so the
//     bigger sprite ROM here needs no functional changes, just a wider
//     truncation).
//
// Everything else — tile-decode functions, palette-decode, sprite
// double-buffer delay (same double-snapshot-buffer technique, just a
// different mainram base offset), sprite draw FSM, TX-over-sprite-over-
// BG1-over-BG0 compositing order, and screen geometry (SCREEN_W/H,
// VIDEOSHIFT=92, MAX_SPRITE_CLOCK=134656 — strahl calls the exact same
// `set_screen_lowres`/`set_max_sprite_clock(384*263)` helpers every
// prior port's own machine config does) — is unchanged from
// video_bioship.sv. See that module's own header (and video_mustang.sv's,
// for the base architecture) for their full derivation, not repeated here.
module video_strahl #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter BG2TILE_FILE = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger, // from nmk_irq_hacky: snapshot sprite RAM now

	// register/RAM read ports into strahl_core's storage (dual-tap
	// reads, strahl_core owns the arrays — see mustang_core.sv's own
	// header for why)
	output [12:0] bg0vram_addr,
	input  [15:0] bg0vram_data,
	output [12:0] bg1vram_addr,
	input  [15:0] bg1vram_data,
	output [9:0]  txvram_addr,
	input  [15:0] txvram_data,
	output [9:0]  palette_addr,     // tile-plane palette tap (live, per-pixel)
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only, see header)
	input  [15:0] spr_palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,

	input [15:0] bg0_xscroll, bg0_yscroll,
	input [15:0] bg1_xscroll, bg1_yscroll,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(92,92), see header
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, set_max_sprite_clock (see header)

	// sprite RAM base within mainram, in WORDS — m_sprdma_base=0xF000
	// bytes / 2 = 0x7800 words (see header; every prior port's own is
	// 0x4000, from the family default m_sprdma_base=0x8000).
	localparam [14:0] SPRDMA_BASE_WORDS = 15'h7800;

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py)
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:131071];  // strahl-3.73, region declared 0x20000, only first 0x10000 dumped
	reg [7:0] bgtile_rom  [0:262143];  // str7b2r0.275, 16x16 col_2x2_group, 128B/tile
	reg [7:0] bg2tile_rom [0:524287];  // str6b1w1.776, 16x16 col_2x2_group, 128B/tile
	reg [7:0] sprites_rom [0:1572863]; // strl3-01/strl4-02/strl5-03, plain concat (3 x 0x80000)
	initial if (FGTILE_FILE  != "") $readmemh(FGTILE_FILE,  fgtile_rom);
	initial if (BGTILE_FILE  != "") $readmemh(BGTILE_FILE,  bgtile_rom);
	initial if (BG2TILE_FILE != "") $readmemh(BG2TILE_FILE, bg2tile_rom);
	initial if (SPRITES_FILE != "") $readmemh(SPRITES_FILE, sprites_rom);

	// 8x8x4bpp packed_msb: 32 bytes/tile, hi nibble = even column first.
	function automatic [3:0] tile_nibble(input [7:0] byte_val, input col_odd);
		tile_nibble = col_odd ? byte_val[3:0] : byte_val[7:4];
	endfunction

	function automatic [3:0] fgtile_pixel(input integer code, input integer row, input integer col);
		integer byte_addr;
		begin
			byte_addr = code * 32 + row * 4 + (col >> 1);
			fgtile_pixel = tile_nibble(fgtile_rom[byte_addr[16:0]], col[0]);
		end
	endfunction

	// gfx_8x8x4_col_2x2_group_packed_msb: 128 bytes/16x16 unit; left half
	// (col 0-7) at +0, right half (col 8-15) at +64; row spans 0-15
	// through both halves uniformly. `rom_sel` selects which of the
	// three group16-format ROMs (0=bgtile/BG0, 1=sprites, 2=bg2tile/BG1).
	function automatic [3:0] group16_pixel(input integer base, input integer rom_sel, input integer row, input integer col);
		integer byte_addr;
		integer half_offset;
		integer col_local;
		begin
			half_offset = (col >= 8) ? 64 : 0;
			col_local = col & 7;
			byte_addr = base * 128 + half_offset + row * 4 + (col_local >> 1);
			case (rom_sel)
				2'd1:    group16_pixel = tile_nibble(sprites_rom[byte_addr[20:0]], col_local[0]);
				2'd2:    group16_pixel = tile_nibble(bg2tile_rom[byte_addr[19:0]], col_local[0]);
				default: group16_pixel = tile_nibble(bgtile_rom[byte_addr[18:0]],  col_local[0]);
			endcase
		end
	endfunction

	// ------------------------------------------------------------------
	// Palette decode: RRRRGGGGBBBBRGBx (emupal.cpp RRRRGGGGBBBBRGBx_decoder)
	// ------------------------------------------------------------------
	function automatic [7:0] expand5to8(input [4:0] v);
		expand5to8 = {v, v[4:2]};
	endfunction

	function automatic [23:0] decode_rgb(input [15:0] raw);
		reg [4:0] r5, g5, b5;
		begin
			r5 = {raw[15:12], raw[3]};
			g5 = {raw[11:8],  raw[2]};
			b5 = {raw[7:4],   raw[1]};
			decode_rgb = {expand5to8(r5), expand5to8(g5), expand5to8(b5)};
		end
	endfunction

	// ------------------------------------------------------------------
	// BG0: plain VRAM tilemap, page-mapped 16x16 tiles, 256 cols x 32
	// rows, independent X+Y scroll. Always opaque — the base layer.
	// ------------------------------------------------------------------
	wire [12:0] bg0_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg0_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg0_line_y = (rd_y + 13'd512 + bg0_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg0_col = bg0_line_x[11:4];
	wire [3:0]  bg0_px  = bg0_line_x[3:0];
	wire [4:0]  bg0_row = bg0_line_y[8:4];
	wire [3:0]  bg0_py  = bg0_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	assign bg0vram_addr = {bg0_row[4], bg0_col, bg0_row[3:0]};

	wire [3:0] bg0_pix_nib = group16_pixel(int'(bg0vram_data[11:0]), 0, int'(bg0_py), int'(bg0_px));
	// GFXDECODE_ENTRY("bgtile",...,0x300,16) — see header.
	wire [9:0] bg0_pal_addr = 10'h300 + {2'd0, bg0vram_data[15:12], bg0_pix_nib};

	// ------------------------------------------------------------------
	// BG1: second plain VRAM tilemap, same page-mapped layout as BG0,
	// independent X+Y scroll, transparent pen 15 — drawn over BG0.
	// ------------------------------------------------------------------
	wire [12:0] bg1_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg1_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg1_line_y = (rd_y + 13'd512 + bg1_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg1_col = bg1_line_x[11:4];
	wire [3:0]  bg1_px  = bg1_line_x[3:0];
	wire [4:0]  bg1_row = bg1_line_y[8:4];
	wire [3:0]  bg1_py  = bg1_line_y[3:0];

	assign bg1vram_addr = {bg1_row[4], bg1_col, bg1_row[3:0]};

	wire [3:0] bg1_pix_nib = group16_pixel(int'(bg1vram_data[11:0]), 2, int'(bg1_py), int'(bg1_px));
	wire       bg1_opaque = (bg1_pix_nib != 4'hF);
	// GFXDECODE_ENTRY("bg2tile",...,0x200,16) — see header.
	wire [9:0] bg1_pal_addr = 10'h200 + {2'd0, bg1vram_data[15:12], bg1_pix_nib};

	wire [9:0] base_pal_addr = bg1_opaque ? bg1_pal_addr : bg0_pal_addr;

	// ------------------------------------------------------------------
	// TX tilemap: fixed 8x8 tiles, 32x32 (256x256 logical px), no scroll
	// beyond the shared dx, transparent pen 15 — unchanged from mustang.
	// ------------------------------------------------------------------
	wire [8:0] tx_sum = {1'b0, rd_x[7:0]} + 9'd256 - VIDEOSHIFT[8:0];
	wire [7:0] tx_line_x = tx_sum[7:0]; // mod 256 (logical width), truncation is the modulo
	wire [7:0] tx_line_y = rd_y;        // 256 logical height, no scroll — direct
	wire [4:0] tx_col = tx_line_x[7:3];
	wire [2:0] tx_px  = tx_line_x[2:0];
	wire [4:0] tx_row = tx_line_y[7:3];
	wire [2:0] tx_py  = tx_line_y[2:0];

	// TILEMAP_SCAN_COLS: tile_index = col*32 + row
	assign txvram_addr = {tx_col, 5'd0} + {5'd0, tx_row};

	wire [3:0] tx_pix_nib = fgtile_pixel(int'(txvram_data[11:0]), int'(tx_py), int'(tx_px));
	wire       tx_opaque = (tx_pix_nib != 4'hF);
	// GFXDECODE_ENTRY("fgtile",...,0x000,16) — TX's own color base is
	// 0x000 here (no offset needed), unlike every prior port's own.
	wire [9:0] tx_pal_addr = {2'd0, txvram_data[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by all three tilemap layers —
	// TX wins when opaque, else the BG1-over-BG0 composite above.
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : base_pal_addr;
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM double-buffered snapshot (see video_mustang.sv's own
	// header derivation) — ping-ponging 2048-entry buffers.
	// ------------------------------------------------------------------
	reg [15:0] snap_buf [0:1][0:2047];
	reg        snap_cur; // buffer index the NEXT trigger will overwrite
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered display/draw planes — get_colour_4bit
	// is unchanged for strahl (same 4-bit colour mask), sprite GFXDECODE
	// color base is 0x100 here (see header).
	// ------------------------------------------------------------------
	reg [8:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1];
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [8:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 9'd0;
	wire        spr_valid = spr_entry[8];

	assign spr_palette_addr = 10'h100 + {2'd0, spr_entry[7:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG1-over-
	// BG0 — see header's "Compositing" derivation.
	assign rd_rgb = !rd_in_range ? 24'h0 : (tx_opaque ? tile_rgb : (spr_valid ? spr_rgb : tile_rgb));

	// ------------------------------------------------------------------
	// Sprite draw FSM — unchanged from video_mustang.sv EXCEPT the
	// mainram snapshot base offset (SPRDMA_BASE_WORDS, see header — the
	// only real difference from every prior port's own hardcoded 0x4000).
	// ------------------------------------------------------------------
	localparam
		S_RESET_CLR0 = 0,
		S_RESET_CLR1 = 1,
		S_IDLE        = 2,
		S_SNAP_REQ    = 3,
		S_SNAP_LATCH  = 4,
		S_CLEAR       = 5,
		S_SPR_HEAD    = 6,
		S_SPR_UNIT    = 7,
		S_SPR_CHECK   = 8,
		S_SPR_PLOT    = 9,
		S_SPR_NEXT    = 10,
		S_DONE        = 11;

	reg [3:0]  state;
	reg [16:0] clr_idx;
	reg        draw_buf;      // = ~disp_buf for the duration of one draw pass
	reg        draw_snap_idx; // = ~snap_cur, latched for the duration of one draw pass

	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;

	always @(posedge clk_sys) begin
		if (reset) begin
			state    <= S_RESET_CLR0;
			clr_idx  <= 17'd0;
			disp_buf <= 1'b0;
			snap_cur <= 1'b0;
			snap_pending <= 1'b0;
		end else begin
			if (sprite_dma_trigger) snap_pending <= 1'b1;

			case (state)
				S_RESET_CLR0: begin
					sprite_plane[0][clr_idx] <= 9'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						clr_idx <= 17'd0;
						state <= S_RESET_CLR1;
					end else clr_idx <= clr_idx + 17'd1;
				end
				S_RESET_CLR1: begin
					sprite_plane[1][clr_idx] <= 9'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) state <= S_IDLE;
					else clr_idx <= clr_idx + 17'd1;
				end

				S_IDLE: begin
					if (snap_pending) begin
						snap_pending <= 1'b0;
						snap_idx <= 12'd0;
						state <= S_SNAP_REQ;
					end
				end

				// snapshot mainram[SPRDMA_BASE_WORDS+i] -> snap_buf[snap_cur][i], i=0..2047
				S_SNAP_REQ: begin
					mainram_addr <= SPRDMA_BASE_WORDS + snap_idx[10:0];
					state <= S_SNAP_LATCH;
				end
				S_SNAP_LATCH: begin
					snap_buf[snap_cur][snap_idx] <= mainram_data;
					if (snap_idx == 12'd2047) begin
						draw_buf <= ~disp_buf;
						draw_snap_idx <= ~snap_cur;
						clr_idx <= 17'd0;
						state <= S_CLEAR;
					end else begin
						snap_idx <= snap_idx + 12'd1;
						state <= S_SNAP_REQ;
					end
				end

				S_CLEAR: begin
					sprite_plane[draw_buf][clr_idx] <= 9'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						s_slot <= 0;
						clk_budget <= 0;
						state <= S_SPR_HEAD;
					end else clr_idx <= clr_idx + 17'd1;
				end

				// ---------------- sprites ----------------
				S_SPR_HEAD: begin
					begin : spr_head_blk
						integer offs;
						reg [15:0] w0, w1, w3, w4, w6, w7;
						integer budget_after_scan, budget_after_draw;
						integer w, h;

						offs = s_slot * 8;
						w0 = snap_buf[draw_snap_idx][offs + 0];
						w1 = snap_buf[draw_snap_idx][offs + 1];
						w3 = snap_buf[draw_snap_idx][offs + 3];
						w4 = snap_buf[draw_snap_idx][offs + 4];
						w6 = snap_buf[draw_snap_idx][offs + 6];
						w7 = snap_buf[draw_snap_idx][offs + 7];
						w = w1[3:0];
						h = w1[7:4];

						budget_after_scan = clk_budget + 16;
						budget_after_draw = budget_after_scan + 128 * w * h;

						if (budget_after_scan >= MAX_SPRITE_CLOCK) begin
							state <= S_DONE;
						end else if (!w0[0]) begin
							clk_budget <= budget_after_scan;
							if (s_slot == 255) state <= S_DONE;
							else begin s_slot <= s_slot + 1; state <= S_SPR_HEAD; end
						end else if (budget_after_draw >= MAX_SPRITE_CLOCK) begin
							state <= S_DONE;
						end else begin
							clk_budget <= budget_after_draw;
							s_w <= w;
							s_h <= h;
							s_code <= w3;
							s_colour <= w7[3:0];
							s_sx <= (int'(w4) & 9'h1ff) + VIDEOSHIFT;
							s_sy <= (int'(w6) & 9'h1ff);
							s_ty <= 0; s_tx <= 0; s_py <= 0; s_px <= 0;
							state <= S_SPR_UNIT;
						end
					end
				end

				S_SPR_UNIT: begin
					s_unit_code <= s_code + s_ty * (s_w + 1) + s_tx;
					s_pixel_x_base <= (s_sx + s_tx * 16) % 512;
					s_pixel_y_base <= (s_sy + s_ty * 16) % 512;
					s_px <= 0; s_py <= 0;
					state <= S_SPR_CHECK;
				end

				S_SPR_CHECK: begin
					s_pix_nib = group16_pixel(s_unit_code, 1, s_py, s_px);
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT;
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						sx = s_pixel_x_base + s_px;
						sy = s_pixel_y_base + s_py;
						if (sx < SCREEN_W && sy < SCREEN_H)
							sprite_plane[draw_buf][sy * SCREEN_W + sx] <= {1'b1, s_colour[3:0], s_pix_nib[3:0]};
					end
					state <= S_SPR_NEXT;
				end

				S_SPR_NEXT: begin
					if (s_px == 15) begin
						s_px <= 0;
						if (s_py == 15) begin
							s_py <= 0;
							if (s_tx == s_w) begin
								s_tx <= 0;
								if (s_ty == s_h) begin
									if (s_slot == 255) state <= S_DONE;
									else begin s_slot <= s_slot + 1; state <= S_SPR_HEAD; end
								end else begin
									s_ty <= s_ty + 1;
									state <= S_SPR_UNIT;
								end
							end else begin
								s_tx <= s_tx + 1;
								state <= S_SPR_UNIT;
							end
						end else begin
							s_py <= s_py + 1;
							state <= S_SPR_CHECK;
						end
					end else begin
						s_px <= s_px + 1;
						state <= S_SPR_CHECK;
					end
				end

				S_DONE: begin
					disp_buf <= draw_buf;
					snap_cur <= ~snap_cur;
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
