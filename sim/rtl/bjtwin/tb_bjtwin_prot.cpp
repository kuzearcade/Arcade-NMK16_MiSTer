// Testbench for rtl/bjtwin/bjtwin_prot_core.sv — the third Family D
// (TLCS-90/TMP90840 protection MCU) game, after macross/gunnail, and
// the smallest-scope one: reuses the already-verified cactus-family
// video/CPU architecture (bjtwin_core.sv) plus the already-built
// dual-NMK214 protection-MCU infrastructure (macross_core.sv's own
// pattern) directly. Modeled on tb_macross.cpp's own structure (no
// NMK004 here — bjtwin's own sound is nmk112 + 2x OKIM6295, no sound
// MCU at all — so this testbench drops the NMK004 trace streams
// tb_macross.cpp carries and keeps only the 68000 + protection-MCU
// streams plus the halt-transition log).
#include <cstdint>
#include <cstdio>

#include "Vbjtwin_prot_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 300000000;
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vbjtwin_prot_core top{&contextp};
	FILE *prot_trace = std::fopen("prot_sys.trace", "w");
	FILE *prot_cyc_trace = std::fopen("prot_cyc.trace", "w");
	FILE *prot_reg_trace = std::getenv("TB_LOG_PROT_REGS") != nullptr ? std::fopen("prot_regs.trace", "w") : nullptr;
	NmkTraceWriter trace("bjtwin_prot_video.trace", "bjtwin", 10000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;

	uint64_t prot_instrs = 0;
	uint64_t prot_last_pc = 0;
	bool     prot_prev_dbg_valid = false;
	bool     halt_prev = false;
	uint64_t halt_asserts = 0;
	bool     log_halt = std::getenv("TB_LOG_HALT") != nullptr;

	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0;
	uint32_t last_fetch_pc = 0;
	uint64_t fetch_start_ticks = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;
	FILE *m68k_trace = std::fopen("bjtwin_prot_68k.trace", "w");
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");
	uint64_t m68k_instrs = 0;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		bool prot_dbg_valid_now = top.dbg_prot_valid;
		if (prot_dbg_valid_now && !prot_prev_dbg_valid) {
			uint16_t pc = top.dbg_prot_pc;
			std::fprintf(prot_trace, "%04X\n", pc);
			std::fprintf(prot_cyc_trace, "%llu %04X\n", (unsigned long long)(clk_sys_ticks / 10), pc);
			if (prot_reg_trace)
				std::fprintf(prot_reg_trace, "%llu %04X HL=%04X VCOUNT=%u\n",
				             (unsigned long long)(clk_sys_ticks / 10), pc, (unsigned)top.dbg_prot_hl, (unsigned)top.dbg_vt_vcount);
			prot_instrs++;
			prot_last_pc = pc;
		}
		prot_prev_dbg_valid = prot_dbg_valid_now;

		bool halt_now = top.dbg_halt_68k;
		if (halt_now && !halt_prev) {
			halt_asserts++;
			if (log_halt)
				std::fprintf(stderr, "cycle=%llu 68000 HALT asserted (prot PC=$%04X)\n",
				             (unsigned long long)clk_sys_ticks, (unsigned)prot_last_pc);
		} else if (!halt_now && halt_prev) {
			if (log_halt)
				std::fprintf(stderr, "cycle=%llu 68000 HALT released (prot PC=$%04X)\n",
				             (unsigned long long)clk_sys_ticks, (unsigned)prot_last_pc);
		}
		halt_prev = halt_now;

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
			uint64_t cpu_cycle = clk_sys_ticks / 4;
			trace.frame(cpu_cycle, frame_count, frame_crc);

			if (std::getenv("TB_DUMP_PPM") != nullptr) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "bjtwin_prot_frame_%02u.ppm", frame_count);
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

	std::fclose(prot_trace);
	std::fclose(prot_cyc_trace);
	if (prot_reg_trace) std::fclose(prot_reg_trace);
	std::fclose(m68k_trace);
	std::fclose(m68k_cyc_trace);
	std::printf("tb_bjtwin_prot: ran %llu clk_sys cycles (~%llu 68000 bus cycles)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4));
	std::printf("tb_bjtwin_prot: protection MCU executed %llu instructions (last PC=$%04X), 68000 HALT asserted %llu times\n",
	            (unsigned long long)prot_instrs, (unsigned)prot_last_pc, (unsigned long long)halt_asserts);
	std::printf("tb_bjtwin_prot: 68000 last instruction-fetch PC=$%06X, completed %u write bus cycles total\n",
	            last_fetch_pc, m68k_writes);
	std::printf("tb_bjtwin_prot: rendered %u video frame(s), wrote bjtwin_prot_video.trace\n", frame_count);
	std::printf("tb_bjtwin_prot: 68000 executed %llu instructions, wrote bjtwin_prot_68k.trace\n", (unsigned long long)m68k_instrs);
	return 0;
}
