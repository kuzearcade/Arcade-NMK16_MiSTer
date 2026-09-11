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
module video_retime (
	// write side — the core's raster
	input         clk_w,
	input         reset_w,
	input         ce_w,             // 8 MHz pixel enable
	input  [9:0]  hcount_w,         // 0..511, steps at ce_w
	input  [9:0]  vcount_w,         // 0..277, steps at the hcount wrap
	input  [23:0] rgb_w,            // pixel hcount_w-x0 of line vcount_w, sampled at ce_w
	input         mode7,            // 1: 448 px / 7 MHz window (powerins); 0: 512 px / 8 MHz
	input  [3:0]  hshift_sel,       // OSD H Shift, two's complement x2 px
	input  [5:0]  vshift_sel,       // OSD V Shift, 0..20 = 0..+20, 21..40 = -20..-1

	// read side — the framework's video clock
	input         clk_r,
	output reg    ce_r,
	output reg [23:0] rgb_r,
	output reg    hs_r,
	output reg    vs_r,
	output reg    de_r
);

	// Geometry per mode (bitmap coordinates in the board's own pixel
	// units; the write side always uses the 512-px raster's window).
	localparam [9:0] W_X0_8 = 10'd28,  W_X0_7 = 10'd60;   // write-side active start (core raster)
	localparam [9:0] R_X0_8 = 10'd28,  R_X0_7 = 10'd60;   // read-side active start
	localparam [9:0] R_HT_8 = 10'd512, R_HT_7 = 10'd448;  // read-side HTOTAL
	localparam [9:0] R_HS_8 = 10'd440, R_HS_7 = 10'd404;  // nominal hsync start (same 3.5 us after active end)
	localparam [9:0] R_HW_8 = 10'd32,  R_HW_7 = 10'd28;   // hsync width (4 us)
	localparam [9:0] AW_8   = 10'd384, AW_7   = 10'd320;  // active width
	localparam [3:0] DIV_8  = 4'd7,    DIV_7  = 4'd8;     // clk_r per pixel
	localparam [9:0] VTOTAL = 10'd278;
	localparam integer LINE_CLKS = 3584;                  // 512*7 = 448*8

	// ------------------------------------------------------------------
	// Write side
	// ------------------------------------------------------------------
	reg [23:0] buf_mem [0:1023];  // 2 lines x 512 slots (index = {line parity, x[8:0]}; x < 384)
	wire [9:0] w_x0   = mode7 ? W_X0_7 : W_X0_8;
	wire [9:0] w_aw   = mode7 ? AW_7   : AW_8;
	wire [9:0] w_x    = hcount_w - w_x0;
	wire       w_act  = (hcount_w >= w_x0) && (w_x < w_aw) && (vcount_w >= 10'd16) && (vcount_w < 10'd240);
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
	always @(posedge clk_r) mode_sync <= {mode_sync[0], mode7};
	wire       m7 = mode_sync[1];
	wire [9:0] r_x0 = m7 ? R_X0_7 : R_X0_8;
	wire [9:0] r_ht = m7 ? R_HT_7 : R_HT_8;
	wire [9:0] r_aw = m7 ? AW_7   : AW_8;
	wire [3:0] r_div = m7 ? DIV_7 : DIV_8;

	// H/V Shift (the same arithmetic Macross2.sv used on the core raster):
	// positive = picture right/down = sync earlier.
	wire [9:0] hshift_px = {{5{hshift_sel[3]}}, hshift_sel, 1'b0};
	wire [9:0] vshift_ln = (vshift_sel <= 6'd20) ? {4'd0, vshift_sel} : ({4'd0, vshift_sel} - 10'd41);
	wire [9:0] hs_start  = (m7 ? R_HS_7 : R_HS_8) - hshift_px;
	wire [9:0] hs_width  = m7 ? R_HW_7 : R_HW_8;
	wire [9:0] vs_rel    = 10'd24 - vshift_ln;

	reg        running = 1'b0;
	reg [11:0] hclk;              // clk_r within the line, 0..3583
	reg [3:0]  pix_div;           // clk_r within the pixel
	reg [9:0]  hcount_r;          // pixel within the line
	reg [9:0]  vcount_r;          // line, 0..277 (one behind the write side)

	wire       pix_tick = (pix_div == r_div - 4'd1);
	wire       line_end = (hclk == LINE_CLKS - 1);

	// Registered buffer read: the address is the current pixel's, stable
	// for a whole pixel period, so rgb_q holds pixel hcount_r at its tick.
	wire [9:0]  r_x    = hcount_r - r_x0;
	wire        r_act  = (hcount_r >= r_x0) && (r_x < r_aw) && (vcount_r >= 10'd16) && (vcount_r < 10'd240);
	reg  [23:0] rgb_q;
	always @(posedge clk_r) rgb_q <= buf_mem[{vcount_r[0], r_x[8:0]}];

	wire [9:0] vrel = (vcount_r >= 10'd240) ? (vcount_r - 10'd240) : (vcount_r + 10'd38);
	wire       hs_now = (hcount_r >= hs_start) && (hcount_r < hs_start + hs_width);
	wire       vs_now = (vrel >= vs_rel) && (vrel < vs_rel + 10'd3);

	// Expected read position at a write frame start: the placement below
	// puts the read side at (line 277, hclk 0) one clock AFTER the frame
	// edge, so exactly one frame later the edge finds it on the last clock
	// of line 276 (hclk 3583); accept a window either side of that wrap.
	wire in_phase = running && (((vcount_r == VTOTAL - 10'd1) && (hclk < 12'd32)) ||
	                            ((vcount_r == VTOTAL - 10'd2) && (hclk >= LINE_CLKS - 32)));

	always @(posedge clk_r) begin
		ce_r <= 1'b0;
		if (frame_edge && !in_phase) begin
			running  <= 1'b1;
			hclk     <= 12'd0;
			pix_div  <= 4'd0;
			hcount_r <= 10'd0;
			vcount_r <= VTOTAL - 10'd1;
		end else if (running) begin
			hclk <= line_end ? 12'd0 : hclk + 12'd1;
			if (pix_tick) begin
				pix_div  <= 4'd0;
				ce_r     <= 1'b1;
				rgb_r    <= r_act ? rgb_q : 24'd0;
				de_r     <= r_act;
				hs_r     <= hs_now;
				vs_r     <= vs_now;
				if (hcount_r == r_ht - 10'd1) begin
					hcount_r <= 10'd0;
					vcount_r <= (vcount_r == VTOTAL - 10'd1) ? 10'd0 : vcount_r + 10'd1;
				end else begin
					hcount_r <= hcount_r + 10'd1;
				end
			end else begin
				pix_div <= pix_div + 4'd1;
			end
		end else begin
			de_r <= 1'b0; hs_r <= 1'b0; vs_r <= 1'b0; rgb_r <= 24'd0;
		end
	end

endmodule
