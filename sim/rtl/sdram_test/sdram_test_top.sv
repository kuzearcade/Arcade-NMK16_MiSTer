// Standalone verification harness: rtl/sdram.sv + rtl/sdram_req.sv (x4)
// against sim/models/sdram_model.sv's behavioral SDR SDRAM chip — proves
// the shared 4-port req/ack primitive works (correct data, correct
// round-robin arbitration under contention) before it's ever wired into
// a real core. See docs/hw-bringup.md.
module sdram_test_top
(
	input clk,
	input reset,
	output sdram_ready_o,

	// four independent consumer ports, C++-driven
	input  [24:1] c_addr  [0:3],
	input         c_we    [0:3],
	input         c_wrl   [0:3],
	input         c_wrh   [0:3],
	input  [15:0] c_din   [0:3],
	input         c_req   [0:3],
	output        c_busy  [0:3],
	output        c_valid [0:3],
	output [15:0] c_dout  [0:3]
);

	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE;
	wire        sdram_ready;
	assign sdram_ready_o = sdram_ready;

	wire [24:1] p_addr [0:3];
	wire        p_wrl  [0:3];
	wire        p_wrh  [0:3];
	wire [15:0] p_din  [0:3];
	wire [15:0] p_dout [0:3];
	wire        p_req  [0:3];
	wire        p_ack  [0:3];

	sdram sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk), .prio_mode(2'd0),
		.addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]), .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]),
		.addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]), .din1(p_din[1]), .dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
		.addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]), .din2(p_din[2]), .dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2]),
		.addr3(p_addr[3]), .wrl3(p_wrl[3]), .wrh3(p_wrh[3]), .din3(p_din[3]), .dout3(p_dout[3]), .req3(p_req[3]), .ack3(p_ack[3])
	);

	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	genvar g;
	generate
		for (g = 0; g < 4; g = g + 1) begin : reqs
			sdram_req req_inst (
				.clk(clk), .reset(reset),
				.addr(c_addr[g]), .we(c_we[g]), .wrl(c_wrl[g]), .wrh(c_wrh[g]), .din(c_din[g]),
				.req(c_req[g]), .busy(c_busy[g]), .valid(c_valid[g]), .dout(c_dout[g]),
				.sdram_addr(p_addr[g]), .sdram_wrl(p_wrl[g]), .sdram_wrh(p_wrh[g]),
				.sdram_din(p_din[g]), .sdram_dout(p_dout[g]), .sdram_req(p_req[g]), .sdram_ack(p_ack[g])
			);
		end
	endgenerate

endmodule
