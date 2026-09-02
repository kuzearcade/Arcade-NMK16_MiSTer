// Testbench for rtl/strahl/strahl_core.sv — the fourth Tier 2
// NMK004-board game to get a system-level integration testbench, after
// sim/rtl/mustang/tb_mustang.cpp, sim/rtl/bioship/tb_bioship.cpp, and
// sim/rtl/blkheart/tb_blkheart.cpp (those files' own headers cover the
// shared rationale for every trace/instrumentation technique reused
// here unchanged). strahl's own clk_sys is 48MHz (not mustang's 32MHz
// or bioship's 40MHz — see strahl_core.sv's own header): the 68000's
// own bus-cycle divider is clk_sys/4=12MHz, NMK004/pixel is
// clk_sys/6=8MHz — cycle-trace divisors below reflect this (/4 for the
// 68000, /6 for NMK004).
//
// Like the prior two ports, this testbench does NOT hardcode a
// game-specific host-handshake poll-loop PC or root-cause capture
// point — no dedicated ROM disassembly investigation has been done for
// strahl's own boot sequence.
#include <cstdint>
#include <cstdio>

#include "Vstrahl_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 240000000;
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vstrahl_core top{&contextp};
	FILE *nmk004_trace = std::fopen("nmk004_sys.trace", "w");
	FILE *nmk004_cyc_trace = std::fopen("nmk004_cyc.trace", "w");
	NmkTraceWriter trace("strahl_video.trace", "strahl", 12000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;
	uint64_t nmk004_instrs = 0;
	uint64_t last_pc = 0;
	bool     prev_dbg_valid = false;

	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0;
	uint32_t last_fetch_pc = 0;
	uint64_t fetch_start_ticks = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;
	FILE *m68k_trace = std::fopen("strahl_68k.trace", "w");
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");
	uint64_t m68k_instrs = 0;

	bool ym_we_prev_dbg = false;
	uint32_t ym_we_count = 0;
	bool log_ym = std::getenv("TB_LOG_YM") != nullptr;

	bool oki0_we_prev_dbg = false, oki1_we_prev_dbg = false;
	uint32_t oki0_we_count = 0, oki1_we_count = 0;
	bool log_oki = std::getenv("TB_LOG_OKI") != nullptr;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		bool dbg_valid_now = top.dbg_nmk004_valid;
		if (dbg_valid_now && !prev_dbg_valid) {
			uint16_t pc = top.dbg_nmk004_pc;
			std::fprintf(nmk004_trace, "%04X\n", pc);
			// NMK004's own real clock is clk_sys/6 here (not /4 or /5 —
			// see strahl_core.sv's header).
			std::fprintf(nmk004_cyc_trace, "%llu %04X\n", (unsigned long long)(clk_sys_ticks / 6), pc);
			nmk004_instrs++;
			last_pc = pc;
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

		// 68000 side: fetch-bus-cycle-start timestamp (ASn's falling
		// edge), matching MAME's own totalcycles sample point — see
		// docs/tier2-system.md's "68000 bus-wait-state timing". The
		// 68000's own bus-cycle divider is clk_sys/4 here.
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
			// cpu_cycle here means the 68000's own cycle count (clk_sys/4,
			// matching every prior port's own convention).
			uint64_t cpu_cycle = clk_sys_ticks / 4;
			trace.frame(cpu_cycle, frame_count, frame_crc);

			if (std::getenv("TB_DUMP_PPM") != nullptr) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "strahl_frame_%02u.ppm", frame_count);
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
	std::printf("tb_strahl: ran %llu clk_sys cycles (~%llu 68000 bus cycles), NMK004 executed %llu instructions (last PC=$%04X)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4), (unsigned long long)nmk004_instrs, (unsigned)last_pc);
	std::printf("tb_strahl: 68000 last instruction-fetch PC=$%06X, completed %u write bus cycles total\n",
	            last_fetch_pc, m68k_writes);
	std::printf("tb_strahl: NMK004 wrote to YM2203 %u times\n", ym_we_count);
	std::printf("tb_strahl: NMK004 wrote to OKI1/OKI2 %u/%u times\n", oki0_we_count, oki1_we_count);
	std::printf("tb_strahl: rendered %u video frame(s), wrote strahl_video.trace\n", frame_count);
	std::printf("tb_strahl: 68000 executed %llu instructions, wrote strahl_68k.trace\n", (unsigned long long)m68k_instrs);

	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg0 = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 8192; i++) { top.dbg_bg0vram_addr = i; top.eval(); if (top.dbg_bg0vram_data != 0xFFFF) nonzero_bg0++; }
		for (int i = 0; i < 1024; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_strahl: non-blank palette=%d/1024 bg0vram=%d/8192 txvram=%d/1024\n",
		             nonzero_pal, nonzero_bg0, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_strahl: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
