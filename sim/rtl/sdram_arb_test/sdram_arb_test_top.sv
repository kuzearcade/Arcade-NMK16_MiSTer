// Standalone verification of rtl/sdram_arb.sv (N=3 logical channels
// sharing one physical rtl/sdram.sv port) against sim/models/sdram_model.sv.
// See docs/hw-bringup.md.
module sdram_arb_test_top #(
	parameter N = 3
) (
	input clk,
	input reset,
	output sdram_ready_o,

	input  [24:1] c_addr  [0:N-1],
	input         c_we    [0:N-1],
	input         c_wrl   [0:N-1],
	input         c_wrh   [0:N-1],
	input  [15:0] c_din   [0:N-1],
	input         c_req   [0:N-1],
	output        c_busy  [0:N-1],
	output        c_valid [0:N-1],
	output [15:0] c_dout  [0:N-1]
);

	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE;
	wire        sdram_ready;
	assign sdram_ready_o = sdram_ready;

	wire [24:1] p_addr;
	wire        p_wrl, p_wrh;
	wire [15:0] p_din, p_dout;
	wire        p_req, p_ack;

	sdram sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk), .prio_mode(2'd0),
		.addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
		.addr1('0), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(), .req1(1'b0), .ack1(),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2(),
		.addr3('0), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(), .req3(1'b0), .ack3()
	);

	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	sdram_arb #(.N(N)) arb_inst (
		.clk(clk), .reset(reset),
		.i_addr(c_addr), .i_we(c_we), .i_wrl(c_wrl), .i_wrh(c_wrh), .i_din(c_din),
		.i_req(c_req), .i_busy(c_busy), .i_valid(c_valid), .i_dout(c_dout),
		.sdram_addr(p_addr), .sdram_wrl(p_wrl), .sdram_wrh(p_wrh),
		.sdram_din(p_din), .sdram_dout(p_dout), .sdram_req(p_req), .sdram_ack(p_ack)
	);

endmodule
