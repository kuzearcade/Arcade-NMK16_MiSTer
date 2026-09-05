// macross2 video pipeline — Tier 3's first port (Family C, Z80-direct-sound
// hi-res boards). Confirmed directly from the reference:
// `VIDEO_START_MEMBER(nmk16_state,macross2)` (nmk16_v.cpp:150-162) creates
// a `common_get_bg_tile_info<0,1>`-driven, `tilemap_scan_pages`-mapped,
// 256x32-tile (16x16 px) BG tilemap — the SAME BG geometry
// `rtl/macross/video_macross.sv` already implements (14-bit BG tile code,
// since macross2's own bgtile ROM is 0x200000 bytes/16384 tiles, identical
// size to macross's own) — plus a 64x32-tile (8x8 px) TX tilemap, which is
// `rtl/gunnail/video_gunnail.sv`'s own TX sizing (`gunnail`'s own
// VIDEO_START literally calls `VIDEO_START_CALL_MEMBER(macross2)` first,
// nmk16_v.cpp:164-168 — i.e. gunnail's TX layer IS macross2's own, not the
// other way around). This module is therefore video_macross.sv's own BG
// architecture + video_gunnail.sv's own TX sizing, with two more real
// differences confirmed directly from the reference, not assumed:
//
//   1. **No NMK214 descrambling** — macross2 has no protection MCU at all
//      (`init_banked_audiocpu` only, nmk16.cpp:10736); bgtile/sprites ROM
//      data is read directly, unlike video_macross.sv's own two live
//      nmk214 instances.
//   2. **5-bit sprite colour, not 4** — `macross2()`'s own machine config
//      uses `get_colour_5bit` (nmk16.cpp:5457, `colour &= 0x1f`), not
//      `get_colour_4bit` every single prior port in this project has used.
//      `gfx_macross2`'s own GFXDECODE_START (nmk16.cpp:4194-4198) confirms
//      the palette layout this requires: sprites at colour base `0x100`
//      with **32** colours (`0x100-0x2FF`, matching the 5-bit index
//      exactly), NOT `0x200` like macross's/gunnail's own. TX is also at a
//      DIFFERENT base here — `0x300`, 16 colours (`0x300-0x3FF`) — NOT
//      `0x200` like every prior port's own TX layer. BG stays at `0x000`,
//      16 colours, unchanged. Confirmed directly against `gfx_macross2`'s
//      own GFXDECODE_START rather than assumed from family resemblance —
//      these three bases exactly tile the full 1024-entry palette
//      (0x000-0x0FF BG, 0x100-0x2FF sprites, 0x300-0x3FF TX).
//
// Per-scanline raster scroll (video_gunnail.sv's own "hardest video item")
// does NOT apply here — macross2_map's own `130000-130007` is a single
// `scroll_w<0>` register (nmk16.cpp:1094), the same plain X/Y scroll shape
// every Tier 5 port's own video already used, not gunnail's own per-row
// scrollram tables. `bg_xscroll`/`bg_yscroll` below are frame-constant
// register inputs, not the row-indexed taps video_gunnail.sv needs.
//
// Everything else (palette decode, sprite double-buffer/draw FSM,
// composite order) is video_macross.sv's own, unchanged.
module video_macross2 #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger, // from nmk_irq: snapshot sprite RAM now

	// register/RAM read ports into macross2_core's storage (dual-tap
	// reads, macross2_core owns the arrays)
	output [14:0] bgvram_addr,
	input  [15:0] bgvram_data,
	// bgvideoram_w<Layer>/scroll_w<Layer> (nmk16.cpp:465-503): macross2's
	// own bgvideoram is FOUR "banks" of the same 8192-tile-position
	// tilemap (0x10000 bytes vs. every other port's own 0x4000 — see
	// module header), selected by bits[5:4] of the scroll register's own
	// X-scroll-high byte (nmk16.cpp:490-501 — `newbank = (m_scroll[0]>>4)
	// & 3`; those same bits also land in the X-scroll VALUE itself via
	// `set_scrollx`'s own unmasked use of that byte, but get discarded by
	// the tilemap's own mod-4096 wraparound, so this doesn't corrupt the
	// visible scroll amount). Top 2 bits of bgvram_addr below.
	input  [1:0]  tilerambank,
	output [10:0] txvram_addr,
	input  [15:0] txvram_data,
	output [9:0]  palette_addr,     // tile-plane palette tap (live, per-pixel)
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only)
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
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(28+64,28+64), see video_gunnail.sv's own header
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, set_max_sprite_clock

	// Palette bases — see header. Sprite is 5-bit (32 colours), not 4-bit.
	localparam [9:0] BG_PAL_BASE  = 10'h000;
	localparam [9:0] SPR_PAL_BASE = 10'h100;
	localparam [9:0] TX_PAL_BASE  = 10'h300;

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py). No
	// descrambling — read directly (see header).
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:131071];  // mcrs2j.1, 8x8x4bpp packed_msb, 32B/tile
	reg [7:0] bgtile_rom  [0:2097151]; // bp932an.a04, 16x16 col_2x2_group, 128B/tile — 16384 tiles (14-bit code, see header)
	reg [7:0] sprites_rom [0:4194303]; // bp932an.a07+a08, word_swap-extracted, 128B/16x16-unit
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

	// ------------------------------------------------------------------
	// BG tile-fetch address — gfx_8x8x4_col_2x2_group_packed_msb layout:
	// 128 bytes/16x16 unit, left half (col 0-7) at +0, right half
	// (col 8-15) at +64, same as video_macross.sv's own derivation.
	// ------------------------------------------------------------------
	wire [20:0] bg_byte_addr;
	wire [7:0]  bgtile_byte = bgtile_rom[bg_byte_addr];

	function automatic [3:0] bg_tile_pixel_nib(input [7:0] byte_val, input integer col_local);
		bg_tile_pixel_nib = tile_nibble(byte_val, col_local[0]);
	endfunction

	// ------------------------------------------------------------------
	// Sprite tile-fetch address — plain byte read, no descrambling.
	// ------------------------------------------------------------------
	wire [21:0] spr_byte_addr;
	wire [7:0] sprites_byte = sprites_rom[spr_byte_addr[21:0]];

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
	// logical px) — video_macross.sv's own geometry, frame-constant
	// X/Y scroll (not per-row, see header).
	// ------------------------------------------------------------------
	wire [12:0] bg_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg_line_y = (rd_y + 13'd512 + bg_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg_col = bg_line_x[11:4];
	wire [3:0]  bg_px  = bg_line_x[3:0];
	wire [4:0]  bg_row = bg_line_y[8:4];
	wire [3:0]  bg_py  = bg_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	assign bgvram_addr = {tilerambank, bg_row[4], bg_col, bg_row[3:0]};

	// common_get_bg_tile_info<0,1>: (code&0xfff)|(m_bgbank<<12) — 14-bit
	// code for macross2's own 16384-tile ROM (bg_bank[1:0], same as
	// macross's own — see header).
	wire [13:0] bg_code = {bg_bank[1:0], bgvram_data[11:0]};
	wire [3:0]  bg_half_col = bg_px;
	assign bg_byte_addr = {bg_code, 7'd0} + (bg_half_col >= 4'd8 ? 21'd64 : 21'd0) + {15'd0, bg_py, 2'd0} + {19'd0, bg_half_col[2:1]};
	wire [3:0] bg_pix_nib = bg_tile_pixel_nib(bgtile_byte, bg_half_col & 4'h7);
	wire [9:0] bg_pal_addr = BG_PAL_BASE + {bgvram_data[15:12], bg_pix_nib};

	// ------------------------------------------------------------------
	// TX tilemap: fixed 8x8 tiles, 64x32 (512x256 logical px — see
	// header, video_gunnail.sv's own sizing), no scroll beyond the
	// shared dx, transparent pen 15.
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
	wire [9:0] tx_pal_addr = TX_PAL_BASE + {2'd0, txvram_data[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by both tilemap layers — TX
	// wins when opaque (pen!=15), else BG.
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : bg_pal_addr;
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM double-buffered snapshot — unchanged from
	// video_macross.sv's own (ping-ponging 2048-entry buffers).
	// ------------------------------------------------------------------
	reg [15:0] snap_buf [0:1][0:2047];
	reg        snap_cur; // buffer index the NEXT trigger will overwrite
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered display/draw planes — 5-bit colour
	// field, sprite GFXDECODE colour base 0x100 (see header, NOT 4-bit/
	// 0x100-as-16-colours like every prior port's own).
	// ------------------------------------------------------------------
	reg [9:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1]; // {valid,colour[4:0],pix[3:0]} = 1+5+4=10 bits
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [9:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 10'd0;
	wire        spr_valid = spr_entry[9];

	assign spr_palette_addr = SPR_PAL_BASE + {1'd0, spr_entry[8:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG.
	assign rd_rgb = !rd_in_range ? 24'h0 : (tx_opaque ? tile_rgb : (spr_valid ? spr_rgb : tile_rgb));

	// ------------------------------------------------------------------
	// Sprite draw FSM — unchanged from video_macross.sv's own, except
	// the colour field is 5 bits wide (s_colour[4:0]) throughout instead
	// of 4 (see header), and the byte address is 22 bits wide (macross2's
	// own sprite ROM is 0x400000 bytes/4MB, double macross's own 2MB).
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
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;
	reg [21:0] s_byte_addr;
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
					sprite_plane[0][clr_idx] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						clr_idx <= 17'd0;
						state <= S_RESET_CLR1;
					end else clr_idx <= clr_idx + 17'd1;
				end
				S_RESET_CLR1: begin
					sprite_plane[1][clr_idx] <= 10'd0;
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
					sprite_plane[draw_buf][clr_idx] <= 10'd0;
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
							s_colour <= w7[4:0];
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
					begin : spr_check_blk
						integer half_offset, col_local, byte_addr;
						half_offset = (s_px >= 8) ? 64 : 0;
						col_local = s_px & 7;
						byte_addr = s_unit_code * 128 + half_offset + s_py * 4 + (col_local >> 1);
						s_byte_addr <= byte_addr[21:0];
					end
					state <= S_SPR_CHECK2;
				end
				// One extra cycle so `spr_byte_addr`/`sprites_byte` (combinational,
				// downstream of a registered `s_byte_addr`) has settled before
				// this state reads it.
				S_SPR_CHECK2: begin
					s_pix_nib = tile_nibble(sprites_byte, s_px[0]);
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT;
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						sx = s_pixel_x_base + s_px;
						sy = s_pixel_y_base + s_py;
						if (sx < SCREEN_W && sy < SCREEN_H)
							sprite_plane[draw_buf][sy * SCREEN_W + sx] <= {1'b1, s_colour[4:0], s_pix_nib[3:0]};
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
