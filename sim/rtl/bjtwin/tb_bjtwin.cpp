// Testbench for rtl/bjtwin/bjtwin_core.sv — runs the real cactus 68000 ROM
// (converted by tools/mkrom.py) and logs every completed bus write cycle
// through NmkTraceWriter, in the same nmktrace v1 grammar as
// sim/oracle/trace.lua, for comparison via sim/compare/oracle_diff.py
// against a real MAME-captured oracle trace
// (sim/oracle/traces/cactus_io.trace).
//
// A bus write "completes" when ASn rises after having been asserted with
// eRWn low — the module exposes dbg_* signals sampled combinationally
// from the live bus, so this testbench does the edge detection rather
// than the RTL, keeping bjtwin_core's debug port simple.
//
// Timestamps are logged in CPU-clock cycles (matching the oracle's
// clock_hz=10000000, since bjtwin_core's CPU clock enable is undivided
// 10MHz from the 40MHz clk_sys via the /4 fx68k phase pattern) — a plain
// clk_sys tick counter divided by 4 approximates this closely enough for
// a first ordered-sequence comparison; exact cycle alignment against
// MAME's own bus-cycle timing model is a follow-up refinement once the
// value sequence itself is confirmed to match.

#include <cstdint>
#include <cstdio>

#include "Vbjtwin_core.h"
#include "verilated.h"

#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 400000; // clk_sys cycles; see header comment for budget rationale

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vbjtwin_core top{&contextp};
	NmkTraceWriter trace("cactus_rtl.trace", "cactus", 10000000, ":maincpu", "program", 0x80000, 0xfffff, "-");

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	bool prev_as_n = true;
	bool prev_write = false;
	uint32_t last_addr = 0, last_data = 0, last_mask = 0;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;
	};

	for (uint64_t i = 0; i < RESET_CYCLES; i++) {
		tick();
	}
	top.reset = 0;

	for (uint64_t i = 0; i < RUN_CYCLES; i++) {
		// Sample bus state while ASn is asserted, so we have the
		// last-valid values in hand when it rises.
		if (!top.dbg_as_n) {
			last_addr = (uint32_t)top.dbg_eab << 1;
			last_data = top.dbg_data;
			uint32_t mask = 0;
			if (!top.dbg_uds_n) mask |= 0xff00;
			if (!top.dbg_lds_n) mask |= 0x00ff;
			last_mask = mask;
			prev_write = top.dbg_write;
		}

		bool as_n_now = top.dbg_as_n;
		if (prev_as_n == false && as_n_now == true) {
			// bus cycle just completed
			if (prev_write) {
				uint64_t cpu_cycle = clk_sys_ticks / 4;
				trace.bus(cpu_cycle, 'w', last_addr, last_data, last_mask);
			}
		}
		prev_as_n = as_n_now;

		tick();
	}

	trace.flush();
	std::printf("tb_bjtwin: ran %llu clk_sys cycles (~%llu CPU cycles), wrote cactus_rtl.trace\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4));
	return 0;
}
