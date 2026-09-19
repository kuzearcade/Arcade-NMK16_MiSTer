// Savestate prototype: park a running fx68k at an instruction boundary with a
// level-7 interrupt whose vector the bus substitutes, run a monitor routine
// from a bus overlay that pushes every register on the game's own stack and
// records SSP/USP, hold it on a resume flag, and let RTE resume. No fx68k
// change. The testbench owns the memory and the park handshake.
module top (
	input         clk,
	input         reset,
	// memory model (word-wide, 64 KB RAM at 0)
	output [23:1] mem_a,
	output        mem_rd,
	output        mem_wr,
	output [1:0]  mem_be,
	output [15:0] mem_wdata,
	input  [15:0] mem_rdata,
	// park handshake
	input         park_req,
	output reg    park_done,     // monitor wrote DONE
	input         resume,
	output reg [31:0] ssp_reg,
	output reg [31:0] usp_reg,
	input      [31:0] ssp_load,   // testbench can overwrite the state registers
	input      [31:0] usp_load,
	input             regs_load,
	output            fetch_game  // instruction fetch from below the overlay (monitor left)
);
	// clock enables: phi1 / phi2 alternate, 2 clocks apart
	reg [1:0] div = 0;
	always @(posedge clk) div <= div + 1'd1;
	wire enPhi1 = (div == 2'd0), enPhi2 = (div == 2'd2);

	wire eRWn, ASn, LDSn, UDSn, FC0, FC1, FC2;
	wire [15:0] iEdb, oEdb; wire [23:1] eab;
	wire iack = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack;
	wire DTACKn = ASn | iack;

	// level-7 request held until its acknowledge cycle
	reg ipl7 = 0;
	always @(posedge clk) begin
		if (park_req & ~park_done & ~ipl7 & ~armed) ipl7 <= 1'b1;
		if (iack & (eab[3:1] == 3'd7)) ipl7 <= 1'b0;
	end
	reg armed = 0;   // an IPL7 was taken for this park request
	always @(posedge clk) begin
		if (~park_req) armed <= 1'b0;
		else if (iack & (eab[3:1] == 3'd7)) armed <= 1'b1;
	end
	wire [2:0] ipl = ipl7 ? 3'd7 : 3'd0;

	fx68k cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(enPhi1), .enPhi2(enPhi2),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab));

	wire [23:0] a = {eab, 1'b0};
	wire rd = eRWn & ~ASn, wr = ~eRWn & ~ASn;
	wire sel_mon  = (a[23:9] == 15'h7F80);          // FF0000..FF01FF
	wire sel_code = sel_mon & ~a[8];                 // FF0000..FF00FF: monitor code
	wire sel_regs = sel_mon &  a[8];                 // FF0100..: state registers
	wire sel_vec7 = park_req & (a[23:2] == 22'h1F);  // 0x7C/0x7E while parking: vector 31

	// monitor ROM (27 words)
	reg [15:0] mon [0:31];
	initial begin
		mon[0]=16'h48E7; mon[1]=16'hFFFE; mon[2]=16'h4E68; mon[3]=16'h23C8; mon[4]=16'h00FF; mon[5]=16'h0104;
		mon[6]=16'h23CF; mon[7]=16'h00FF; mon[8]=16'h0100; mon[9]=16'h33FC; mon[10]=16'h0001; mon[11]=16'h00FF;
		mon[12]=16'h0108; mon[13]=16'h4A79; mon[14]=16'h00FF; mon[15]=16'h010A; mon[16]=16'h67F8; mon[17]=16'h2E79;
		mon[18]=16'h00FF; mon[19]=16'h0100; mon[20]=16'h2079; mon[21]=16'h00FF; mon[22]=16'h0104; mon[23]=16'h4E60;
		mon[24]=16'h4CDF; mon[25]=16'h7FFF; mon[26]=16'h4E73; mon[27]=16'h4E71; mon[28]=16'h4E71; mon[29]=16'h4E71; mon[30]=16'h4E71; mon[31]=16'h4E71;
	end
	// state registers: 0100 SSP.L, 0104 USP.L, 0108 DONE.W, 010A RESUME.W
	reg [15:0] regs_rd;
	always @(*) begin
		case (a[3:1])
			3'd0: regs_rd = ssp_reg[31:16];
			3'd1: regs_rd = ssp_reg[15:0];
			3'd2: regs_rd = usp_reg[31:16];
			3'd3: regs_rd = usp_reg[15:0];
			3'd4: regs_rd = {15'd0, park_done};
			3'd5: regs_rd = {15'd0, resume};
			default: regs_rd = 16'h0000;
		endcase
	end
	always @(posedge clk) begin
		if (regs_load) begin ssp_reg <= ssp_load; usp_reg <= usp_load; end
		if (wr & sel_regs & (div == 2'd1)) begin   // one write per bus cycle (sample once)
			case (a[3:1])
				3'd0: ssp_reg[31:16] <= oEdb;
				3'd1: ssp_reg[15:0]  <= oEdb;
				3'd2: usp_reg[31:16] <= oEdb;
				3'd3: usp_reg[15:0]  <= oEdb;
				3'd4: park_done <= oEdb[0];
				default: ;
			endcase
		end
		if (~park_req) park_done <= 1'b0;
	end
	assign iEdb = sel_code ? mon[a[5:1]] : sel_regs ? regs_rd : sel_vec7 ? (a[1] ? 16'h0000 : 16'h00FF) : mem_rdata;
	// vector 31 -> 0x00FF0000 (high word at 0x7C = 00FF, low word at 0x7E = 0000)
	assign mem_a = eab; assign mem_rd = rd & ~sel_mon & ~sel_vec7; assign mem_wr = wr & ~sel_mon;
	assign mem_be = {~UDSn, ~LDSn}; assign mem_wdata = oEdb;
	assign fetch_game = rd & (FC1 & ~FC0 | FC1 & FC0 & ~FC2) & ~sel_mon;   // program-space fetch outside the overlay
endmodule
