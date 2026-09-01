// bjtwin-family video pipeline: single COL-scan 8x8 tilemap + nmk16spr
// sprite compositor, driven by a per-frame procedural render (NOT yet a
// real-time scanline-synchronized hardware pipeline — see the "Known
// simplification" note below). Built and verified against MAME's exact
// algorithms per docs/tier1-bjtwin.md:
//   - tile decode: nmk16_v.cpp bjtwin_get_bg_tile_info + gfx_8x8x4_packed_msb
//   - sprite decode: nmk16spr.cpp draw_sprites() + gfx_8x8x4_col_2x2_group_packed_msb
//   - palette: palette_device::RRRRGGGGBBBBRGBx_decoder (emupal.cpp:811)
//
// Known simplification: this module computes an entire frame procedurally
// (a multi-cycle FSM walking every tile then every sprite into a full
// 384x224 framebuffer, using generously-wide scratch registers rather
// than hand-fitted bit widths) rather than rendering in real time
// synchronized to video_timing's hcount/vcount. That's the right order
// of operations for this milestone — prove the decode/compositing
// algorithms bit-exact against the MAME oracle first — but it is NOT
// synthesizable as final hardware: a real core needs a line-buffered
// raster renderer respecting actual tile/sprite ROM read bandwidth per
// scanline, and tightened bit widths throughout. Re-architecting for
// real-time output is follow-up work once this algorithm is verified.
//
// bjtwin-specific compositing facts (verified from nmk16_v.cpp, not
// assumed): m_bg_tilemap->draw(..., 0, 1) writes priority value 1 for
// opaque tilemap pixels; sprites use pri_mask=GFX_PMASK_2 (bit1). Since
// (1 & 2) == 0, sprites ALWAYS draw over the tilemap for this family —
// no real priority-bitmap logic is needed here. bjtwin/cactus never call
// set_ext_callback, so nmk16spr's flipx/flipy are unconditionally 0 for
// every sprite — no flip logic is needed either. Both simplifications
// are specific to this hardware family, not general nmk16spr behavior.
// Position wraparound: sprite X/Y are masked to 9 bits (xmask/ymask =
// 0x1ff) at extraction, so (position + tile_offset) naturally wraps
// modulo 512 via a plain 9-bit truncation — verified equivalent to
// nmk16spr.cpp's scattered +=/-= xpos_max checks for the range of values
// this hardware can produce (see docs/tier1-bjtwin.md derivation).
module video_bjtwin #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = ""
) (
	input clk_sys,
	input reset,

	input sprite_dma_trigger, // from nmk_irq_hacky: snapshot sprite RAM now

	// register/RAM read ports into bjtwin_core's storage (dual-tap reads,
	// bjtwin_core.sv owns the arrays; see its header for why)
	output reg [10:0] bgvram_addr,
	input      [15:0] bgvram_data,
	output reg [9:0]  palette_addr,
	input      [15:0] palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,

	input [7:0] tilebank_reg,
	input [7:0] scroll_y_reg,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb,

	output reg frame_done // pulses for one clk_sys cycle when a new frame is ready to read
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // 28+64, see docs/tier1-bjtwin.md screen/video config
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, see nmk16spr.cpp set_max_sprite_clock

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py)
	// ------------------------------------------------------------------
	reg [7:0] fgtile_rom  [0:65535];
	reg [7:0] bgtile_rom  [0:2097151];
	reg [7:0] sprites_rom [0:2097151];
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
			fgtile_pixel = tile_nibble(fgtile_rom[byte_addr[15:0]], col[0]);
		end
	endfunction

	function automatic [3:0] bgtile_pixel(input integer code, input integer row, input integer col);
		integer byte_addr;
		begin
			byte_addr = code * 32 + row * 4 + (col >> 1);
			bgtile_pixel = tile_nibble(bgtile_rom[byte_addr[20:0]], col[0]);
		end
	endfunction

	// gfx_8x8x4_col_2x2_group_packed_msb: 128 bytes/16x16 unit; left half
	// (col 0-7) at +0, right half (col 8-15) at +64; row spans 0-15
	// through both halves uniformly (see module header derivation).
	function automatic [3:0] sprite_pixel(input integer code, input integer row, input integer col);
		integer byte_addr;
		integer half_offset;
		integer col_local;
		begin
			half_offset = (col >= 8) ? 64 : 0;
			col_local = col & 7;
			byte_addr = code * 128 + half_offset + row * 4 + (col_local >> 1);
			sprite_pixel = tile_nibble(sprites_rom[byte_addr[20:0]], col_local[0]);
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
	// Framebuffer (simulation-only storage, see header note)
	// ------------------------------------------------------------------
	reg [23:0] framebuf [0:SCREEN_W*SCREEN_H-1];

	assign rd_rgb = (rd_x < SCREEN_W && rd_y < SCREEN_H) ? framebuf[rd_y * SCREEN_W + rd_x] : 24'h0;

	// ------------------------------------------------------------------
	// Sprite RAM snapshot (single-buffered, per docs/tier1-bjtwin.md)
	// ------------------------------------------------------------------
	reg [15:0] sprite_snap [0:2047]; // 256 sprites x 8 words
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Render FSM
	// ------------------------------------------------------------------
	localparam
		S_IDLE        = 0,
		S_SNAP_REQ    = 1,
		S_SNAP_LATCH  = 2,
		S_TILE_REQ    = 3,
		S_TILE_LATCH  = 4,
		S_TILE_PALREQ = 5,
		S_TILE_PLOT   = 6,
		S_TILE_NEXT   = 7,
		S_SPR_HEAD    = 8,
		S_SPR_UNIT    = 9,
		S_SPR_PALREQ  = 10,
		S_SPR_PLOT    = 11,
		S_SPR_NEXT    = 12,
		S_DONE        = 13;

	reg [3:0] state;

	// tilemap walk
	integer t_col, t_row, t_px, t_py;
	reg [15:0] t_word;
	integer t_pix_nib;

	// sprite walk
	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base, s_screen_x, s_screen_y;
	integer s_pix_nib;

	always @(posedge clk_sys) begin
		frame_done <= 1'b0;

		if (reset) begin
			state <= S_IDLE;
			snap_pending <= 1'b0;
		end else begin
			if (sprite_dma_trigger) snap_pending <= 1'b1;

			case (state)
				S_IDLE: begin
					if (snap_pending) begin
						snap_pending <= 1'b0;
						snap_idx <= 12'd0;
						state <= S_SNAP_REQ;
					end
				end

				// snapshot mainram[0x8000+i] -> sprite_snap[i], i=0..2047
				S_SNAP_REQ: begin
					mainram_addr <= 15'h4000 + snap_idx[10:0]; // 0x8000 bytes / 2 = 0x4000 word offset
					state <= S_SNAP_LATCH;
				end
				S_SNAP_LATCH: begin
					sprite_snap[snap_idx] <= mainram_data;
					if (snap_idx == 12'd2047) begin
						t_col <= 0; t_row <= 0; t_px <= 0; t_py <= 0;
						state <= S_TILE_REQ;
					end else begin
						snap_idx <= snap_idx + 12'd1;
						state <= S_SNAP_REQ;
					end
				end

				// one tile-code fetch per tile (COL-scan: index = col*32+row)
				S_TILE_REQ: begin
					bgvram_addr <= t_col * 32 + t_row;
					state <= S_TILE_LATCH;
				end
				S_TILE_LATCH: begin
					t_word <= bgvram_data;
					state <= S_TILE_PALREQ;
				end
				S_TILE_PALREQ: begin
					if (t_word[11]) begin
						t_pix_nib = bgtile_pixel(int'(t_word[10:0]) + (int'(tilebank_reg) << 11), t_py, t_px);
					end else begin
						t_pix_nib = fgtile_pixel(int'(t_word[10:0]), t_py, t_px);
					end
					palette_addr <= {t_word[15:12], t_pix_nib[3:0]};
					state <= S_TILE_PLOT;
				end
				S_TILE_PLOT: begin
					begin : tile_plot_blk
						integer sx, sy;
						sx = t_col * 8 + VIDEOSHIFT + t_px;
						sy = t_row * 8 + t_py - int'(scroll_y_reg);
						sx = sx % 512;
						sy = sy % 512;
						if (sx >= 0 && sx < SCREEN_W && sy >= 0 && sy < SCREEN_H)
							framebuf[sy * SCREEN_W + sx] <= decode_rgb(palette_data);
					end
					state <= S_TILE_NEXT;
				end
				S_TILE_NEXT: begin
					if (t_px == 7) begin
						t_px <= 0;
						if (t_py == 7) begin
							t_py <= 0;
							if (t_row == 31) begin
								t_row <= 0;
								if (t_col == 63) begin
									s_slot <= 0;
									clk_budget <= 0;
									state <= S_SPR_HEAD;
								end else begin
									t_col <= t_col + 1;
									state <= S_TILE_REQ;
								end
							end else begin
								t_row <= t_row + 1;
								state <= S_TILE_REQ;
							end
						end else begin
							t_py <= t_py + 1;
							state <= S_TILE_REQ;
						end
					end else begin
						t_px <= t_px + 1;
						state <= S_TILE_REQ;
					end
				end

				// ---------------- sprites ----------------
				// One slot examined per cycle (matching MAME's "clk += 16
				// per sprite examined" cost at the granularity of one
				// state per slot, not one state per host clock — see
				// module header re: this being a simulation-only FSM).
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
							// invisible: doesn't cost the draw budget, just move on
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
					state <= S_SPR_PALREQ;
				end

				S_SPR_PALREQ: begin
					s_pix_nib = sprite_pixel(s_unit_code, s_py, s_px);
					if (s_pix_nib != 15) begin
						palette_addr <= 10'h100 + (s_colour << 4) + s_pix_nib[3:0];
						state <= S_SPR_PLOT;
					end else begin
						state <= S_SPR_NEXT; // pen15 = transparent, skip plot
					end
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						sx = s_pixel_x_base + s_px;
						sy = s_pixel_y_base + s_py;
						if (sx < SCREEN_W && sy < SCREEN_H)
							framebuf[sy * SCREEN_W + sx] <= decode_rgb(palette_data);
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
									// done with this sprite, next slot
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
							state <= S_SPR_PALREQ;
						end
					end else begin
						s_px <= s_px + 1;
						state <= S_SPR_PALREQ;
					end
				end

				S_DONE: begin
					frame_done <= 1'b1;
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
