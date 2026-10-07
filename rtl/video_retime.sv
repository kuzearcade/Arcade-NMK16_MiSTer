// Video output retimer (2026-09-11, docs/known-issues.md NMK-18).
//
// The shared Family C core draws its raster on clk_sys (40 MHz) with an
// 8 MHz pixel enable: 512 pixels per 64 us line, the hi-res boards'
// exact geometry (16 MHz/2, HTOTAL 512). Power Instinct's board runs
// 448 pixels per line at 7 MHz (14 MHz/2, set_screen_midres) — the same
// 64 us line, so every interrupt, DMA and frame is exact — but 40 MHz
// has no integer 7 MHz enable, and a fractional one (40/7) would make
// alternate pixels 125 and 150 ns wide on an analog monitor. This
// module re-clocks the picture instead: the core's pixels are written
// into a two-line buffer as they are drawn, and read back on clk_r
// (56 MHz, rtl/pll_video.v) at an exact 8 MHz (/7) or 7 MHz (/8) pixel
// rate — 3584 clk_r per line either way, the same 64 us — one line
// behind the write side, with sync/blanking regenerated here in the
// board's own pixel units (H/V Shift trims included). CLK_VIDEO/
// CE_PIXEL/VGA_* then carry the PCB's pixel clock to the framework's
// scaler and analog output.
//
// Phase: the read side free-runs on its own counters (exactly rate-
// matched, both PLLs lock to the same 50 MHz) and is placed once on the
// first synchronised write-side frame start; every later frame start is
// checked against the expected read position and only a gross error
// (> 32 clk_r, i.e. a mode change, a restart or a lost frame) reloads
// it, so the sync outputs never take a per-frame jitter step.
//
// Buffer parity is the line number's LSB on both sides (VTOTAL 278 is
// even, so the parity sequence is consistent across the frame wrap):
// line L is written into buf[L&1] during write line L and read back
// during write line L+1, while the writer fills buf[(L+1)&1].
// Parameters (2026-09-11, the Gunnail rbf): the two modes' geometry and
// the clk_r count per line are parameters — the defaults are the
// Macross2 rbf's (56 MHz clk_r: 512 px / 7 and 448 px / 8); NMK16_Gunnail.sv
// passes a 48 MHz set (512 px / 6 for gunnail, 384 px / 8 for the lowres
// boards, 3072 clk_r per line). mode1 selects the second set.
module video_retime #(
	parameter [9:0] M0_X0 = 10'd28,  M0_HT = 10'd512, M0_HS = 10'd440, M0_HW = 10'd32, M0_AW = 10'd384,
	parameter [4:0] M0_DIV = 5'd14,
	parameter [9:0] M1_X0 = 10'd60,  M1_HT = 10'd448, M1_HS = 10'd404, M1_HW = 10'd28, M1_AW = 10'd320,
	parameter [4:0] M1_DIV = 5'd16,
	parameter integer LINE_CLKS = 7168   // clk_r per line: M0_HT*M0_DIV == M1_HT*M1_DIV
) (
	// write side — the core's raster
	input         clk_w,
	input         reset_w,
	input         ce_w,             // 8 MHz pixel enable
	input  [9:0]  hcount_w,         // 0..511, steps at ce_w
	input  [9:0]  vcount_w,         // 0..277, steps at the hcount wrap
	input  [23:0] rgb_w,            // pixel hcount_w-x0 of line vcount_w, sampled at ce_w
	input         mode1,            // 1: the M1_* geometry (powerins / lowres); 0: M0_*
	// manybloc's 240-line window (raster lines 8..247 instead of 16..239);
	// VTOTAL and the line period are unchanged, so only the vertical
	// active window and the vblank-relative vsync placement move.
	input         tall240,

	// read side — the framework's video clock
	input         clk_r,
	output reg    ce_r,
	output reg [23:0] rgb_r,
	output reg    hs_r,
	output reg    vs_r,
	output reg    de_r,
	// Separate blanks for sys/video_mixer.sv (HQ2X/scandoubler), which
	// needs the two axes independently -- de_r alone cannot be split.
	output reg    hb_r,
	output reg    vb_r,
	// VBlank with its edges moved onto the hsync start, for rtl/crt_chain.sv:
	// crt_adjust samples VBlank at each HSync rise and applies it to the
	// active window that FOLLOWS that pulse. Where the pulse sits after the
	// active area (hires: sync at 440, active from 28 of the next row) the
	// native vb_r still shows the current row there, so the module would
	// blank the first active row; this output already reads as the next
	// row's blanking from the END of the active area on, so it holds for
	// the nominal pulse and for one moved by H-Position (as long as the
	// pulse stays out of the picture). Where the pulse precedes the active
	// area on the same row (lowres: sync at 20, active from 92) that is
	// the same as vb_r at the pulse. Off-path consumers keep vb_r.
	output reg    vb_hs_r,
	// (NMK-40) flips once a frame, a quarter of a line after where the read side
	// expects the core's frame to start: the top ends the core's reset on it
	output reg    rel_tog = 1'b0,
	// lines from the end of the core's reset to its first frame start (its
	// raster's reset line to the frame's end; static, from clk_w): rel_tog
	// comes that many lines earlier
	input  [9:0]  rel_lead
);

	// Geometry per mode (bitmap coordinates in the board's own pixel
	// units; the write side always uses the 512-px raster's window).
	localparam [9:0] W_X0_8 = M0_X0,  W_X0_7 = M1_X0;    // write-side active start (core raster)
	localparam [9:0] R_X0_8 = M0_X0,  R_X0_7 = M1_X0;    // read-side active start
	localparam [9:0] R_HT_8 = M0_HT,  R_HT_7 = M1_HT;    // read-side HTOTAL
	localparam [9:0] R_HS_8 = M0_HS,  R_HS_7 = M1_HS;    // nominal hsync start (3.5 us after active end)
	localparam [9:0] R_HW_8 = M0_HW,  R_HW_7 = M1_HW;    // hsync width (4 us)
	localparam [9:0] AW_8   = M0_AW,  AW_7   = M1_AW;    // active width
	localparam [4:0] DIV_8  = M0_DIV, DIV_7  = M1_DIV;   // clk_r per pixel (5 bits: may be 16)
	localparam [9:0] VTOTAL = 10'd278;
	wire [9:0] v_start = tall240 ? 10'd8   : 10'd16;
	wire [9:0] v_end   = tall240 ? 10'd248 : 10'd240;   // exclusive: the first vblank line
	wire [9:0] v_blank = VTOTAL - v_end;                // lines of vblank (30 / 38)

	// ------------------------------------------------------------------
	// Write side
	// ------------------------------------------------------------------
	reg [23:0] buf_mem [0:1023];  // 2 lines x 512 slots (index = {line parity, x[8:0]}; x < 384)
	wire [9:0] w_x0   = mode1 ? W_X0_7 : W_X0_8;
	wire [9:0] w_aw   = mode1 ? AW_7   : AW_8;
	wire [9:0] w_x    = hcount_w - w_x0;
	wire       w_act  = (hcount_w >= w_x0) && (w_x < w_aw) && (vcount_w >= v_start) && (vcount_w < v_end);
	reg        frame_tog = 1'b0;   // toggles at each write-side frame start
	always @(posedge clk_w) begin
		if (ce_w && w_act) buf_mem[{vcount_w[0], w_x[8:0]}] <= rgb_w;
		if (ce_w && hcount_w == 10'd0 && vcount_w == 10'd0) frame_tog <= ~frame_tog;
	end

	// ------------------------------------------------------------------
	// Read side
	// ------------------------------------------------------------------
	reg [2:0] ftog_sync = 3'b000;
	always @(posedge clk_r) ftog_sync <= {ftog_sync[1:0], frame_tog};
	wire frame_edge = ftog_sync[2] ^ ftog_sync[1];

	reg  [1:0] mode_sync = 2'b00;
	always @(posedge clk_r) mode_sync <= {mode_sync[0], mode1};
	wire       m7 = mode_sync[1];
	// tall240 crossed into clk_r the same way mode1 is (both are static
	// per session, but the read side must not sample a metastable value).
	reg  [1:0] tall_sync = 2'b00;
	always @(posedge clk_r) tall_sync <= {tall_sync[0], tall240};
	wire [9:0] v_start_r = tall_sync[1] ? 10'd8   : 10'd16;
	wire [9:0] v_end_r   = tall_sync[1] ? 10'd248 : 10'd240;
	wire [9:0] v_blank_r = VTOTAL - v_end_r;
	wire [9:0] r_x0 = m7 ? R_X0_7 : R_X0_8;
	wire [9:0] r_ht = m7 ? R_HT_7 : R_HT_8;
	wire [9:0] r_aw = m7 ? AW_7   : AW_8;
	wire [4:0] r_div = m7 ? DIV_7 : DIV_8;

	// Sync placement is nominal: the former OSD H/V Shift trims that moved
	// these pulses were replaced on 2026-09-18 by the CRT Adjust chain
	// (rtl/crt_chain.sv), which shifts sync downstream of this module.
	wire [9:0] hs_start  = m7 ? R_HS_7 : R_HS_8;
	wire [9:0] hs_width  = m7 ? R_HW_7 : R_HW_8;
	wire [9:0] vs_rel    = 10'd24;

	// MODIFIED (Arcade-NMK16_MiSTer, NMK-38; Arcade-GingaNin_MiSTer's GN-14): the read
	// side runs from configuration, not from the first write-side frame. The
	// core's raster is held in reset through the whole ROM download, so the
	// first frame edge came only after it: until then there was no sync, and
	// analog and direct video lost the picture (the menu's loading screen
	// included). The first real frame edge re-places the read side (once).
	reg        running = 1'b1;
	reg [12:0] hclk = 13'd0;      // clk_r within the line (13 bits: LINE_CLKS may be 6144)
	reg [4:0]  pix_div = 5'd0;    // clk_r within the pixel (5 bits: DIV may be 16)
	reg [9:0]  hcount_r = 10'd0;  // pixel within the line
	reg [9:0]  vcount_r = 10'd0;  // line, 0..277 (one behind the write side)

	wire       pix_tick = (pix_div == r_div - 5'd1);
	/* verilator lint_off WIDTHTRUNC */
	// LINE_CLKS is an integer parameter (<= 6144), so both fit 13 bits.
	localparam [12:0] LINE_END_C  = LINE_CLKS - 1;
	/* verilator lint_on WIDTHTRUNC */
	wire       line_end = (hclk == LINE_END_C);

	// Registered buffer read: the address is the current pixel's, stable
	// for a whole pixel period, so rgb_q holds pixel hcount_r at its tick.
	wire [9:0]  r_x    = hcount_r - r_x0;
	wire        r_hact = (hcount_r >= r_x0) && (r_x < r_aw);
	wire        r_vact = (vcount_r >= v_start_r) && (vcount_r < v_end_r);
	wire        r_act  = r_hact && r_vact;
	// next row's vertical activity, for vb_hs_r (see the port comment)
	wire [9:0]  vnext_r  = (vcount_r == VTOTAL - 10'd1) ? 10'd0 : vcount_r + 10'd1;
	wire        r_vact_n = (vnext_r >= v_start_r) && (vnext_r < v_end_r);
	// From the END of the row's active area on, report the next row's
	// blanking: every sync pulse that lies outside the picture -- the
	// nominal one and any H-Position shift of it -- then samples the
	// blanking of the active window it precedes, on both layouts.
	wire        vb_hs_now = (hcount_r >= r_x0 + r_aw) ? ~r_vact_n : ~r_vact;
	reg  [23:0] rgb_q;
	always @(posedge clk_r) rgb_q <= buf_mem[{vcount_r[0], r_x[8:0]}];

	// MODIFIED (NMK-38): black while the core's raster is stopped (its reset,
	// the download): read-side frames since the last write-side frame start,
	// saturating; two without one and the two-line buffer holds stale lines
	reg  [1:0] stale = 2'd3;
	always @(posedge clk_r) begin
		if (frame_edge) stale <= 2'd0;
		else if (running && pix_tick && hcount_r == r_ht - 10'd1 && vcount_r == VTOTAL - 10'd1 && stale != 2'd3)
			stale <= stale + 2'd1;
	end
	// (NMK-40) and from the clock the core's reset (reset_w) is seen: a reset
	// shorter than two frames showed the buffer's stale lines
	reg  [1:0] rst_sync = 2'b11;
	always @(posedge clk_r) rst_sync <= {rst_sync[0], reset_w};
	// ... and on until the core's first frame start after it (the rest of
	// that frame is its vertical blank, the buffer's lines older than the reset)
	reg        rst_seen = 1'b1;
	always @(posedge clk_r) if (rst_sync[1]) rst_seen <= 1'b1; else if (frame_edge) rst_seen <= 1'b0;
	wire       blank_r = stale[1] | rst_sync[1] | rst_seen;

	wire [9:0] vrel = (vcount_r >= v_end_r) ? (vcount_r - v_end_r) : (vcount_r + v_blank_r);
	wire       hs_now = (hcount_r >= hs_start) && (hcount_r < hs_start + hs_width);
	wire       vs_now = (vrel >= vs_rel) && (vrel < vs_rel + 10'd3);

	// MODIFIED (Arcade-NMK16_MiSTer, NMK-40; Arcade-GingaNin_MiSTer's GN-16): the read side's position in its frame (fpos, clk_r),
	// and where it expects the core's frame to start (ref). The placement
	// below puts the read side at (line VTOTAL-1, hclk 0) one clock after the
	// frame edge, so the nominal edge is the clock before that (FR_NOM); a
	// later edge within 32 clocks of ref is in phase.
	//   After the core's raster has been stopped (the reset: `stale`, two
	// frames without an edge) its first edge need not be: the top ends the
	// reset on rel_tog, a quarter of a line after FR_NOM, so the edge comes a
	// little after it, and anything from LINE/8 before FR_NOM to 3/4 of a line
	// after it is taken as the new ref with no move of the read side -- the
	// two-line buffer has room for a write side up to a line ahead of the
	// read and an eighth of a line (less than any core's blanking) behind
	// it. The sync carries on through the reset and the restart, so a CRT
	// never re-locks. Any other edge places the read side as before.
	localparam integer VT_INT   = {22'd0, VTOTAL};
	localparam integer FR_LEN   = VT_INT * LINE_CLKS;
	localparam integer FR_NOM_I = (VT_INT - 1) * LINE_CLKS - 1;
	localparam [20:0]  FR_LAST  = 21'(FR_LEN - 1);
	localparam [20:0]  FR_NOM   = 21'(FR_NOM_I);
	localparam [20:0]  FR_REL   = 21'(FR_NOM_I + LINE_CLKS / 4);
	// the restart window, LINE/8 before FR_NOM to 3/4 of a line after it
	// (inside the frame: FR_NOM is a line before its end)
	localparam [20:0]  WIN_A    = 21'(FR_NOM_I - LINE_CLKS / 8);
	localparam [20:0]  WIN_B    = 21'(FR_NOM_I + (LINE_CLKS * 3) / 4);
	reg  [20:0] fpos = 21'd0;           // (line, hclk) = (0, 0) at configuration, as the counters
	// rpos: clocks since the position the core's frame is expected at (ref),
	// so an edge is in phase when rpos is within 32 of 0 (either side)
	reg  [20:0] rpos = 21'(FR_LEN - FR_NOM_I);
	// the two tests, a clock ahead (registered; the window moves by a clock)
	reg         near_ref = 1'b0, in_win = 1'b0;
	// `stale` (above) counts read-side frames since the core's last edge
	wire stalled = stale[1];
	// FR_REL less rel_lead lines, in the frame; rel_lead is static (two
	// registers in, then the product, then the fold)
	reg  [9:0]  lead_r1 = 10'd0, lead_r2 = 10'd0;
	reg  [22:0] lead_clks = 23'd0;
	reg  [20:0] rel_pos = FR_REL;
	always @(posedge clk_r) begin
		lead_r1   <= rel_lead;
		lead_r2   <= lead_r1;
		lead_clks <= lead_r2 * 13'(LINE_CLKS);
		rel_pos   <= ({2'b00, FR_REL} >= lead_clks) ? 21'({2'b00, FR_REL} - lead_clks) : 21'({2'b00, FR_REL} + 23'(FR_LEN) - lead_clks);
	end
	wire in_phase   = running && near_ref;
	wire restart_ok = stalled && in_win;
	always @(posedge clk_r) begin
		fpos <= (fpos == FR_LAST) ? 21'd0 : fpos + 21'd1;
		rpos <= (rpos == FR_LAST) ? 21'd0 : rpos + 21'd1;
		near_ref <= (rpos < 21'd31) || (rpos >= 21'(FR_LEN - 33));
		in_win   <= (fpos >= WIN_A - 21'd1) && (fpos < WIN_B);
		if (fpos == rel_pos) rel_tog <= ~rel_tog;
		if (frame_edge && !in_phase) begin
			if (restart_ok) rpos <= 21'd1;                      // this edge's position is the new ref
			else begin fpos <= FR_NOM + 21'd1; rpos <= 21'd1; end
		end
	end
	always @(posedge clk_r) begin
		ce_r <= 1'b0;
		if (frame_edge && !in_phase && !restart_ok) begin
			running  <= 1'b1;
			hclk     <= 13'd0;
			pix_div  <= 5'd0;
			hcount_r <= 10'd0;
			vcount_r <= VTOTAL - 10'd1;
		end else if (running) begin
			hclk <= line_end ? 13'd0 : hclk + 13'd1;
			if (pix_tick) begin
				pix_div  <= 5'd0;
				ce_r     <= 1'b1;
				rgb_r    <= (r_act && !blank_r) ? rgb_q : 24'd0;
				de_r     <= r_act;
				hb_r     <= ~r_hact;
				vb_r     <= ~r_vact;
				vb_hs_r  <= vb_hs_now;
				hs_r     <= hs_now;
				vs_r     <= vs_now;
				if (hcount_r == r_ht - 10'd1) begin
					hcount_r <= 10'd0;
					vcount_r <= (vcount_r == VTOTAL - 10'd1) ? 10'd0 : vcount_r + 10'd1;
				end else begin
					hcount_r <= hcount_r + 10'd1;
				end
			end else begin
				pix_div <= pix_div + 5'd1;
			end
		end else begin
			de_r <= 1'b0; hs_r <= 1'b0; vs_r <= 1'b0; rgb_r <= 24'd0; hb_r <= 1'b1; vb_r <= 1'b1; vb_hs_r <= 1'b1;
		end
	end

endmodule
