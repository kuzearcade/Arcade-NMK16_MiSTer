// Byte-addressed wrapper around rtl/rom_cache_n.sv, the multi-line
// counterpart of rom_cache1_byte.sv. Used for the sprite tile fetch of
// the compositing pass: a 16x16 unit is 32 aligned 4-byte groups (left
// half rows at +0, right half at +64), each drawn in 8 cycles, while an
// SDRAM round trip through the arbiter is ~12 — with a 1-line cache
// every group cost a full round trip and the pass could not finish
// inside a frame at the sprite loads the game runs (800-1200 on-screen
// units per gameplay frame, see docs/hw-bringup.md "Slowdown"), which
// delayed the plane swap and halved the sprite update rate. The
// next-pair prefetch overlaps the fetch of the following group with the
// drawing of the current one; LINES >= 4 keeps both row halves and
// their successors resident.
module rom_cache_n_byte #(
	parameter [22:0] BASE_WORD_OFFSET = 23'd0,
	parameter        LINES = 8,
	parameter        PREFETCH = 1,
	parameter [23:0] REGION_BYTES = 24'h400000  // size of this region: nothing is prefetched past its end
) (
	input         clk,
	input         reset,

	input  [23:0] byte_addr,  // relative to this region's own base
	output [7:0]  data,
	output [15:0] word,
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
	localparam [23:2] LAST_PAIR = (BASE_WORD_OFFSET + REGION_BYTES[23:1] - 23'd1) >> 1;

	rom_cache_n #(.LINES(LINES), .PREFETCH(PREFETCH), .LAST_PAIR(LAST_PAIR)) cache_inst (
		.clk(clk), .reset(reset),
		.addr(word_addr), .data(word_data), .ready(ready),
		.sd_addr(sd_addr), .sd_req(sd_req), .sd_busy(sd_busy), .sd_valid(sd_valid), .sd_dout(sd_dout), .sd_dout_pair(sd_dout_pair)
	);

	assign data = byte_addr[0] ? word_data[15:8] : word_data[7:0];
	assign word = word_data;

endmodule
