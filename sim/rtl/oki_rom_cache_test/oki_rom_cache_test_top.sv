// Standalone verification of rtl/oki_rom_cache.sv against a real
// rtl/sdram.sv + sim/models/sdram_model.sv, through the real
// rtl/sdram_arb.sv exactly as tdragon2_core.sv wires SDRAM port 1:
// channel 0 a rom_cache1_byte (the Z80 program fetch), channels 1 and 2
// two oki_rom_cache instances (the two OKIs, which run in lockstep on
// the real board and so miss at the same instant).
module oki_rom_cache_test_top
(
	input clk,
	input reset,
	output sdram_ready_o,

	input  [21:0] c_addr,       // drives both OKI caches
	output [7:0]  c_data,
	output        c_ready,
	output        c_stall,
	output        c_req,
	output [7:0]  c2_data,
	output        c2_ready,
	output        c2_stall,

	input  [16:0] z_addr,       // Z80-like reader on channel 0
	output [7:0]  z_data,
	output        z_ready,

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

	wire [24:1] p0_addr;
	wire        p0_wrl, p0_wrh;
	wire [15:0] p0_din;
	wire [15:0] p0_dout_from_sdram;
	wire [31:0] p0_dout_pair_from_sdram;
	wire        p0_req, p0_ack;

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

	// Port 0 of the SDRAM through the 3-channel arbiter, as in the core.
	wire        a_busy [0:2];
	wire        a_valid[0:2];
	wire [24:1] a_addr [0:2];
	wire        a_req  [0:2];
	wire [15:0] a_dout [0:2];
	wire [31:0] a_dout_pair [0:2];

	sdram_arb #(.N(3)) arb_inst (
		.clk(clk), .reset(reset),
		.i_addr(a_addr), .i_we('{1'b0, 1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0, 1'b0}), .i_din('{16'd0, 16'd0, 16'd0}),
		.i_req(a_req), .i_busy(a_busy), .i_valid(a_valid), .i_dout(a_dout), .i_dout_pair(a_dout_pair),
		.sdram_addr(p0_addr), .sdram_wrl(p0_wrl), .sdram_wrh(p0_wrh), .sdram_din(p0_din),
		.sdram_dout(p0_dout_from_sdram), .sdram_dout_pair(p0_dout_pair_from_sdram), .sdram_req(p0_req), .sdram_ack(p0_ack)
	);

	// Channel 0: Z80-like byte reader over the same 32KB image.
	rom_cache1_byte #(.BASE_WORD_OFFSET(23'd0)) z_cache_inst (
		.clk(clk), .reset(reset),
		.byte_addr({7'd0, z_addr}), .data(z_data), .ready(z_ready),
		.sd_addr(a_addr[0]), .sd_req(a_req[0]), .sd_busy(a_busy[0]), .sd_valid(a_valid[0]), .sd_dout(a_dout[0]), .sd_dout_pair(a_dout_pair[0])
	);

	assign c_req = a_req[1];
	oki_rom_cache #(.BASE_WORD_OFFSET(23'd0)) cache_inst (
		.clk(clk), .reset(reset),
		.byte_addr(c_addr), .data(c_data), .ready(c_ready), .stall(c_stall),
		.sd_addr(a_addr[1]), .sd_req(a_req[1]), .sd_busy(a_busy[1]), .sd_valid(a_valid[1]), .sd_dout(a_dout[1]), .sd_dout_pair(a_dout_pair[1])
	);
	oki_rom_cache #(.BASE_WORD_OFFSET(23'd0)) cache2_inst (
		.clk(clk), .reset(reset),
		.byte_addr(c_addr), .data(c2_data), .ready(c2_ready), .stall(c2_stall),
		.sd_addr(a_addr[2]), .sd_req(a_req[2]), .sd_busy(a_busy[2]), .sd_valid(a_valid[2]), .sd_dout(a_dout[2]), .sd_dout_pair(a_dout_pair[2])
	);

	sdram_req w_req_inst (
		.clk(clk), .reset(reset),
		.addr(w_addr), .we(1'b1), .wrl(1'b1), .wrh(1'b1), .din(w_din),
		.req(w_req), .busy(w_busy), .valid(w_valid), .dout(),
		.sdram_addr(p1_addr), .sdram_wrl(p1_wrl), .sdram_wrh(p1_wrh),
		.sdram_din(p1_din), .sdram_dout(p1_dout_from_sdram), .sdram_req(p1_req), .sdram_ack(p1_ack)
	);

endmodule
