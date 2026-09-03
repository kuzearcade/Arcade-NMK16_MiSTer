// Standalone-test wrapper: two nmk214 instances (MODE=0/1, both default
// identity ADDR_BITSWAP so the testbench's own C++ reference model can
// stay address-bitswap-agnostic and focus on the hand-transcribed
// config/selector/output-bitswap tables — the highest-risk part of the
// SV port). See tb_nmk214.cpp.
module nmk214_tb_top (
	input         clk,
	input         reset0,
	input         reset1,

	input         cfg_we0,
	input   [7:0] cfg_data0,
	output        initialized0,
	input  [20:0] addr0,
	input  [15:0] din0,
	output [15:0] dout_word0,
	input   [7:0] din80,
	output  [7:0] dout_byte0,

	input         cfg_we1,
	input   [7:0] cfg_data1,
	output        initialized1,
	input  [20:0] addr1,
	input  [15:0] din1,
	output [15:0] dout_word1,
	input   [7:0] din81,
	output  [7:0] dout_byte1
);

	nmk214 #(.MODE(1'b0)) u0 (
		.clk(clk), .reset(reset0),
		.cfg_we(cfg_we0), .cfg_data(cfg_data0), .initialized(initialized0),
		.addr(addr0), .din(din0), .dout_word(dout_word0),
		.din8(din80), .dout_byte(dout_byte0)
	);

	nmk214 #(.MODE(1'b1)) u1 (
		.clk(clk), .reset(reset1),
		.cfg_we(cfg_we1), .cfg_data(cfg_data1), .initialized(initialized1),
		.addr(addr1), .din(din1), .dout_word(dout_word1),
		.din8(din81), .dout_byte(dout_byte1)
	);

endmodule
