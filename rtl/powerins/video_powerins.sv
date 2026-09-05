// powerins video pipeline — Tier 3's fourth port (Family C, Z80-direct-sound
// boards), and its most novel video target yet. Derived from
// rtl/macross2/video_macross2.sv's own architecture (BG tilemap fetch, TX
// tilemap fetch, palette decode, sprite double-buffer/draw FSM all reused
// structurally), with the following real, source-verified differences:
//
//   1. **No tilerambank.** `VIDEO_START_MEMBER(nmk16_state,powerins)`
//      (nmk16_v.cpp) has no bank-select logic at all, and powerins' own
//      bgvideoram region (nmk16.cpp:powerins_map, 0x140000-0x143FFF,
//      0x4000 bytes) is the SAME smaller size every Tier 5 port's own
//      bgvideoram used — NOT macross2's own four-times-bigger 0x10000.
//      `bgvram_addr` below is therefore the plain 13-bit
//      `{bg_row[4],bg_col,bg_row[3:0]}` tilemap_scan_pages index, no
//      bank prefix.
//
//   2. **11-bit BG tile code, non-contiguous 5-bit BG colour.**
//      `powerins_get_bg_tile_info` (nmk16_v.cpp):
//        `tileinfo.set(1, (code&0x07ff)|(m_bgbank<<11), ((code&0xf000)>>12)|((code&0x0800)>>7), 0);`
//      Tile index = code[10:0] concatenated with the full 8-bit bgbank
//      register shifted up by 11 (bank<<11 with a plain, unmasked 8-bit
//      write in tilebank_w — not artificially truncated to the ROM's own
//      real tile count here, matching the reference's own literal
//      computation). Colour is a 5-bit value assembled from TWO
//      non-adjacent code bits: the low nibble comes from code[15:12], and
//      the TOP bit of the 5-bit colour comes from code[11] — code bit 11
//      is used ONLY for colour, never folted into the tile index (unlike
//      macross2's own contiguous 12-bit-code+4-bit-colour split).
//
//   3. **Single BG tilemap, no per-scanline scroll, no tilebank
//      pixel-level anything else new** — `VIDEO_START_MEMBER(powerins)`
//      creates only `m_bg_tilemap[0]` (256x32, 16x16 — same geometry as
//      macross2's own) with no `set_scroll_rows` call, confirming
//      video_gunnail.sv's own per-row scroll mechanism does NOT apply
//      here.
//
//   4. **6-bit sprite colour, not 5.** `get_colour_6bit` (nmk16_v.cpp,
//      `colour &= 0x3f`) — widened one more bit past macross2's own 5-bit
//      field. `gfx_powerins`'s own GFXDECODE_START (nmk16.cpp:4220-4224)
//      confirms the palette layout this needs: BG at base 0x000 (32
//      colours, 0x000-0x1FF), TX at 0x200 (16 colours, 0x200-0x2FF),
//      sprites at 0x400 (64 colours, 0x400-0x7FF) — summing to exactly
//      0x800=2048 entries, matching `PALETTE(...).set_format(...,2048)`
//      exactly. This is a WIDER palette than every prior Tier 3 port's
//      own 1024-entry table — palette_addr/spr_palette_addr are 11 bits
//      here, not 10.
//
//   5. **Sprite horizontal flip — genuinely new to this project.** No
//      prior port (macross2/tdragon2/raphero, nor any Tier 5 port)
//      implements ANY flip logic; confirmed via grep that
//      video_macross2.sv has zero flipx/flipy references anywhere.
//      `powerins()`'s own machine config sets
//      `m_spritegen->set_ext_callback(FUNC(nmk16_state::get_flip_extcode_powerins))`,
//      and `get_flip_extcode_powerins` (nmk16_v.cpp) is:
//        `flipx = BIT(attr, 12);`
//        `code = (code & 0x7fff) | ((attr & 0x100) << 7);`
//      — i.e. `s_code`'s own bit 15 is REPLACED by attribute word bit 8
//      (attr is the SAME w1 word that already encodes w/h in its own low
//      byte), and flipx comes from attr bit 12. flipy is never touched by
//      this callback — confirmed always 0 for this game, no vertical-flip
//      logic implemented.
//
//      The exact flip semantics were derived directly from
//      `nmk_16bit_sprite_device::draw_sprites`
//      (mame/src/mame/nmk/nmk16spr.cpp:55-256), which applies flip in TWO
//      combined ways: (a) the per-UNIT draw loop's own screen-X placement
//      reverses (`sx += flipx?(delta*w):0` with a negated `xinc`, while
//      `codecol`/the code-walk order does NOT reverse — same
//      `s_unit_code` formula regardless of flip); (b) each unit's own
//      pixel COLUMNS are separately mirrored via `gfx->transpen`'s own
//      `flipx_global` argument (source-pixel fetch reversed, destination
//      column position NOT reversed). Translated to this FSM: when
//      s_flipx, `s_pixel_x_base` uses `(s_w-s_tx)` in place of `s_tx`
//      (reversing which unit lands at which screen position, code-walk
//      unaffected), while the per-pixel SOURCE column fetch (feeding
//      `half_offset`/`col_local`/the nibble-select bit) uses
//      `(15-s_px)` in place of `s_px` — the destination plot position
//      (`sx = s_pixel_x_base + s_px`) stays the plain, un-mirrored s_px.
//
//   6. **23-bit sprite ROM addressing.** powerins' sprites region is
//      0x800000 bytes (nmk16.cpp:9010-9018, eight ROM_LOAD16_WORD_SWAP
//      files), double raphero's own 0x600000 and double macross2's own
//      0x400000 — needs one more address bit than video_macross2.sv's
//      own 22-bit spr_byte_addr.
//
// Screen geometry: `set_screen_midres` (nmk16.cpp:4367-4378) gives a
// THIRD distinct visible width class (256=lowres, 384=hires, 320=midres
// here) — 380-60=320px wide, 240-16=224px tall (height unchanged from
// every class). `VIDEOSHIFT`=60+32=92 (`set_scrolldx(60+32,60+32)`,
// VIDEO_START_MEMBER(powerins)'s own comment: "leftmost 32 pixels have to
// be retrieved from the other side of the tilemap").
//
// Everything else (palette RGB decode, sprite double-buffer/snapshot,
// TX tilemap fetch/geometry — same 64x32/8x8 `TILEMAP_SCAN_COLS` sizing,
// `common_get_tx_tile_info`'s own unchanged 12-bit-code/4-bit-colour
// split) is video_macross2.sv's own, unmodified.
module video_powerins #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger, // from nmk_irq: snapshot sprite RAM now

	output [12:0] bgvram_addr, // 13 bits — 0x4000-byte BG VRAM (8192 words), no tilerambank prefix (see header)
	input  [15:0] bgvram_data,
	output [10:0] txvram_addr,
	input  [15:0] txvram_data,
	output [10:0] palette_addr,     // 11 bits — 2048-entry palette (see header)
	input  [15:0] palette_data,
	output [10:0] spr_palette_addr,
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

	localparam integer SCREEN_W = 320;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(60+32,60+32), see header
	localparam integer MAX_SPRITE_CLOCK = 117824; // 448*263, set_max_sprite_clock

	// Palette bases — see header. Sprite is 6-bit (64 colours).
	localparam [10:0] BG_PAL_BASE  = 11'h000;
	localparam [10:0] TX_PAL_BASE  = 11'h200;
	localparam [10:0] SPR_PAL_BASE = 11'h400;

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py). No
	// descrambling (no protection MCU on this board).
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:1048575]; // 93095-1.u15, 0x100000 — only the low 0x20000 is ever addressed (12-bit code, see header)
	reg [7:0] bgtile_rom  [0:2621439]; // 93095-5/6/7, 0x280000 concat
	reg [7:0] sprites_rom [0:8388607]; // 93095-12..19, word_swap-extracted, 0x800000
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
			fgtile_pixel = tile_nibble(fgtile_rom[byte_addr[19:0]], col[0]);
		end
	endfunction

	// ------------------------------------------------------------------
	// BG tile-fetch address — gfx_8x8x4_col_2x2_group_packed_msb layout:
	// 128 bytes/16x16 unit, left half (col 0-7) at +0, right half
	// (col 8-15) at +64, same as video_macross2.sv's own derivation.
	// bg_code is 19 bits wide (8-bit bgbank concatenated with an 11-bit
	// in-VRAM code, see header) — real game data only ever exercises
	// bank values reaching the ROM's own actual 20480-tile range; a
	// theoretically-out-of-range bank value aliases within bgtile_rom's
	// own declared size rather than being separately clamped (matches no
	// masking anywhere in the reference's own literal computation).
	// ------------------------------------------------------------------
	wire [25:0] bg_byte_addr;
	wire [7:0]  bgtile_byte = bgtile_rom[bg_byte_addr[21:0]];

	function automatic [3:0] bg_tile_pixel_nib(input [7:0] byte_val, input integer col_local);
		bg_tile_pixel_nib = tile_nibble(byte_val, col_local[0]);
	endfunction

	// ------------------------------------------------------------------
	// Sprite tile-fetch address — plain byte read, no descrambling.
	// ------------------------------------------------------------------
	wire [22:0] spr_byte_addr;
	wire [7:0] sprites_byte = sprites_rom[spr_byte_addr[22:0]];

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
	// logical px), frame-constant X/Y scroll, no tilerambank (see header).
	// ------------------------------------------------------------------
	wire [12:0] bg_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg_line_y = (rd_y + 13'd512 + bg_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg_col = bg_line_x[11:4];
	wire [3:0]  bg_px  = bg_line_x[3:0];
	wire [4:0]  bg_row = bg_line_y[8:4];
	wire [3:0]  bg_py  = bg_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	assign bgvram_addr = {bg_row[4], bg_col, bg_row[3:0]};

	// powerins_get_bg_tile_info: (code&0x07ff)|(bgbank<<11), colour =
	// ((code&0xf000)>>12)|((code&0x0800)>>7) — see header.
	wire [18:0] bg_code = {bg_bank, bgvram_data[10:0]};
	wire [3:0]  bg_half_col = bg_px;
	assign bg_byte_addr = {bg_code, 7'd0} + (bg_half_col >= 4'd8 ? 26'd64 : 26'd0) + {18'd0, bg_py, 2'd0} + {22'd0, bg_half_col[2:1]};
	wire [3:0] bg_pix_nib = bg_tile_pixel_nib(bgtile_byte, bg_half_col & 4'h7);
	wire [4:0] bg_colour5 = {bgvram_data[11], bgvram_data[15:12]};
	wire [10:0] bg_pal_addr = BG_PAL_BASE + {6'd0, bg_colour5};

	// ------------------------------------------------------------------
	// TX tilemap: fixed 8x8 tiles, 64x32 (512x256 logical px), no scroll
	// beyond the shared dx, transparent pen 15 — unchanged from
	// video_macross2.sv's own (common_get_tx_tile_info is shared, see
	// header point 6).
	// ------------------------------------------------------------------
	wire [9:0] tx_sum = {2'b0, rd_x[7:0]} + 10'd512 - VIDEOSHIFT[9:0];
	wire [8:0] tx_line_x = tx_sum[8:0]; // mod 512 (logical width), truncation is the modulo
	wire [7:0] tx_line_y = rd_y;        // 256 logical height, no scroll — direct
	wire [5:0] tx_col = tx_line_x[8:3]; // 6 bits — 64 columns
	wire [2:0] tx_px  = tx_line_x[2:0];
	wire [4:0] tx_row = tx_line_y[7:3];
	wire [2:0] tx_py  = tx_line_y[2:0];

	// TILEMAP_SCAN_COLS, 64x32: tile_index = col*32 + row (11 bits, 0-2047)
	assign txvram_addr = {tx_col, 5'd0} + {6'd0, tx_row};

	wire [3:0] tx_pix_nib = fgtile_pixel(int'(txvram_data[11:0]), int'(tx_py), int'(tx_px));
	wire       tx_opaque = (tx_pix_nib != 4'hF);
	wire [10:0] tx_pal_addr = TX_PAL_BASE + {3'd0, txvram_data[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by both tilemap layers — TX
	// wins when opaque (pen!=15), else BG.
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : bg_pal_addr;
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM double-buffered snapshot — unchanged from
	// video_macross2.sv's own (ping-ponging 2048-entry buffers).
	// ------------------------------------------------------------------
	reg [15:0] snap_buf [0:1][0:2047];
	reg        snap_cur; // buffer index the NEXT trigger will overwrite
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered display/draw planes — 6-bit colour
	// field, sprite GFXDECODE colour base 0x400 (see header).
	// ------------------------------------------------------------------
	reg [10:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1]; // {valid,colour[5:0],pix[3:0]} = 1+6+4=11 bits
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [10:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 11'd0;
	wire        spr_valid = spr_entry[10];

	assign spr_palette_addr = SPR_PAL_BASE + {1'd0, spr_entry[9:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG.
	assign rd_rgb = !rd_in_range ? 24'h0 : (tx_opaque ? tile_rgb : (spr_valid ? spr_rgb : tile_rgb));

	// ------------------------------------------------------------------
	// Sprite draw FSM — video_macross2.sv's own, with: 6-bit colour field
	// (s_colour[5:0]), 23-bit sprite-ROM byte address, and the new
	// horizontal-flip logic (see header point 5): s_code's own bit 15 is
	// replaced by w1 bit 8, s_flipx comes from w1 bit 12. s_unit_code's
	// own formula is UNCHANGED by flip (code-walk order doesn't reverse);
	// only s_pixel_x_base's per-unit placement and the per-pixel SOURCE
	// column (half_offset/col_local/nibble-select) mirror when flipped —
	// the destination plot column (s_px in S_SPR_PLOT) does not.
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
		S_SPR_CHECK2  = 9,
		S_SPR_PLOT    = 10,
		S_SPR_NEXT    = 11,
		S_DONE        = 12;

	reg [3:0]  state;
	reg [16:0] clr_idx;
	reg        draw_buf;      // = ~disp_buf for the duration of one draw pass
	reg        draw_snap_idx; // = ~snap_cur, latched for the duration of one draw pass

	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	reg     s_flipx;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;
	reg [22:0] s_byte_addr;
	assign spr_byte_addr = s_byte_addr;

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
					sprite_plane[0][clr_idx] <= 11'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						clr_idx <= 17'd0;
						state <= S_RESET_CLR1;
					end else clr_idx <= clr_idx + 17'd1;
				end
				S_RESET_CLR1: begin
					sprite_plane[1][clr_idx] <= 11'd0;
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
					sprite_plane[draw_buf][clr_idx] <= 11'd0;
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
							// get_flip_extcode_powerins: code=(code&0x7fff)|((attr&0x100)<<7)
							// — bit15 of s_code comes from w1 bit8, bits14:0 from w3.
							s_code <= {w1[8], w3[14:0]};
							s_colour <= w7[5:0];
							s_flipx <= w1[12]; // get_flip_extcode_powerins: flipx=BIT(attr,12)
							s_sx <= (int'(w4) & 9'h1ff) + VIDEOSHIFT;
							s_sy <= (int'(w6) & 9'h1ff);
							s_ty <= 0; s_tx <= 0; s_py <= 0; s_px <= 0;
							state <= S_SPR_UNIT;
						end
					end
				end

				S_SPR_UNIT: begin
					s_unit_code <= s_code + s_ty * (s_w + 1) + s_tx; // unchanged by flip — code-walk order doesn't reverse (see header)
					s_pixel_x_base <= s_flipx ? (s_sx + (s_w - s_tx) * 16) % 512 : (s_sx + s_tx * 16) % 512;
					s_pixel_y_base <= (s_sy + s_ty * 16) % 512;
					s_px <= 0; s_py <= 0;
					state <= S_SPR_CHECK;
				end

				S_SPR_CHECK: begin
					begin : spr_check_blk
						integer px_eff, half_offset, col_local, byte_addr;
						px_eff = s_flipx ? (15 - s_px) : s_px; // source-column mirror when flipped (see header)
						half_offset = (px_eff >= 8) ? 64 : 0;
						col_local = px_eff & 7;
						byte_addr = s_unit_code * 128 + half_offset + s_py * 4 + (col_local >> 1);
						s_byte_addr <= byte_addr[22:0];
					end
					state <= S_SPR_CHECK2;
				end
				// One extra cycle so `spr_byte_addr`/`sprites_byte` (combinational,
				// downstream of a registered `s_byte_addr`) has settled before
				// this state reads it.
				S_SPR_CHECK2: begin
					begin : spr_check2_blk
						integer px_eff;
						px_eff = s_flipx ? (15 - s_px) : s_px;
						s_pix_nib = tile_nibble(sprites_byte, px_eff[0]);
					end
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT;
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						sx = s_pixel_x_base + s_px; // destination column NOT mirrored (see header)
						sy = s_pixel_y_base + s_py;
						if (sx < SCREEN_W && sy < SCREEN_H)
							sprite_plane[draw_buf][sy * SCREEN_W + sx] <= {1'b1, s_colour[5:0], s_pix_nib[3:0]};
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
