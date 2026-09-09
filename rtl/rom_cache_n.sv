// Small fully associative read cache over one SDRAM channel, for the
// 68000 program ROM: LINES aligned word pairs (what rtl/sdram.sv returns
// per transaction) with FIFO replacement, plus an optional prefetch of
// the pair following the one being read. Same consumer/port interface
// as rom_cache1.sv, which it replaces on the CPU program port.
//
// Why (docs/hw-bringup.md, "Slowdown"): the real board and MAME run
// the 68000 with zero wait states from EPROM. Through the 1-line
// rom_cache1 56% of ROM bus cycles missed (the instruction stream and
// the game's ROM data-table reads thrash a single pair) and each miss
// is a ~10 clk_sys SDRAM round trip, 1-2 wait states — 13-20% of every
// frame spent stalled, which surfaces as slowdown wherever MAME's CPU
// is already near the frame budget. Replaying the recorded ROM-access
// trace (tools/rom_cache_eval.py): 16 lines alone leave 4% misses
// (sequential streaming through code and tables executed once per
// frame); 16 lines + next-pair prefetch leave 0.35%.
//
// Replacement never targets the line the consumer is reading right
// now: a fill landing on it between the 68000's DTACK sample and its
// data latch would hand the CPU garbage (the race rom_cache1's
// address gating in the cores guards against — keep that gating, the
// cache still only ever sees ROM addresses).
//
// Port protocol: req held high, address stable, until sd_valid; then
// low for at least one cycle before the next request — works with a
// direct sdram_req.sv (rising-edge trigger) and an sdram_arb channel.
module rom_cache_n #(
	parameter LINES = 16,
	parameter PREFETCH = 1,
	// Last pair of the ROM: nothing is prefetched past it (the SDRAM
	// beyond holds other ROMs; the read would be harmless but wasted).
	parameter [23:2] LAST_PAIR = 22'h01FFFF
) (
	input         clk,
	input         reset,

	input  [23:1] addr,
	output [15:0] data,
	output        ready,   // level: 1 iff `data` reflects `addr` right now

	output [24:1] sd_addr,
	output        sd_req,
	input         sd_busy,
	input         sd_valid,
	input  [15:0] sd_dout,      // unused: the pair is what gets cached
	input  [31:0] sd_dout_pair
);

	localparam IW = (LINES <= 1) ? 1 : $clog2(LINES);

	reg [23:2]      tag  [0:LINES-1];
	reg [31:0]      line [0:LINES-1];   // {word(pair,1), word(pair,0)}
	reg [LINES-1:0] vld;
	reg [IW-1:0]    wr_ptr;
	reg             pending;
	reg [23:2]      req_pair;

	wire [23:2] want      = addr[23:2];
	wire [23:2] next_pair = want + 22'd1;

	reg          hit;
	reg [31:0]   hit_pair;
	reg [IW-1:0] hit_idx;
	reg          next_present;
	integer i;
	always @* begin
		hit = 1'b0; hit_pair = 32'd0; hit_idx = {IW{1'b0}}; next_present = 1'b0;
		for (i = 0; i < LINES; i = i + 1) begin
			if (vld[i] && tag[i] == want) begin
				hit      = 1'b1;
				hit_pair = hit_pair | line[i];   // tags are unique: at most one term
				hit_idx  = i[IW-1:0];
			end
			if (vld[i] && tag[i] == next_pair) next_present = 1'b1;
		end
	end

	assign data    = addr[1] ? hit_pair[31:16] : hit_pair[15:0];
	assign ready   = hit;
	assign sd_addr = {1'b0, req_pair, 1'b0};
	assign sd_req  = pending;

	wire [IW-1:0] wr_ptr_inc = wr_ptr + 1'b1;
	wire [IW-1:0] slot       = (hit && hit_idx == wr_ptr) ? wr_ptr_inc : wr_ptr;
	wire          want_pf    = (PREFETCH != 0) && hit && !next_present && (want != LAST_PAIR);

	always @(posedge clk) begin
		if (reset) begin
			vld     <= {LINES{1'b0}};
			pending <= 1'b0;
			wr_ptr  <= {IW{1'b0}};
		end else if (!pending) begin
			if (!hit) begin
				req_pair <= want;
				pending  <= 1'b1;
			end else if (want_pf && !sd_busy) begin
				req_pair <= next_pair;
				pending  <= 1'b1;
			end
		end else if (sd_valid) begin
			tag[slot]  <= req_pair;
			line[slot] <= sd_dout_pair;
			vld[slot]  <= 1'b1;
			wr_ptr     <= slot + 1'b1;
			pending    <= 1'b0;
		end
	end

endmodule
