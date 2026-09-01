// Testbench for rtl/mustang/mustang_core.sv — the first system-level
// integration milestone for Tier 2 (see that module's own header for full
// scope/simplifications). Runs mustang's real 68000 program ROM alongside
// the real NMK004 boot ROM + external program, and answers the specific
// question CPU-only verification (sim/rtl/tlcs90/tb_nmk004.cpp) couldn't:
// does NMK004 actually get *past* its host-handshake poll loop once a
// real 68000 is wired up on the other end of it?
//
// Logs NMK004's PC trace to nmk004_sys.trace in the exact same plain
// "%04X\n per instruction boundary" format tb_tlcs90.cpp/tb_nmk004.cpp
// already use, so it's directly diffable with the same oracle-comparison
// tooling and against the same MAME oracle capture used throughout Tier 2
// (see docs/tier2-tlcs90.md).
#include <cstdint>
#include <cstdio>

#include "Vmustang_core.h"
#include "verilated.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 25000000; // clk_sys (32MHz) cycles

// The CPU-only testbench's polling loop was PC=0x0EAB/0x0EB1 (LD D,($FB00) /
// CP A,D / JR NZ,$0EAB) — see docs/tier2-tlcs90.md's "Third verification
// result". Track visits to that PC as the thing we're trying to get past.
static constexpr uint16_t POLL_LOOP_PC = 0x0EB1;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vmustang_core top{&contextp};
	FILE *nmk004_trace = std::fopen("nmk004_sys.trace", "w");

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint64_t nmk004_instrs = 0;
	uint64_t poll_loop_visits = 0;
	uint64_t last_pc = 0;
	bool     prev_dbg_valid = false;

	// 68000 side: track the most recent instruction-fetch address (same
	// FC1&&!FC0 technique tb_bjtwin.cpp already established, since fx68k
	// has no direct PC pin) and every completed bus write, so a stall can
	// actually be diagnosed instead of just observed.
	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0;
	uint32_t last_fetch_pc = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		// dbg_nmk004_valid lives on the divided-down NMK004 clock domain
		// (nmk004_clk_r, clk_sys/4 — see mustang_core.sv's header) but
		// this loop samples every clk_sys tick, so the same asserted
		// value would otherwise be read (and logged) up to 4x in a row.
		// Edge-detect it here instead of trusting the raw level.
		bool dbg_valid_now = top.dbg_nmk004_valid;
		if (dbg_valid_now && !prev_dbg_valid) {
			uint16_t pc = top.dbg_nmk004_pc;
			std::fprintf(nmk004_trace, "%04X\n", pc);
			nmk004_instrs++;
			if (pc == POLL_LOOP_PC) poll_loop_visits++;
			last_pc = pc;
		}
		prev_dbg_valid = dbg_valid_now;

		// 68000 side: same edge-detected-bus-cycle-completion technique
		// tb_bjtwin.cpp already established (see its own header for why:
		// fx68k has no direct PC pin, so an instruction-fetch cycle's own
		// address bus IS the fetch PC).
		if (!top.dbg_as_n) {
			last_addr = (uint32_t)top.dbg_eab << 1;
			last_data = top.dbg_data;
			prev_write = top.dbg_write;
			prev_is_fetch = top.dbg_fc1 && !top.dbg_fc0;
		}
		bool as_n_now = top.dbg_as_n;
		if (!prev_as_n && as_n_now) {
			if (prev_write) {
				m68k_writes++;
				if (log_m68k)
					std::fprintf(stderr, "cycle=%llu m68k W %06X = %04X\n",
					             (unsigned long long)clk_sys_ticks, last_addr, last_data);
			}
			if (!prev_write && prev_is_fetch) last_fetch_pc = last_addr;
		}
		prev_as_n = as_n_now;
	};

	for (uint64_t i = 0; i < RESET_CYCLES; i++) tick();
	top.reset = 0;

	for (uint64_t i = 0; i < RUN_CYCLES; i++) tick();

	std::fclose(nmk004_trace);
	bool still_in_loop = (last_pc == 0x0EAB || last_pc == 0x0EAF || last_pc == 0x0EB1);
	std::printf("tb_mustang: ran %llu clk_sys cycles (~%llu 68000 bus cycles), NMK004 executed %llu instructions (last PC=$%04X)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4), (unsigned long long)nmk004_instrs, (unsigned)last_pc);
	std::printf("tb_mustang: NMK004 visited the poll-loop's own PC ($%04X) %llu of those %llu instructions (%.1f%%)\n",
	            POLL_LOOP_PC, (unsigned long long)poll_loop_visits, (unsigned long long)nmk004_instrs,
	            nmk004_instrs ? 100.0 * poll_loop_visits / nmk004_instrs : 0.0);
	std::printf("tb_mustang: NMK004 is %s the host-handshake poll loop at end of run\n",
	            still_in_loop ? "STILL STUCK IN" : "past");
	std::printf("tb_mustang: 68000 last instruction-fetch PC=$%06X, completed %u write bus cycles total\n",
	            last_fetch_pc, m68k_writes);
	return 0;
}
