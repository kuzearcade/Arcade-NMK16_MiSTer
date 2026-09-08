// Generic 1-line (2-word, aligned pair) read cache over one SDRAM channel (a direct
// rtl/sdram_req.sv port or one logical channel of an rtl/sdram_arb.sv
// arbiter). Presents a simple "current data for the currently-wanted
// address, or not ready yet" interface to a consumer whose own address
// input may be a live combinational signal (a CPU bus address, a video
// tile-fetch address, an OKI chip's own rom_addr output) — refetches
// automatically whenever that address changes, and correctly tracks a
// request that's still in flight even if the consumer's own address
// moves on again before the fetch completes (the actually-in-flight
// address is latched at request time, not re-read live).
//
// This is the one primitive every ROM consumer in this project's
// hardware bring-up work is built on — see docs/hw-bringup.md. A
// consumer whose own address is held perfectly stable for the whole
// time it cares about the result (a 68000/Z80 bus cycle) gets a plain
// single-fetch-then-cached-until-address-changes behavior; a consumer
// whose address free-runs (BG/TX/sprite tile fetch, keyed to the
// pixel/unit currently being drawn) gets automatic re-fetching that
// converges to a hit as soon as the address stops moving faster than
// one fetch round-trip.
module rom_cache1
(
	input         clk,
	input         reset,

	input  [23:1] addr,
	output [15:0] data,
	output        ready,   // level: 1 iff `data` reflects `addr` right now

	// one sdram_req.sv port, or one logical channel of an sdram_arb.sv
	// instance — same shape either way. Since rtl/sdram.sv returns the
	// aligned word PAIR containing any requested address, this is a
	// 2-word line cache: sd_dout_pair is what gets cached, sd_dout is
	// unused (kept so existing instantiations still connect).
	output [24:1] sd_addr,
	output        sd_req,
	input         sd_busy,  // sdram_req's busy, or sdram_arb's i_busy for this channel
	input         sd_valid,
	input  [15:0] sd_dout,
	input  [31:0] sd_dout_pair
);

	reg [23:2] cached_tag;   // aligned pair address
	reg [31:0] cached_pair;  // {word(tag,1), word(tag,0)}
	reg        have_cache;
	reg [23:1] req_addr;
	reg        pending;

	wire addr_match = have_cache && (cached_tag == addr[23:2]);

	assign data     = addr[1] ? cached_pair[31:16] : cached_pair[15:0];
	assign ready    = addr_match;
	assign sd_addr  = req_addr;
	assign sd_req   = pending;

	always @(posedge clk) begin
		if (reset) begin
			have_cache <= 1'b0;
			pending    <= 1'b0;
		end else begin
			if (!pending && !addr_match) begin
				req_addr <= addr;
				pending  <= 1'b1;
			end
			if (pending && sd_valid) begin
				cached_tag  <= req_addr[23:2];
				cached_pair <= sd_dout_pair;
				have_cache  <= 1'b1;
				pending     <= 1'b0;
`ifdef ROM_CACHE1_DEBUG
				$display("[%0t] CACHE1 fetch-done req_addr=%06x pair=%08x", $time, req_addr, sd_dout_pair);
`endif
			end
`ifdef ROM_CACHE1_DEBUG
			if (!pending && !addr_match) $display("[%0t] CACHE1 issue addr=%06x", $time, addr);
`endif
		end
	end

endmodule
