// Byte-addressed wrapper around rtl/rom_cache1.sv — every ROM consumer
// in this project except the 68000 (Z80 program fetch, OKI sample
// fetch, tile-graphics fetch) reads single bytes, but rom_cache1/SDRAM
// work at 16-bit word granularity. BASE_WORD_OFFSET places this
// region at its own fixed absolute offset in the shared 32MB SDRAM
// address space (see docs/hw-bringup.md's per-game byte-offset table —
// pass BASE_WORD_OFFSET = that region's byte offset / 2).
module rom_cache1_byte #(
	parameter [22:0] BASE_WORD_OFFSET = 23'd0
) (
	input         clk,
	input         reset,

	input  [23:0] byte_addr,  // relative to this region's own base
	output [7:0]  data,
	output        ready,

	output [24:1] sd_addr,
	output        sd_req,
	input         sd_busy,
	input         sd_valid,
	input  [15:0] sd_dout,
	input  [31:0] sd_dout_pair
);

	wire [22:0] word_addr = BASE_WORD_OFFSET + byte_addr[23:1];
	wire [15:0] word_data;

	rom_cache1 cache_inst (
		.clk(clk), .reset(reset),
		.addr(word_addr), .data(word_data), .ready(ready),
		.sd_addr(sd_addr), .sd_req(sd_req), .sd_busy(sd_busy), .sd_valid(sd_valid), .sd_dout(sd_dout), .sd_dout_pair(sd_dout_pair)
	);

	assign data = byte_addr[0] ? word_data[15:8] : word_data[7:0];

endmodule
