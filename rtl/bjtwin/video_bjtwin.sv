// bjtwin-family video pipeline: single COL-scan 8x8 tilemap + nmk16spr
// sprite compositor. Built and verified against MAME's exact algorithms
// per docs/tier1-bjtwin.md:
//   - tile decode: nmk16_v.cpp bjtwin_get_bg_tile_info + gfx_8x8x4_packed_msb
//   - sprite decode: nmk16spr.cpp draw_sprites() + gfx_8x8x4_col_2x2_group_packed_msb
//   - palette: palette_device::RRRRGGGGBBBBRGBx_decoder (emupal.cpp:811)
//
// Real-time, scanline-synchronized architecture (replaces the earlier
// per-frame procedural-FSM draft — see git history / docs/tier1-bjtwin.md
// for that version's role in first proving the decode algorithms bit-exact
// before this rework):
//
//   - Tilemap: MAME never models tile-fetch bandwidth limits for this
//     family (no clock-budget/drop-out logic in the source, unlike
//     sprites), so there's nothing to synchronize to a raster clock —
//     tile decode is instead a pure, stateless per-pixel combinational
//     function of (x, y, scroll_y_reg, tilebank_reg), addressing bgvram
//     and the tile-palette tap directly. Real hardware would drive this
//     from a live hcount/vcount at one pixel per pixel-clock; in
//     simulation it's driven by the rd_x/rd_y readback ports the same
//     way, since both are the same combinational chain.
//
//     This rewrite also fixes a real wraparound bug in the old sweep: the
//     tilemap is a 64x32-tile (512x256px) toroidal surface (confirmed via
//     nmk16_v.cpp's tilemap_create(..., 8, 8, 64, 32) + bjtwin_scroll_w's
//     set_scrolly(0, -data), which MAME's tilemap system always wraps).
//     The old code derived screen position from tile position and only
//     kept results landing in the visible window without ever wrapping
//     the *source* row — for scroll_y_reg values past roughly 32, most of
//     the screen got zero tile coverage per frame (stale/undefined
//     pixels) instead of wrapped tile content. Inverting the direction —
//     deriving source tile position from screen position via mod-256 (Y)
//     / mod-512 (X) wraparound — gives full coverage for any scroll value
//     and is also the natural formulation for a live per-pixel raster
//     fetch. Never exercised by the captured verification trace (which
//     stayed near scroll_y_reg==0), so this doesn't invalidate anything
//     already verified — it closes a gap that verification never reached.
//
//   - Sprites: nmk16spr *does* model a real per-frame clock budget
//     (m_max_sprite_clock / MAX_SPRITE_CLOCK below) that silently drops
//     late sprites — that's the part that actually needs to behave like
//     real hardware's bandwidth-limited draw engine, decoupled from
//     display so a redraw in progress never tears the frame currently
//     being shown. Implemented as a double-buffered sprite plane: one
//     buffer (disp_buf) is read for display/readback while the other is
//     being rebuilt by the budget-walked draw FSM below, triggered by
//     sprite_dma_trigger (same mainram->sprite_snap DMA snapshot as
//     before); the buffers swap atomically the instant a draw pass
//     finishes. The draw FSM's per-sprite/per-pixel cost accounting is
//     unchanged from the already MAME-oracle-verified version — only the
//     destination (a plane slot instead of a shared framebuffer) and the
//     removal of a mid-draw palette dependency (see below) changed.
//
//     Sprite pixels store a 10-bit raw palette index (colour<<4|pen),
//     not pre-decoded RGB, and are decoded from the *live* palette tap at
//     read time — matching MAME's own model, where draw_sprites() reads
//     whatever palette content currently exists at screen_update() time,
//     which is unrelated to when the sprite position/tile data was
//     DMA'd. This also means the draw FSM itself never needs to touch
//     the palette at all (the pen==15 transparency test only needs the
//     sprite ROM's own pixel value, confirmed via nmk16spr.cpp's
//     drawgfx(...,15) transpen call) — one less external RAM port to
//     arbitrate during drawing.
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
//
// Known simplification carried forward: storage bit widths are still
// generously sized rather than hand-fit for BRAM inference/area budgeting
// on real Cyclone V hardware (e.g. the two 86016-entry sprite planes,
// ~1.9Mbit total, are plain reg arrays with combinational read ports).
// Getting the timing MODEL right (this rework) comes before that tuning
// pass, per docs/PLAN.md's verification-first methodology. There is also
// still no live hsync/vsync/RGB output pin — that's the separate
// MiSTer sys/ integration milestone, not implied by this rework.
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
	output [10:0] bgvram_addr,
	input  [15:0] bgvram_data,
	output [9:0]  palette_addr,   // tile-plane palette tap (live, per-pixel)
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only, see header)
	input  [15:0] spr_palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,

	input [7:0] tilebank_reg,
	input [7:0] scroll_y_reg,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb,

	// sprite_snap readback for the testbench, to verify against MAME's
	// m_spriteram_old (see docs/tier1-bjtwin.md "sprite_dma() buffer
	// verification" — that buffer is a host-memory copy in MAME, never a
	// CPU bus transaction, so it needs this kind of direct internal-state
	// comparison rather than a bus trace)
	input  [10:0] dbg_snap_addr,
	output [15:0] dbg_snap_data
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
	// Tilemap: pure per-pixel combinational function of (rd_x, rd_y),
	// see module header. No FSM, no framebuffer — real hardware would
	// drive the same chain from a live hcount/vcount instead.
	// ------------------------------------------------------------------
	wire [8:0] tile_line_x = (rd_x + (512 - VIDEOSHIFT)) % 512; // toroidal, 64 cols x 8px
	wire [7:0] tile_line_y = (rd_y + scroll_y_reg) % 256;       // toroidal, 32 rows x 8px
	wire [5:0] t_col = tile_line_x[8:3];
	wire [2:0] t_px  = tile_line_x[2:0];
	wire [4:0] t_row = tile_line_y[7:3];
	wire [2:0] t_py  = tile_line_y[2:0];

	assign bgvram_addr = {t_col, t_row}; // COL-scan: index = col*32+row

	wire [3:0] t_pix_nib = bgvram_data[11]
		? bgtile_pixel(int'(bgvram_data[10:0]) + (int'(tilebank_reg) << 11), int'(t_py), int'(t_px))
		: fgtile_pixel(int'(bgvram_data[10:0]), int'(t_py), int'(t_px));

	assign palette_addr = {bgvram_data[15:12], t_pix_nib};
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM snapshot (per docs/tier1-bjtwin.md sprite_dma() writeup)
	// ------------------------------------------------------------------
	reg [15:0] sprite_snap [0:2047]; // 256 sprites x 8 words
	assign dbg_snap_data = sprite_snap[dbg_snap_addr];
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered, see module header. Bit[10]=valid
	// (opaque sprite pixel drawn this pass), bits[9:0]=raw palette index
	// (colour<<4|pen), decoded from the live palette tap at read time.
	// ------------------------------------------------------------------
	reg [10:0] sprite_plane [0:1][0:SCREEN_W*SCREEN_H-1];
	reg        disp_buf; // which buffer is currently valid for display/readback

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);
	wire [10:0] spr_entry = rd_in_range ? sprite_plane[disp_buf][rd_addr] : 11'd0;
	wire        spr_valid = spr_entry[10];

	assign spr_palette_addr = 10'h100 + {6'd0, spr_entry[9:0]}; // truncates to 10 bits, same wraparound as the original single-tap formula it replaces
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	assign rd_rgb = !rd_in_range ? 24'h0 : (spr_valid ? spr_rgb : tile_rgb);

	// ------------------------------------------------------------------
	// Sprite draw FSM: snapshot -> clear the non-displayed plane -> walk
	// sprite_snap in slot order under the same MAME-verified clock
	// budget as before -> swap buffers. Fully decoupled from frame_done
	// (now generated directly off the raster counter in bjtwin_core.sv)
	// and from the tilemap path above (no shared state).
	// ------------------------------------------------------------------
	localparam
		S_RESET_CLR0 = 0, // power-on: clear buffer 0 (the initial disp_buf)
		S_RESET_CLR1 = 1, // power-on: clear buffer 1
		S_IDLE        = 2,
		S_SNAP_REQ    = 3,
		S_SNAP_LATCH  = 4,
		S_CLEAR       = 5, // per-pass: clear the buffer about to be (re)drawn
		S_SPR_HEAD    = 6,
		S_SPR_UNIT    = 7,
		S_SPR_CHECK   = 8,
		S_SPR_PLOT    = 9,
		S_SPR_NEXT    = 10,
		S_DONE        = 11;

	reg [3:0]  state;
	reg [16:0] clr_idx;
	reg        draw_buf; // = ~disp_buf for the duration of one draw pass

	// sprite walk
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

				// snapshot mainram[0x8000+i] -> sprite_snap[i], i=0..2047
				S_SNAP_REQ: begin
					mainram_addr <= 15'h4000 + snap_idx[10:0]; // 0x8000 bytes / 2 = 0x4000 word offset
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

				// ---------------- sprites ----------------
				// One slot examined per cycle (matching MAME's "clk += 16
				// per sprite examined" cost at the granularity of one
				// state per slot, not one state per host clock).
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
					state <= S_SPR_CHECK;
				end

				S_SPR_CHECK: begin
					s_pix_nib = sprite_pixel(s_unit_code, s_py, s_px);
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT; // pen15 = transparent, skip plot
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
							state <= S_SPR_CHECK;
						end
					end else begin
						s_px <= s_px + 1;
						state <= S_SPR_CHECK;
					end
				end

				S_DONE: begin
					disp_buf <= draw_buf; // atomic swap: draw_buf is now ready for display
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
