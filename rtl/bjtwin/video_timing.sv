// Shared raster timing for the bjtwin family: 512x278 total, 384x224
// visible, hblank 28-412, vblank 16-240 (see docs/tier1-bjtwin.md).
// Both nmk_irq_hacky (interrupt/sprite-DMA scanline triggers) and the
// video pipeline consume this single counter pair rather than each
// keeping their own, so there's one source of truth for raster position.
//
// Reset-time raster phase: `vcount` resets to `VACTIVE_END` (240, the
// first scanline of vblank), not 0 — confirmed directly against real
// MAME's own screen device (Family D bring-up investigation, tdragon1):
// `screen.vpos()` at machine time 0 sits at the very start of vblank,
// not the top of the frame. Measured two independent ways that agree:
// (1) a MAME Lua memory-read tap on the protection MCU's own P5
// register (`screen.vpos()>>2`, the *exact* value real game code
// observes) showed vpos in [44,47] at real time 5.260ms after machine
// start, while `time_until_vblank_start()` returns *exactly*
// `frame_period()` at time 0 (consistent with vpos already sitting
// precisely at the vblank-start boundary, one full frame from the
// next one); (2) tracking P5 over time gave a clean ~64us/scanline
// rate (matching `scan_period()` exactly, VTOTAL=278), confirming
// the *rate* was never wrong — only the reset-time starting value —
// solving `vpos(t=0) + 5260/64 ≡ [44,47] (mod 278)` for vpos(t=0)
// gives [240,243], landing on VACTIVE_END. This was NOT assumed or
// guessed: every prior port's own polling loops tolerated the old
// vcount=0 reset silently (it only ever showed up as an already-
// documented, bounded residual cycle-cost mismatch in verification),
// and this project spent real, substantial effort chasing several
// wrong theories (a CPU-core EXX bug, a periph timer-rate mismatch, a
// MAME debugger-trace timing artifact, MAME itself never rendering
// under headless test flags) before a user-supplied correction (their
// own interactive MAME run *did* reach a title screen) redirected the
// investigation back to this, the original, correct hypothesis.
module video_timing (
	input        clk_sys,
	input        ce_pix,     // 8MHz pixel-clock enable
	input        reset,

	output reg [9:0] hcount,  // 0..511
	output reg [9:0] vcount,  // 0..277
	output           line_start, // pulse at hcount==0
	output           hblank,
	output           vblank
);

	localparam HTOTAL = 512;
	localparam VTOTAL = 278;
	localparam HACTIVE_START = 28;
	localparam HACTIVE_END   = 412; // exclusive
	localparam VACTIVE_START = 16;
	localparam VACTIVE_END   = 240; // exclusive

	always @(posedge clk_sys) begin
		if (reset) begin
			hcount <= 10'd0;
			vcount <= VACTIVE_END[9:0]; // see header — matches MAME's own reset-time raster phase
		end else if (ce_pix) begin
			if (hcount == HTOTAL - 1) begin
				hcount <= 10'd0;
				vcount <= (vcount == VTOTAL - 1) ? 10'd0 : vcount + 10'd1;
			end else begin
				hcount <= hcount + 10'd1;
			end
		end
	end

	assign line_start = ce_pix & (hcount == 10'd0);
	assign hblank = (hcount < HACTIVE_START) || (hcount >= HACTIVE_END);
	assign vblank = (vcount < VACTIVE_START) || (vcount >= VACTIVE_END);

endmodule
