// bjtwin-family video pipeline, PROTECTED variant (Family D: bjtwin/
// bjtwina/bjtwinpa/sabotenb/sabotenba/nouryoku — NMK-215/TMP90840 +
// dual NMK214 descramblers, see rtl/bjtwin/bjtwin_prot_core.sv's own
// header). A near-copy of the already-verified rtl/bjtwin/video_bjtwin.sv
// (Tier 1's unprotected cactus/bjtwinp/nouryokup target, unchanged by
// this file — kept as a separate module rather than parameterized,
// matching this project's own established per-game-variant convention,
// e.g. video_macross.sv/video_gunnail.sv are their own files too), with
// exactly one structural difference: BG-tile and sprite ROM fetches are
// routed through two live `nmk214` instances before use (fgtile is NOT
// descrambled — confirmed the same for every other Family D game this
// session, `base_nmk214_215()` only ever wires up "sprites" and "bg" GFX
// regions, `nmk16.cpp`'s own `nmk214_sprites_address_bitswap`/
// `nmk214_bg_address_bitswap` are shared, non-game-specific constants
// reused verbatim from rtl/macross/video_macross.sv's own instantiation).
//
// BG addressing here is bjtwin's own *8x8* single-plane format (`code*32
// + row*4 + (col>>1)`, identical in shape to fgtile_pixel's own formula
// below, just a different ROM) — NOT macross's own 16x16 col_2x2_group
// BG format (macross has separate 8x8 FG/16x16 BG layers; bjtwin has
// only one 8x8 tilemap total). Sprite addressing IS the same 128-byte/
// 16x16-unit col_2x2_group format as macross's own, so the sprite
// descramble wiring below (including the extra S_SPR_CHECK2 pipeline
// stage needed for nmk214's own combinational-but-address-driven output
// to settle) is copied from video_macross.sv's own, already-verified
// pattern nearly verbatim.
module video_bjtwin_prot #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger,

	input        nmk214_cfg_we,
	input  [7:0] nmk214_cfg_data,

	output [10:0] bgvram_addr,
	input  [15:0] bgvram_data,
	output [9:0]  palette_addr,
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr,
	input  [15:0] spr_palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,

	input [7:0] tilebank_reg,
	input [7:0] scroll_y_reg,

	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb,

	input  [10:0] dbg_snap_addr,
	output [15:0] dbg_snap_data
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92;
	localparam integer MAX_SPRITE_CLOCK = 134656;

	// ------------------------------------------------------------------
	// Graphics ROMs — bgtile/sprites hold the RAW (still-scrambled) ROM
	// content, same as video_macross.sv's own convention; descrambling
	// happens per-fetch below.
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:65535];
	reg [7:0] bgtile_rom  [0:2097151];
	reg [7:0] sprites_rom [0:2097151];
	initial if (FGTILE_FILE  != "") $readmemh(FGTILE_FILE,  fgtile_rom);
	initial if (BGTILE_FILE  != "") $readmemh(BGTILE_FILE,  bgtile_rom);
	initial if (SPRITES_FILE != "") $readmemh(SPRITES_FILE, sprites_rom);

	function automatic [3:0] tile_nibble(input [7:0] byte_val, input col_odd);
		tile_nibble = col_odd ? byte_val[3:0] : byte_val[7:4];
	endfunction

	function automatic [3:0] fgtile_pixel(input integer code, input integer row, input integer col);
		integer byte_addr;
		begin
			byte_addr = code * 32 + row * 4 + (col >> 1);
			fgtile_pixel = tile_nibble(fgtile_rom[byte_addr[15:0]], col[0]);
		end
	endfunction

	// ------------------------------------------------------------------
	// BG tile-fetch address, a plain wire (not buried in a function) so
	// it can drive the nmk214 BG instance's own `addr` input directly —
	// see module header. Same 8x8 linear layout as fgtile_pixel above.
	// ------------------------------------------------------------------
	function automatic [20:0] bgtile_addr(input integer code, input integer row, input integer col);
		bgtile_addr = (code * 32 + row * 4 + (col >> 1)) & 21'h1FFFFF;
	endfunction

	wire [20:0] bg_byte_addr = bgtile_addr(int'(bgvram_data[10:0]) + (int'(tilebank_reg) << 11), int'(t_py), int'(t_px));
	wire [7:0]  bgtile_raw_byte = bgtile_rom[bg_byte_addr];
	wire [7:0]  bgtile_descrambled_byte;

	nmk214 #(
		.MODE(1'b1), // BG instance — nmk16_v.cpp: m_nmk214[1], "BG GFX data"
		.ADDR_WIDTH(21),
		// nmk214_bg_address_bitswap, nmk16.cpp:5684 — LSB-first (index i = ADDR_BITSWAP[i])
		.ADDR_BITSWAP({5'd20,5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd11,5'd3,5'd2,5'd1,5'd0})
	) nmk214_bg (
		.clk(clk_sys), .reset(reset),
		.cfg_we(nmk214_cfg_we), .cfg_data(nmk214_cfg_data), .initialized(),
		.addr(bg_byte_addr), .din(16'h0), .dout_word(),
		.din8(bgtile_raw_byte), .dout_byte(bgtile_descrambled_byte)
	);

	// ------------------------------------------------------------------
	// Sprite tile-fetch address — WORD-addressed for the nmk214 sprite
	// instance, same gfx_8x8x4_col_2x2_group_packed_msb (128 bytes/
	// 16x16 unit) layout as video_macross.sv's own sprite plane.
	// ------------------------------------------------------------------
	wire [20:0] spr_byte_addr;
	wire [19:0] spr_word_addr = spr_byte_addr[20:1];
	wire [15:0] sprites_raw_word = {sprites_rom[{spr_word_addr,1'b0}], sprites_rom[{spr_word_addr,1'b0} + 21'd1]}; // get_u16be
	wire [15:0] sprites_descrambled_word;

	nmk214 #(
		.MODE(1'b0), // sprite instance — nmk16_v.cpp: m_nmk214[0], "sprite GFX data"
		.ADDR_WIDTH(21),
		// nmk214_sprites_address_bitswap, nmk16.cpp:5683
		.ADDR_BITSWAP({5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd12,5'd10,5'd3,5'd2,5'd1,5'd0})
	) nmk214_spr (
		.clk(clk_sys), .reset(reset),
		.cfg_we(nmk214_cfg_we), .cfg_data(nmk214_cfg_data), .initialized(),
		.addr({1'b0, spr_word_addr}), .din(sprites_raw_word), .dout_word(sprites_descrambled_word),
		.din8(8'h0), .dout_byte()
	);
	wire [7:0] sprites_descrambled_byte = spr_byte_addr[0] ? sprites_descrambled_word[7:0] : sprites_descrambled_word[15:8];

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
	// Tilemap: pure per-pixel combinational function of (rd_x, rd_y) —
	// unchanged from video_bjtwin.sv's own.
	// ------------------------------------------------------------------
	wire [8:0] tile_line_x = (rd_x + (512 - VIDEOSHIFT)) % 512;
	wire [7:0] tile_line_y = (rd_y + scroll_y_reg) % 256;
	wire [5:0] t_col = tile_line_x[8:3];
	wire [2:0] t_px  = tile_line_x[2:0];
	wire [4:0] t_row = tile_line_y[7:3];
	wire [2:0] t_py  = tile_line_y[2:0];

	assign bgvram_addr = {t_col, t_row}; // COL-scan: index = col*32+row

	wire [3:0] t_pix_nib = bgvram_data[11]
		? tile_nibble(bgtile_descrambled_byte, t_px[0])
		: fgtile_pixel(int'(bgvram_data[10:0]), int'(t_py), int'(t_px));

	assign palette_addr = {bgvram_data[15:12], t_pix_nib};
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM snapshot
	// ------------------------------------------------------------------
	reg [15:0] sprite_snap [0:2047];
	assign dbg_snap_data = sprite_snap[dbg_snap_addr];
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered — unchanged from video_bjtwin.sv's own.
	// ------------------------------------------------------------------
	reg [10:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1];
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [10:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 11'd0;
	wire        spr_valid = spr_entry[10];

	assign spr_palette_addr = 10'h100 + {6'd0, spr_entry[9:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	assign rd_rgb = !rd_in_range ? 24'h0 : (spr_valid ? spr_rgb : tile_rgb);

	// ------------------------------------------------------------------
	// Sprite draw FSM: snapshot -> clear -> walk -> swap, same
	// MAME-verified clock budget as video_bjtwin.sv's own, plus one
	// extra pipeline stage (S_SPR_CHECK2) so nmk214's own combinational-
	// but-address-driven sprite output settles before it's read — see
	// video_macross.sv's own identical S_SPR_CHECK/S_SPR_CHECK2 split
	// for the full derivation.
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
	reg        draw_buf;

	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;
	reg [20:0] s_byte_addr;
	assign spr_byte_addr = s_byte_addr;

	always @(posedge clk_sys) begin
		if (reset) begin
			state    <= S_RESET_CLR0;
			clr_idx  <= 17'd0;
			disp_buf <= 1'b0;
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

				S_SNAP_REQ: begin
					mainram_addr <= 15'h4000 + snap_idx[10:0];
					state <= S_SNAP_LATCH;
				end
				S_SNAP_LATCH: begin
					sprite_snap[snap_idx] <= mainram_data;
					if (snap_idx == 12'd2047) begin
						draw_buf <= ~disp_buf;
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

				S_SPR_HEAD: begin
					begin : spr_head_blk
						integer offs;
						reg [15:0] w0, w1, w3, w4, w6, w7;
						integer budget_after_scan, budget_after_draw;
						integer w, h;

						offs = s_slot * 8;
						w0 = sprite_snap[offs + 0];
						w1 = sprite_snap[offs + 1];
						w3 = sprite_snap[offs + 3];
						w4 = sprite_snap[offs + 4];
						w6 = sprite_snap[offs + 6];
						w7 = sprite_snap[offs + 7];
						w = w1[3:0];
						h = w1[7:4];

						budget_after_scan = clk_budget + 16;
						budget_after_draw = budget_after_scan + 128 * (w + 1) * (h + 1);

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
							s_colour <= w7[5:0];
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
						s_byte_addr <= byte_addr[20:0];
					end
					state <= S_SPR_CHECK2;
				end
				// One extra cycle so spr_byte_addr/sprites_descrambled_byte
				// (combinational, but downstream of a registered
				// s_byte_addr and nmk214's own address-driven output) has
				// settled — see video_macross.sv's own identical comment.
				S_SPR_CHECK2: begin
					s_pix_nib = tile_nibble(sprites_descrambled_byte, s_px[0]);
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT;
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						sx = s_pixel_x_base + s_px;
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
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
