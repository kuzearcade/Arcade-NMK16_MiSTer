// Savestate support (2026-09-18): park a running fx68k at an instruction
// boundary WITHOUT touching the vendored CPU, and get every register out.
//
// Mechanism (proven in sim/rtl/ss_m68k before it was wired into a core):
//   1. park_req raises a level-7 interrupt. The 68000 finishes its current
//      instruction, pushes SR/PC on the supervisor stack and runs an
//      interrupt-acknowledge cycle; the core answers it with VPA (autovector),
//      so the CPU fetches vector 31 from address 0x7C. While park_req is
//      high that long word is substituted here with MON_BASE, the address of
//      a 52-byte monitor routine served from a bus overlay (sel_mon /
//      mon_data override the read-data mux; MON_BASE must be unmapped on
//      every board the core serves).
//   2. The monitor pushes D0-D7/A0-A6 on the game's own stack (so they land
//      in the main-RAM image), stores SSP and USP in the state registers
//      at MON_BASE+0x100/+0x104, writes 1 to DONE (+0x108) and spins on
//      RESUME (+0x10A). Every other register (SR, PC) is in the exception
//      frame, also in RAM.
//   3. To resume, the engine (after restoring SSP/USP on a load) sets
//      RESUME: the monitor reloads A7/USP from the state registers, pops
//      the registers and RTEs. The level-7 request was dropped at its
//      acknowledge, so the CPU returns to the game with its own SR.
//
// The state registers are exposed on a tiny word bus (ss_sel/ss_wr/...):
//   0 SSP[31:16] 1 SSP[15:0] 2 USP[31:16] 3 USP[15:0]
//
// Bus cycles are sampled once on `phi` (the ungated enPhi2 of the core's
// clock-enable pair), so a write is applied exactly once per bus cycle.
module ss_m68k_park #(
	parameter [23:9] MON_BASE = 15'h0F40   // 0x1E8000: the 512-byte overlay window
) (
	input             clk,
	input             reset,
	input             phi,          // one pulse per CPU clock (enPhi2, ungated)

	input             park_req,     // level: hold the CPU in the monitor
	output reg        parked,       // the monitor has written DONE
	input             resume,       // level: let the monitor RTE (engine drops park_req after the CPU leaves)

	// 68000 bus (fx68k names)
	input      [23:1] eab,
	input             ASn,
	input             eRWn,
	input             FC0, FC1, FC2,
	input      [15:0] oEdb,

	output reg  [2:0] ipl_park,     // OR into the core's IPL: 7 while requesting, else 0
	output            sel_mon,      // this read is the overlay's (code, state registers, or the vector)
	output reg [15:0] mon_data,

	// state registers
	input       [1:0] ss_sel,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_rdata
);
	wire [23:0] a = {eab, 1'b0};
	wire iack = FC0 & FC1 & FC2 & ~ASn;
	wire rd = eRWn & ~ASn;
	wire wr = ~eRWn & ~ASn;

	// level-7 request: raised once per park request, dropped at its acknowledge
	reg ipl7 = 1'b0, armed = 1'b0;
	always @(posedge clk) begin
		if (reset | ~park_req) begin
			ipl7 <= 1'b0; armed <= 1'b0;
		end else begin
			if (~parked & ~ipl7 & ~armed) ipl7 <= 1'b1;
			if (iack & (eab[3:1] == 3'd7)) begin ipl7 <= 1'b0; armed <= 1'b1; end
		end
	end
	always @(*) ipl_park = ipl7 ? 3'd7 : 3'd0;

	// The overlay enable changes ONLY between bus cycles (ASn high). fx68k
	// keeps capturing the data bus on every phi2 until the cycle ends, so
	// an overlay that vanished one clock into the RTE's own fetch handed
	// the CPU 0xFFFF instead of 0x4E73: a line-F exception at 0x..8034,
	// found on the board as the game's exception handler halting after
	// every operation (2026-09-18). `left` is set when the RTE fetch's
	// bus cycle has ENDED, and the enable follows it at the next ASn-high.
	reg  left = 1'b0;      // the RTE has been fetched: CPU on its way back to the game
	reg  rte_seen = 1'b0;  // the RTE fetch cycle is in progress
	reg  ovl_on = 1'b0;    // registered overlay enable
	always @(posedge clk) begin
		if (ASn) ovl_on <= park_req & ~left;
	end
	wire sel_win  = ovl_on & (a[23:9] == MON_BASE);
	wire sel_code = sel_win & ~a[8];
	wire sel_regs = sel_win &  a[8];
	wire sel_vec7 = ovl_on & (a[23:2] == 22'h1F);   // 0x7C/0x7E: vector 31
	assign sel_mon = rd & (sel_win | sel_vec7);

	// monitor code, 26 words (unidasm-verified in sim/rtl/ss_m68k)
	wire [15:0] mb_hi = {8'h00, MON_BASE[23:16]};
	wire [15:0] mb_lo = {MON_BASE[15:9], 9'd0};
	reg  [15:0] mon;
	always @(*) begin
		case (a[5:1])
			5'd0:  mon = 16'h48E7; 5'd1:  mon = 16'hFFFE;              // movem.l d0-d7/a0-a6,-(sp)
			5'd2:  mon = 16'h4E68;                                     // move usp,a0
			5'd3:  mon = 16'h23C8; 5'd4:  mon = mb_hi; 5'd5:  mon = mb_lo | 16'h0104;   // move.l a0,USP_REG
			5'd6:  mon = 16'h23CF; 5'd7:  mon = mb_hi; 5'd8:  mon = mb_lo | 16'h0100;   // move.l a7,SSP_REG
			5'd9:  mon = 16'h33FC; 5'd10: mon = 16'h0001; 5'd11: mon = mb_hi; 5'd12: mon = mb_lo | 16'h0108; // move.w #1,DONE
			5'd13: mon = 16'h4A79; 5'd14: mon = mb_hi; 5'd15: mon = mb_lo | 16'h010A;  // loop: tst.w RESUME
			5'd16: mon = 16'h67F8;                                     // beq loop
			5'd17: mon = 16'h2E79; 5'd18: mon = mb_hi; 5'd19: mon = mb_lo | 16'h0100;  // move.l SSP_REG,a7
			5'd20: mon = 16'h2079; 5'd21: mon = mb_hi; 5'd22: mon = mb_lo | 16'h0104;  // move.l USP_REG,a0
			5'd23: mon = 16'h4E60;                                     // move a0,usp
			5'd24: mon = 16'h4CDF; 5'd25: mon = 16'h7FFF;              // movem.l (sp)+,d0-d7/a0-a6
			5'd26: mon = 16'h4E73;                                     // rte
			default: mon = 16'h4E71;                                   // nop
		endcase
	end

	reg [31:0] ssp_reg = 32'd0, usp_reg = 32'd0;
	reg [15:0] regs_rd;
	always @(*) begin
		case (a[3:1])
			3'd0: regs_rd = ssp_reg[31:16];
			3'd1: regs_rd = ssp_reg[15:0];
			3'd2: regs_rd = usp_reg[31:16];
			3'd3: regs_rd = usp_reg[15:0];
			3'd4: regs_rd = {15'd0, parked};
			3'd5: regs_rd = {15'd0, resume};
			default: regs_rd = 16'h0000;
		endcase
	end
	always @(*) begin
		if (sel_code)      mon_data = mon;
		else if (sel_regs) mon_data = regs_rd;
		else               mon_data = a[1] ? {MON_BASE[15:9], 9'd0} : {8'h00, MON_BASE[23:16]};   // vector 31 -> MON_BASE
	end

	always @(posedge clk) begin
		if (ss_wr) begin
			case (ss_sel)
				2'd0: ssp_reg[31:16] <= ss_wdata;
				2'd1: ssp_reg[15:0]  <= ss_wdata;
				2'd2: usp_reg[31:16] <= ss_wdata;
				2'd3: usp_reg[15:0]  <= ss_wdata;
			endcase
		end else if (wr & sel_regs & phi) begin
			case (a[3:1])
				3'd0: ssp_reg[31:16] <= oEdb;
				3'd1: ssp_reg[15:0]  <= oEdb;
				3'd2: usp_reg[31:16] <= oEdb;
				3'd3: usp_reg[15:0]  <= oEdb;
				3'd4: parked <= oEdb[0];
				default: ;
			endcase
		end
		if (resume & rd & sel_code & (a[5:1] == 5'd26)) rte_seen <= 1'b1;
		if (rte_seen & ASn) begin rte_seen <= 1'b0; parked <= 1'b0; left <= 1'b1; end   // the RTE fetch cycle is over
		if (reset | ~park_req) begin parked <= 1'b0; left <= 1'b0; rte_seen <= 1'b0; end
	end
	always @(*) begin
		case (ss_sel)
			2'd0: ss_rdata = ssp_reg[31:16];
			2'd1: ss_rdata = ssp_reg[15:0];
			2'd2: ss_rdata = usp_reg[31:16];
			2'd3: ss_rdata = usp_reg[15:0];
		endcase
	end
endmodule
