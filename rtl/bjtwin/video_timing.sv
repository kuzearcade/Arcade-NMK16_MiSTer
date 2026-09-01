// Shared raster timing for the bjtwin family: 512x278 total, 384x224
// visible, hblank 28-412, vblank 16-240 (see docs/tier1-bjtwin.md).
// Both nmk_irq_hacky (interrupt/sprite-DMA scanline triggers) and the
// video pipeline consume this single counter pair rather than each
// keeping their own, so there's one source of truth for raster position.
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
			vcount <= 10'd0;
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
