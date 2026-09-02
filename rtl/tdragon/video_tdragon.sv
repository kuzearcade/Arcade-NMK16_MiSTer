// tdragon-family (Family B/macross) video pipeline — the sixth Tier 2
// NMK004-board game to get a real video pipeline, after
// rtl/mustang/video_mustang.sv, rtl/bioship/video_bioship.sv,
// rtl/blkheart/video_blkheart.sv, rtl/strahl/video_strahl.sv, and
// rtl/acrobatm/video_acrobatm.sv (those modules' own headers cover the
// shared tile-decode/palette/sprite-FSM architecture in full). tdragon's
// own video family is *identical* to blkheart's own in every respect
// that matters to this module — same `VIDEO_START_MEMBER(nmk16_state,
// macross)`, same `screen_update_macross`, same `gfx_macross` (TX=0x200,
// BG=0x000, sprites=0x100), same BG tile-code bank extension via
// `tilebank_w` (tdragon's own "bgtile" ROM is 0x100000 bytes, 8192
// tiles, the exact same size as blkheart's own — confirmed directly
// from `ROM_START(tdragon)`, not assumed), and even the same sprite-ROM
// size (0x100000) and loading convention (`ROM_LOAD16_WORD_SWAP`, same
// as blkheart's own `90068-8.bin`). This module is therefore
// functionally IDENTICAL to video_blkheart.sv — every array size,
// truncation width, color base, and the sprite draw FSM itself all
// carry over unchanged. See video_blkheart.sv's own header (and
// video_mustang.sv's, for the base architecture) for the full
// derivation of everything below; not re-derived here since nothing
// about it is actually different for tdragon.
module video_tdragon #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger, // from nmk_irq: snapshot sprite RAM now

	// register/RAM read ports into tdragon_core's storage (dual-tap
	// reads, tdragon_core owns the arrays — see mustang_core.sv's own
	// header for why)
	output [12:0] bgvram_addr,
	input  [15:0] bgvram_data,
	output [9:0]  txvram_addr,
	input  [15:0] txvram_data,
	output [9:0]  palette_addr,     // tile-plane palette tap (live, per-pixel)
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only, see header)
	input  [15:0] spr_palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,

	input [15:0] bg_xscroll, bg_yscroll,
	input [7:0]  bg_bank,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(92,92), see header
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, set_max_sprite_clock

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py)
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:131071];  // 91070.6, 8x8x4bpp packed_msb, 32B/tile (fully populated here, unlike blkheart's own half-populated one — see header, no RTL difference either way)
	reg [7:0] bgtile_rom  [0:1048575]; // 91070.5, 16x16 col_2x2_group, 128B/tile — 8192 tiles (bank-extended, see header)
	reg [7:0] sprites_rom [0:1048575]; // 91070.4, word_swap-extracted (see tools/mkgfxrom.py), 128B/16x16-unit
	initial if (FGTILE_FILE  != "") $readmemh(FGTILE_FILE,  fgtile_rom);
	initial if (BGTILE_FILE  != "") $readmemh(BGTILE_FILE,  bgtile_rom);
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
	// through both halves uniformly (same layout as every prior port's
	// own — see video_mustang.sv's own derivation of this format).
	function automatic [3:0] group16_pixel(input integer base, input integer rom_sel, input integer row, input integer col);
		integer byte_addr;
		integer half_offset;
		integer col_local;
		begin
			half_offset = (col >= 8) ? 64 : 0;
			col_local = col & 7;
			byte_addr = base * 128 + half_offset + row * 4 + (col_local >> 1);
			group16_pixel = rom_sel
				? tile_nibble(sprites_rom[byte_addr[20:0]], col_local[0])
				: tile_nibble(bgtile_rom[byte_addr[20:0]],  col_local[0]);
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
	// BG tilemap: page-mapped 16x16 tiles, 256 cols x 32 rows (4096x512
	// logical px), independent X and Y scroll. Pure per-pixel
	// combinational function, same rationale as video_mustang.sv's own
	// tilemap path.
	// ------------------------------------------------------------------
	wire [12:0] bg_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg_line_y = (rd_y + 13'd512 + bg_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg_col = bg_line_x[11:4];
	wire [3:0]  bg_px  = bg_line_x[3:0];
	wire [4:0]  bg_row = bg_line_y[8:4];
	wire [3:0]  bg_py  = bg_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	assign bgvram_addr = {bg_row[4], bg_col, bg_row[3:0]};

	// common_get_bg_tile_info<0,1>: (code&0xfff)|(m_bgbank<<12) — see
	// header. Only bit 0 of bg_bank matters (8192 tiles = 13 bits).
	wire [12:0] bg_code = {bg_bank[0], bgvram_data[11:0]};
	wire [3:0] bg_pix_nib = group16_pixel(int'(bg_code), 0, int'(bg_py), int'(bg_px));
	wire [9:0] bg_pal_addr = {bgvram_data[15:12], bg_pix_nib};

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
	// GFXDECODE_ENTRY("fgtile",...,0x200,16) — same color base as
	// mustang's own gfx_macross usage.
	wire [9:0] tx_pal_addr = 10'h200 + {2'd0, txvram_data[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by both tilemap layers (same
	// single-tap approach as video_mustang.sv) — TX wins when opaque
	// (pen!=15), else BG (BG is never transparent for this family).
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : bg_pal_addr;
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
	// is unchanged for tdragon (same 4-bit colour mask, same sprite
	// GFXDECODE color base 0x100 as mustang's own).
	// ------------------------------------------------------------------
	reg [8:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1];
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [8:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 9'd0;
	wire        spr_valid = spr_entry[8];

	assign spr_palette_addr = 10'h100 + {2'd0, spr_entry[7:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG — see
	// header.
	assign rd_rgb = !rd_in_range ? 24'h0 : (tx_opaque ? tile_rgb : (spr_valid ? spr_rgb : tile_rgb));

	// ------------------------------------------------------------------
	// Sprite draw FSM — unchanged from video_mustang.sv (see that
	// module's own header for the double-buffer-delay/clock-budget
	// derivation this replicates verbatim).
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

				// snapshot mainram[0x8000+i] -> snap_buf[snap_cur][i], i=0..2047
				S_SNAP_REQ: begin
					mainram_addr <= 15'h4000 + snap_idx[10:0]; // 0x8000 bytes / 2 = 0x4000 word offset
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
