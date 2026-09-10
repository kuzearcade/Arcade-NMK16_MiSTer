// Multi-line, prefetching byte cache for an OKIM6295 (jt6295) sample ROM
// held in SDRAM.
//
// Why rom_cache1_byte is not enough here: jt6295's ADPCM data path never
// looks at rom_ok (rtl/third_party/jt6295/hdl/jt6295_rom.v). Each
// channel slot it drives rom_addr with the sample address for two
// cen_sr32 periods (~100 clk_sys at 40MHz/4MHz cen) and keeps whatever
// rom_data shows on the last clock of the second period; the rest of
// the slot rom_addr carries the phrase-table (ctrl) address, whose read
// IS rom_ok-gated. With a single-line cache the two addresses evict each
// other every slot, so every sample byte is an SDRAM round trip through
// the arbitrated port (Z80 + the other OKI), and any trip longer than
// the window hands the decoder a stale byte from the previous line —
// ADPCM is differential, so one bad nibble smears into a burst of noise
// until the phrase ends. The reference sim (registered ROM array,
// rom_ok=1) can never show this.
//
// This module fixes it two ways:
//   1. LINES fully-associative 4-byte lines (one SDRAM pair read each),
//      NRU replacement, so the four channels' current lines and the
//      ctrl line all stay resident, and a sequential prefetch of the
//      next line once a channel has consumed the second byte of its
//      current one — ADPCM phrases are read strictly sequentially, so
//      the demanded byte is normally already here.
//   2. `stall`: high whenever the presented byte is not resident. The
//      core ANDs it out of the chip's `cen`, which freezes every
//      internal timing pulse of jt6295 (all derive from cen — see
//      jt6295_timing.v) while the fetch completes. A miss then costs a
//      few clk_sys of time stretch instead of a wrong byte. The write
//      strobe is sampled on clk, not cen, so Z80 writes during a stall
//      are not lost (jt6295_ctrl.v `last_wrn`).
//
// SDRAM side is the same request/valid protocol as rom_cache1
// (sd_req held until sd_valid; the returned sd_dout_pair is the aligned
// word pair containing the requested word), so it drops into the same
// sdram_arb channel.
module oki_rom_cache #(
	parameter [22:0] BASE_WORD_OFFSET = 23'd0,
	parameter        LINES = 16
) (
	input         clk,
	input         reset,

	input  [21:0] byte_addr,   // after NMK112 remap, relative to this ROM
	output [7:0]  data,
	output        ready,       // level: data reflects byte_addr right now
	output        stall,       // = !ready; gate the chip's cen with ~stall

	output [24:1] sd_addr,
	output        sd_req,
	input         sd_busy,
	input         sd_valid,
	input  [15:0] sd_dout,
	input  [31:0] sd_dout_pair
);

	localparam LW = (LINES > 1) ? $clog2(LINES) : 1;

	reg [19:0] tag   [0:LINES-1];   // byte_addr[21:2]
	reg [31:0] pair  [0:LINES-1];   // {byte3, byte2, byte1, byte0}
	reg        valid [0:LINES-1];
	reg        used  [0:LINES-1];   // NRU reference bit

	wire [19:0] line_cur  = byte_addr[21:2];
	wire [19:0] line_next = line_cur + 20'd1;

	// Lookup (combinational, LINES-way compare).
	reg          hit_cur, hit_next;
	reg [LW-1:0] idx_cur;
	integer i;
	always @* begin
		hit_cur = 1'b0; hit_next = 1'b0; idx_cur = {LW{1'b0}};
		for (i = 0; i < LINES; i = i + 1) begin
			if (valid[i] && tag[i] == line_cur)  begin hit_cur = 1'b1; idx_cur = i[LW-1:0]; end
			if (valid[i] && tag[i] == line_next) hit_next = 1'b1;
		end
	end

	wire [31:0] pair_cur = pair[idx_cur];
	assign data  = byte_addr[1] ? (byte_addr[0] ? pair_cur[31:24] : pair_cur[23:16])
	                            : (byte_addr[0] ? pair_cur[15:8]  : pair_cur[7:0]);
	assign ready = hit_cur;
	assign stall = ~hit_cur;

	// One outstanding SDRAM read. Demand miss first; otherwise prefetch
	// the following line once the current one is half consumed.
	reg          pending;
	reg [19:0]   req_line;
	reg          req_is_prefetch;
	reg [LW-1:0] victim;
	assign sd_req  = pending;
	assign sd_addr = {1'b0, BASE_WORD_OFFSET + {2'd0, req_line, 1'b0}};

	// NRU victim: first line, scanning from a rotating pointer, whose
	// reference bit is clear; the line the chip is reading right now is
	// never chosen. When every candidate is referenced, the bits are
	// cleared (below) and the scan retries next cycle.
	reg [LW-1:0] rr;
	reg          found;
	reg [LW-1:0] cand;
	integer k;
	always @* begin
		found = 1'b0; cand = rr;
		for (k = 0; k < LINES; k = k + 1) begin
			if (!found) begin
				cand = rr + k[LW-1:0];
				if (!used[cand] && !(hit_cur && cand == idx_cur)) found = 1'b1;
			end
		end
	end

	wire want_prefetch = hit_cur && !hit_next && byte_addr[1];  // bytes 2,3 of the line

`ifdef OKI_CACHE_DEBUG
	integer dbg_n = 0;
	reg dbg_stall_d = 1'b0;
	always @(posedge clk) begin
		dbg_stall_d <= stall;
		if (dbg_n < 60) begin
			if (!pending && !reset && (!hit_cur || want_prefetch) && found) begin
				$display("[%0t] OKICACHE %m issue line=%05x (%s) victim=%0d addr=%06x", $time, hit_cur ? line_next : line_cur, hit_cur ? "prefetch" : "demand", cand, byte_addr); dbg_n = dbg_n + 1;
			end
			if (pending && sd_valid) begin
				$display("[%0t] OKICACHE %m fill line=%05x sd_addr=%06x victim=%0d pair=%08x addr=%06x", $time, req_line, sd_addr, victim, sd_dout_pair, byte_addr); dbg_n = dbg_n + 1;
			end
			if (stall != dbg_stall_d) begin
				$display("[%0t] OKICACHE %m stall=%0d addr=%06x hit_cur=%0d pending=%0d found=%0d", $time, stall, byte_addr, hit_cur, pending, found); dbg_n = dbg_n + 1;
			end
			if (reset && dbg_stall_d != stall) begin $display("[%0t] OKICACHE %m in reset", $time); end
		end
	end
`endif

`ifdef VERILATOR
	// Evidence counter for the fill-vs-in-use-line hazard above: every
	// prefetch fill dropped because its victim became the line being read.
	// Before the guard, each of these was a clobbered byte the chip could
	// latch in the one-clock cen_sr32 window.
	integer dropped_prefetch_fills = 0;
	always @(posedge clk)
		if (!reset && pending && sd_valid && req_is_prefetch && hit_cur && victim == idx_cur)
			dropped_prefetch_fills = dropped_prefetch_fills + 1;
	final $display("%m: prefetch fills dropped because the victim became the in-use line: %0d", dropped_prefetch_fills);
`endif

	integer j;
	always @(posedge clk) begin
		if (reset) begin
			pending <= 1'b0;
			rr      <= {LW{1'b0}};
			for (j = 0; j < LINES; j = j + 1) begin
				valid[j] <= 1'b0;
				used[j]  <= 1'b0;
			end
		end else begin
			// Reference bit of the line being read.
			if (hit_cur) used[idx_cur] <= 1'b1;

			if (!pending) begin
				if (!hit_cur || want_prefetch) begin
					if (found) begin
						pending         <= 1'b1;
						req_line        <= hit_cur ? line_next : line_cur;
						req_is_prefetch <= hit_cur;
						victim          <= cand;
						rr              <= cand + 1'b1;
					end else begin
						// Everything referenced: age all lines except the one in use.
						for (j = 0; j < LINES; j = j + 1)
							if (!(hit_cur && j[LW-1:0] == idx_cur)) used[j] <= 1'b0;
					end
				end
			end else if (sd_valid) begin
				// A prefetch's victim was chosen at issue time as a line the
				// chip was NOT reading; the fill lands many clocks later, and
				// by then the chip may have moved onto that very line. Writing
				// it then would corrupt the byte being read — and jt6295's
				// latch pulse (cen_sr32, jt6295_timing.v) is registered one
				// clock after the gated cen, so if the overwrite lands on the
				// clock right after a cen that passed with stall=0, the chip
				// latches the clobbered byte before stall can freeze it. A
				// 1-in-727k event in the raphero_hw audit (docs/known-issues.md
				// NMK-15). Drop such a fill instead; want_prefetch stays high,
				// so the line is simply re-requested with a fresh victim (the
				// in-use line is now excluded by the scan). Demand misses can't
				// hit this: the chip's address is frozen by stall while they
				// are pending, so their victim can never become the in-use line.
				if (!(req_is_prefetch && hit_cur && victim == idx_cur)) begin
					tag[victim]   <= req_line;
					pair[victim]  <= sd_dout_pair;
					valid[victim] <= 1'b1;
					used[victim]  <= 1'b1;
				end
				pending       <= 1'b0;
			end
		end
	end

endmodule
