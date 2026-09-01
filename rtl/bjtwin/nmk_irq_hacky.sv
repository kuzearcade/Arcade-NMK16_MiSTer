// nmk_irq "hacky" fixed-scanline interrupt generator — the variant `cactus`
// uses (undumped timing PROMs on this bootleg; MAME substitutes a fixed
// scanline table, nmk16.cpp set_hacky_interrupt_timing()/nmk16_hacky_scanline,
// nmk16.cpp:4482-4511). bjtwinp/nouryokup need the *real* dual-PROM
// nmk_irq state machine instead (V-PROM driven, per the video-hardware
// research in docs/) — that's a separate module for a later milestone,
// not implemented here since cactus (this milestone's oracle-verified
// target) uses this fixed-table variant.
//
// Fixed scanline table (cactus only):
//   scanline  16  -> IRQ2  (VBIN, start of active video)
//   scanline  68  -> IRQ1
//   scanline 196  -> IRQ1 (second pulse)
//   scanline 240  -> IRQ4  (VBOUT)
//   scanline 242  -> sprite DMA trigger (not consumed yet — no sprite
//                    engine exists in this milestone)
//
// IRQ levels are held (matching MAME's HOLD_LINE semantics for M68K,
// which auto-clears when the CPU takes the interrupt) until the CPU
// performs an interrupt-acknowledge bus cycle at that level.
module nmk_irq_hacky (
	input        clk_sys,
	input        ce_pix,       // 8MHz pixel-clock enable, one pulse per pixel
	input        reset,

	input        iack_cycle,   // FC=111 & ~ASn, from bjtwin_core
	input  [3:1] iack_level,   // eab[3:1] during an iack cycle == level being acked

	output [2:0] ipl_level,    // 0,1,2,4 — see bjtwin_core's IPLn encoding
	output       sprite_dma_trigger
);

	localparam HTOTAL = 512;
	localparam VTOTAL = 278;

	localparam SL_IRQ2      = 16;
	localparam SL_IRQ1_A    = 68;
	localparam SL_IRQ1_B    = 196;
	localparam SL_IRQ4      = 240;
	localparam SL_SPRDMA    = 242;

	reg [9:0] hcount;
	reg [9:0] vcount;

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

	wire line_start = ce_pix & (hcount == 10'd0);

	reg pending1, pending2, pending4;
	reg sprdma_pulse;

	always @(posedge clk_sys) begin
		sprdma_pulse <= 1'b0;

		if (reset) begin
			pending1 <= 1'b0;
			pending2 <= 1'b0;
			pending4 <= 1'b0;
		end else begin
			if (line_start) begin
				case (vcount)
					SL_IRQ2:   pending2 <= 1'b1;
					SL_IRQ1_A: pending1 <= 1'b1;
					SL_IRQ1_B: pending1 <= 1'b1;
					SL_IRQ4:   pending4 <= 1'b1;
					SL_SPRDMA: sprdma_pulse <= 1'b1;
					default: ;
				endcase
			end

			if (iack_cycle) begin
				case (iack_level)
					3'd1: pending1 <= 1'b0;
					3'd2: pending2 <= 1'b0;
					3'd4: pending4 <= 1'b0;
					default: ;
				endcase
			end
		end
	end

	assign ipl_level = pending4 ? 3'd4 : pending2 ? 3'd2 : pending1 ? 3'd1 : 3'd0;
	assign sprite_dma_trigger = sprdma_pulse;

endmodule
