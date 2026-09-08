// Standalone verification of rtl/rom_cache1.sv against a real
// rtl/sdram.sv + sim/models/sdram_model.sv, direct (non-arbitrated)
// single sdram_req.sv channel. See docs/hw-bringup.md.
module rom_cache1_test_top
(
	input clk,
	input reset,
	output sdram_ready_o,

	input  [23:1] c_addr,
	output [15:0] c_data,
	output        c_ready,

	// pre-load path: write directly to the underlying SDRAM before the
	// cache ever reads, via a second physical sdram.sv port so it never
	// contends with the cache's own port.
	input  [24:1] w_addr,
	input  [15:0] w_din,
	input         w_req,
	output        w_busy,
	output        w_valid
);

	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE;
	wire        sdram_ready;
	assign sdram_ready_o = sdram_ready;

	// Port 0 (cache under test)
	wire [24:1] p0_addr;
	wire        p0_wrl, p0_wrh;
	wire [15:0] p0_din;
	wire [15:0] p0_dout_from_sdram;
	wire [31:0] p0_dout_pair_from_sdram;
	wire        p0_req, p0_ack;

	// Port 1 (raw pre-load writer)
	wire [24:1] p1_addr;
	wire        p1_wrl, p1_wrh;
	wire [15:0] p1_din;
	wire [15:0] p1_dout_from_sdram;
	wire        p1_req, p1_ack;

	sdram sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk), .prio_mode(2'd0),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout_from_sdram), .dout0_pair(p0_dout_pair_from_sdram), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout_from_sdram), .req1(p1_req), .ack1(p1_ack),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2(),
		.addr3('0), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(), .req3(1'b0), .ack3()
	);

	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	wire [24:1] cache_sd_addr;
	wire        cache_req, cache_busy, cache_valid;
	wire [15:0] cache_dout;
	wire [31:0] cache_dout_pair;

	sdram_req cache_req_inst (
		.clk(clk), .reset(reset),
		.addr(cache_sd_addr), .we(1'b0), .wrl(1'b0), .wrh(1'b0), .din(16'h0),
		.req(cache_req), .busy(cache_busy), .valid(cache_valid), .dout(cache_dout), .dout_pair(cache_dout_pair),
		.sdram_addr(p0_addr), .sdram_wrl(p0_wrl), .sdram_wrh(p0_wrh),
		.sdram_din(p0_din), .sdram_dout(p0_dout_from_sdram), .sdram_dout_pair(p0_dout_pair_from_sdram), .sdram_req(p0_req), .sdram_ack(p0_ack)
	);

	rom_cache1 cache_inst (
		.clk(clk), .reset(reset),
		.addr(c_addr), .data(c_data), .ready(c_ready),
		.sd_addr(cache_sd_addr), .sd_req(cache_req), .sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout), .sd_dout_pair(cache_dout_pair)
	);

	sdram_req w_req_inst (
		.clk(clk), .reset(reset),
		.addr(w_addr), .we(1'b1), .wrl(1'b1), .wrh(1'b1), .din(w_din),
		.req(w_req), .busy(w_busy), .valid(w_valid), .dout(),
		.sdram_addr(p1_addr), .sdram_wrl(p1_wrl), .sdram_wrh(p1_wrh),
		.sdram_din(p1_din), .sdram_dout(p1_dout_from_sdram), .sdram_req(p1_req), .sdram_ack(p1_ack)
	);

endmodule
