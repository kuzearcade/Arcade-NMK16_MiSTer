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

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 60000000; // clk_sys (32MHz) cycles
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

// The CPU-only testbench's polling loop was PC=0x0EAB/0x0EB1 (LD D,($FB00) /
// CP A,D / JR NZ,$0EAB) — see docs/tier2-tlcs90.md's "Third verification
// result". Track visits to that PC as the thing we're trying to get past.
static constexpr uint16_t POLL_LOOP_PC = 0x0EB1;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vmustang_core top{&contextp};
	FILE *nmk004_trace = std::fopen("nmk004_sys.trace", "w");
	// Cycle-timestamped NMK004 trace ("<clk_sys_ticks/4> <PC>\n" per
	// instruction) — a *separate* file from nmk004_sys.trace (which stays
	// pure PC-per-line for the existing oracle-match tooling). clk_sys/4
	// matches NMK004's own real 8MHz clock (nmk004_clk_r), the same
	// domain MAME's own `totalcycles` debugger symbol counts in for this
	// device — see docs/tier2-system.md's "Cycle-timestamped NMK004
	// trace tooling".
	FILE *nmk004_cyc_trace = std::fopen("nmk004_cyc.trace", "w");
	NmkTraceWriter trace("mustang_video.trace", "mustang", 8000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;
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
	uint64_t fetch_start_ticks = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;
	FILE *m68k_trace = std::fopen("mustang_68k.trace", "w");
	uint64_t m68k_instrs = 0;
	// Cycle-timestamped 68000 trace ("<clk_sys_ticks/4> <PC>\n" per
	// instruction fetch) — same two-column format/rationale as
	// nmk004_cyc.trace above, for diffing against a MAME
	// `:maincpu`-focused capture_cyc_trace.py capture via cyc_diff.py.
	// clk_sys/4 matches the 68000's own real 8MHz clock (mustang() in
	// nmk16.cpp: M68000(config, m_maincpu, XTAL(8'000'000))).
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");

	// YM2203 (jt03) bus/IRQ debug, same tier as TB_LOG_M68K — see
	// docs/tier2-system.md's "Milestone 3".
	bool ym_we_prev_dbg = false;
	uint32_t ym_we_count = 0;
	bool log_ym = std::getenv("TB_LOG_YM") != nullptr;

	// OKIM6295 x2 (jt6295) bus debug, same tier as TB_LOG_YM — see
	// docs/tier2-system.md's "Real jt6295 (OKIM6295 x2) integration".
	bool oki0_we_prev_dbg = false, oki1_we_prev_dbg = false;
	uint32_t oki0_we_count = 0, oki1_we_count = 0;
	bool log_oki = std::getenv("TB_LOG_OKI") != nullptr;

	// One-shot(-ish) capture of live register/RAM state whenever NMK004
	// reaches the RET Z at 0x0E5F — for root-causing the oracle divergence
	// there (see docs/tier2-system.md, "RET Z at 0x0E5F"). Logs every hit,
	// same as the MAME debugger capture this is meant to be diffed against.
	static constexpr uint16_t RETZ_PC = 0x0E5F;
	uint64_t retz_hits = 0;
	bool log_retz = std::getenv("TB_LOG_RETZ") != nullptr;

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
			std::fprintf(nmk004_cyc_trace, "%llu %04X\n", (unsigned long long)(clk_sys_ticks / 4), pc);
			nmk004_instrs++;
			if (pc == POLL_LOOP_PC) poll_loop_visits++;
			last_pc = pc;
			if (pc == RETZ_PC) {
				retz_hits++;
				if (log_retz)
					std::fprintf(stderr, "cycle=%llu RETZ_HIT pc=%04x A=%02x HL=%04x memHL=%02x F=%02x\n",
					             (unsigned long long)clk_sys_ticks, pc, top.dbg_nmk004_a,
					             top.dbg_nmk004_hl, top.dbg_nmk004_ram_hl, top.dbg_nmk004_f);
			}
		}
		prev_dbg_valid = dbg_valid_now;

		bool ym_we_now = top.dbg_ym_we;
		if (ym_we_now && !ym_we_prev_dbg) {
			ym_we_count++;
			if (log_ym)
				std::fprintf(stderr, "cycle=%llu ym_we cs=%d dout=%02X irq_n=%d\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_ym_cs,
				             top.dbg_ym_chip_dout, top.dbg_ym_chip_irq_n);
		}
		ym_we_prev_dbg = ym_we_now;

		bool oki0_we_now = top.dbg_oki0_we;
		if (oki0_we_now && !oki0_we_prev_dbg) {
			oki0_we_count++;
			if (log_oki)
				std::fprintf(stderr, "cycle=%llu oki0_we cs=%d dout=%02X\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_oki0_cs, top.dbg_oki0_chip_dout);
		}
		oki0_we_prev_dbg = oki0_we_now;

		bool oki1_we_now = top.dbg_oki1_we;
		if (oki1_we_now && !oki1_we_prev_dbg) {
			oki1_we_count++;
			if (log_oki)
				std::fprintf(stderr, "cycle=%llu oki1_we cs=%d dout=%02X\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_oki1_cs, top.dbg_oki1_chip_dout);
		}
		oki1_we_prev_dbg = oki1_we_now;

		// 68000 side: same edge-detected-bus-cycle-completion technique
		// tb_bjtwin.cpp already established (see its own header for why:
		// fx68k has no direct PC pin, so an instruction-fetch cycle's own
		// address bus IS the fetch PC).
		//
		// The cycle *timestamp* logged to m68k_cyc_trace below is taken at
		// the fetch bus cycle's own START (ASn's falling edge), not its
		// completion — matching MAME's own `totalcycles` sample point
		// (captured by the trace command's own action, which runs BEFORE
		// each instruction executes) and this project's existing
		// nmk004_cyc_trace convention (dbg_valid pulses at fetch-start,
		// not fetch-completion). A wait-state-lengthened fetch must not
		// shift its own start time.
		if (prev_as_n && !top.dbg_as_n) fetch_start_ticks = clk_sys_ticks;
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
			if (!prev_write && prev_is_fetch) {
				last_fetch_pc = last_addr;
				std::fprintf(m68k_trace, "%06X\n", last_fetch_pc);
				std::fprintf(m68k_cyc_trace, "%llu %06X\n", (unsigned long long)(fetch_start_ticks / 4), last_fetch_pc);
				m68k_instrs++;
			}
		}
		prev_as_n = as_n_now;

		// Video frame checksum, same methodology as tb_bjtwin.cpp / this
		// project's own sim/oracle/trace.lua screen:pixel() loop — see
		// docs/tier2-system.md's "Milestone 6" (mustang video pipeline).
		bool frame_done_now = top.frame_done;
		if (!prev_frame_done && frame_done_now) {
			uint8_t bytes[SCREEN_W * SCREEN_H * 3];
			size_t bi = 0;
			for (int y = 0; y < SCREEN_H; y++) {
				for (int x = 0; x < SCREEN_W; x++) {
					top.rd_x = x;
					top.rd_y = y;
					top.eval();
					uint32_t rgb = top.rd_rgb;
					bytes[bi++] = (uint8_t)(rgb & 0xFF);
					bytes[bi++] = (uint8_t)((rgb >> 8) & 0xFF);
					bytes[bi++] = (uint8_t)((rgb >> 16) & 0xFF);
				}
			}
			uint32_t frame_crc = crc.compute(bytes, bi);
			uint64_t cpu_cycle = clk_sys_ticks / 4;
			trace.frame(cpu_cycle, frame_count, frame_crc);

			if (std::getenv("TB_DUMP_PPM") != nullptr) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "mustang_frame_%02u.ppm", frame_count);
				FILE *ppm = std::fopen(fname, "wb");
				std::fprintf(ppm, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
				for (int y = 0; y < SCREEN_H; y++) {
					for (int x = 0; x < SCREEN_W; x++) {
						top.rd_x = x;
						top.rd_y = y;
						top.eval();
						uint32_t rgb = top.rd_rgb;
						uint8_t rgb_bytes[3] = {
							(uint8_t)((rgb >> 16) & 0xFF),
							(uint8_t)((rgb >> 8) & 0xFF),
							(uint8_t)(rgb & 0xFF)
						};
						std::fwrite(rgb_bytes, 1, 3, ppm);
					}
				}
				std::fclose(ppm);
			}

			frame_count++;
		}
		prev_frame_done = frame_done_now;
	};

	for (uint64_t i = 0; i < RESET_CYCLES; i++) tick();
	top.reset = 0;

	for (uint64_t i = 0; i < RUN_CYCLES; i++) tick();

	std::fclose(nmk004_trace);
	std::fclose(nmk004_cyc_trace);
	std::fclose(m68k_trace);
	std::fclose(m68k_cyc_trace);
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
	std::printf("tb_mustang: NMK004 wrote to YM2203 %u times\n", ym_we_count);
	std::printf("tb_mustang: NMK004 wrote to OKI1/OKI2 %u/%u times\n", oki0_we_count, oki1_we_count);
	std::printf("tb_mustang: NMK004 reached PC=$%04X (RET Z) %llu times\n", RETZ_PC, (unsigned long long)retz_hits);
	std::printf("tb_mustang: rendered %u video frame(s), wrote mustang_video.trace\n", frame_count);
	std::printf("tb_mustang: 68000 executed %llu instructions, wrote mustang_68k.trace\n", (unsigned long long)m68k_instrs);

	// VRAM/palette content + rendered-pixel sanity summary, same tier as
	// the other TB_LOG_*/TB_DUMP_* env vars — permanent bring-up
	// diagnostics for the video pipeline (see docs/tier2-system.md's
	// "Milestone 6"), not throwaway scaffolding.
	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 8192; i++) { top.dbg_bgvram_addr = i; top.eval(); if (top.dbg_bgvram_data != 0xFFFF) nonzero_bg++; }
		for (int i = 0; i < 1024; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_mustang: non-blank palette=%d/1024 bgvram=%d/8192 txvram=%d/1024\n",
		             nonzero_pal, nonzero_bg, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_mustang: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
