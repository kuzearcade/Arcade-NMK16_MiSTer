// Testbench for the macross2 game running on the SHARED Family C core,
// rtl/tdragon2/tdragon2_core.sv (game_macross2=1 — see that file's own
// header: it now serves both tdragon2 and macross2 from one module,
// selected at runtime, not synthesis time). Originally this testbench
// built rtl/macross2/macross2_core.sv as its own separate module; that
// file was retired once the two cores were merged (see git history for
// the pre-merge standalone version if needed) — this testbench's own
// checks are unchanged: whether the NMK112 dual-OKI bank-switcher, the
// real V-PROM nmk_irq, the direct Z80+YM2203 sound path (soundlatch here
// is a plain polling register, no NMI — see the core's own header), and
// the 4-bank ("tilerambank") wide BG tilemap all produce a correct render
// when driven by two real CPUs, now via game_macross2=1 on the shared
// core rather than a dedicated module.
//
// PC tracking: same M1_n-falling-edge (Z80) / ASn-falling-edge (68000)
// technique every prior port's own testbench uses — T80s.v/fx68k have no
// direct PC pin.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vtdragon2_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 300000000; // clk_sys (40MHz) cycles = 7.5 real seconds
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vtdragon2_core top{&contextp};
	top.game_macross2 = 1;

	FILE *z80_trace = std::fopen("macross2_z80.trace", "w");
	FILE *z80_cyc_trace = std::fopen("z80_cyc.trace", "w");
	FILE *m68k_trace = std::fopen("macross2_68k.trace", "w");
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");
	NmkTraceWriter trace("macross2_video.trace", "macross2", 10000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;

	// Z80 side. z80_cen_ticks counts dbg_z80_cen pulses — the real
	// Z80-clock-equivalent tick count (4MHz), directly comparable to
	// MAME's own `totalcycles` for :audiocpu.
	bool     prev_m1_n = true;
	uint64_t z80_instrs = 0;
	uint16_t last_z80_pc = 0;
	uint64_t z80_cen_ticks = 0;
	bool     prev_z80_cen = false;
	bool     log_z80 = std::getenv("TB_LOG_Z80") != nullptr;

	// 68000 side (same edge-detected-bus-cycle-completion technique as
	// every prior port's own testbench — fx68k has no direct PC pin).
	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0;
	uint32_t last_fetch_pc = 0;
	uint64_t fetch_start_ticks = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;
	uint64_t m68k_instrs = 0;

	bool ym_we_prev_dbg = false;
	uint32_t ym_we_count = 0;
	bool oki0_we_prev_dbg = false, oki1_we_prev_dbg = false;
	uint32_t oki0_we_count = 0, oki1_we_count = 0;
	bool log_snd = std::getenv("TB_LOG_SND") != nullptr;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		// Only count cen pulses while the Z80 is actually out of reset —
		// macross2_sound_reset_w can hold/release it repeatedly through a
		// real run ("every time music changes Z80 is reset" per the
		// reference's own PCB-verified comment), and z80_div itself
		// free-runs regardless of reset state, so an un-gated count would
		// include phantom ticks accumulated during every reset-held
		// interval, inflating apparent inter-instruction cycle cost by a
		// different, non-constant amount depending on real 68000 timing.
		bool z80_cen_now = top.dbg_z80_cen && top.dbg_z80_reset_n;
		if (z80_cen_now && !prev_z80_cen) z80_cen_ticks++;
		prev_z80_cen = z80_cen_now;

		// Z80 instruction-fetch PC (M1_n falling edge = fetch cycle start,
		// address bus is the fetch PC at that point). Only counted while
		// the Z80 is out of reset (macross2_sound_reset_w can hold it in
		// reset indefinitely — see macross2_core.sv's own header).
		bool m1_n_now = top.dbg_z80_m1_n;
		if (top.dbg_z80_reset_n && prev_m1_n && !m1_n_now) {
			uint16_t pc = top.dbg_z80_pc;
			last_z80_pc = pc;
			z80_instrs++;
			std::fprintf(z80_trace, "%04X\n", pc);
			std::fprintf(z80_cyc_trace, "%llu %04X\n", (unsigned long long)z80_cen_ticks, pc);
			if (log_z80)
				std::fprintf(stderr, "cycle=%llu z80 fetch PC=%04X\n", (unsigned long long)z80_cen_ticks, pc);
		}
		prev_m1_n = m1_n_now;

		bool ym_we_now = top.dbg_ym_we;
		if (ym_we_now && !ym_we_prev_dbg) {
			ym_we_count++;
			if (log_snd)
				std::fprintf(stderr, "cycle=%llu ym_we cs=%d dout=%02X irq_n=%d\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_ym_cs, top.dbg_ym_chip_dout, top.dbg_ym_irq_n);
		}
		ym_we_prev_dbg = ym_we_now;

		bool oki0_we_now = top.dbg_oki0_we;
		if (oki0_we_now && !oki0_we_prev_dbg) {
			oki0_we_count++;
			if (log_snd)
				std::fprintf(stderr, "cycle=%llu oki0_we dout=%02X\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_oki0_chip_dout);
		}
		oki0_we_prev_dbg = oki0_we_now;

		bool oki1_we_now = top.dbg_oki1_we;
		if (oki1_we_now && !oki1_we_prev_dbg) {
			oki1_we_count++;
			if (log_snd)
				std::fprintf(stderr, "cycle=%llu oki1_we dout=%02X\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_oki1_chip_dout);
		}
		oki1_we_prev_dbg = oki1_we_now;

		// 68000 side
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

		// Video frame checksum
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
				std::snprintf(fname, sizeof(fname), "macross2_frame_%02u.ppm", frame_count);
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

	std::fclose(z80_trace);
	std::fclose(z80_cyc_trace);
	std::fclose(m68k_trace);
	std::fclose(m68k_cyc_trace);

	std::printf("tb_macross2: ran %llu clk_sys cycles (~%llu 68000 bus cycles)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4));
	std::printf("tb_macross2: Z80 executed %llu instructions, last fetch PC=$%04X\n",
	            (unsigned long long)z80_instrs, last_z80_pc);
	std::printf("tb_macross2: 68000 executed %llu instructions, completed %u write bus cycles, last fetch PC=$%06X\n",
	            (unsigned long long)m68k_instrs, m68k_writes, last_fetch_pc);
	std::printf("tb_macross2: Z80 wrote to YM2203 %u times, OKI0 %u times, OKI1 %u times\n",
	            ym_we_count, oki0_we_count, oki1_we_count);
	std::printf("tb_macross2: rendered %u video frame(s), wrote macross2_video.trace\n", frame_count);

	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 32768; i++) { top.dbg_bgvram_addr = i; top.eval(); if (top.dbg_bgvram_data != 0xFFFF) nonzero_bg++; }
		for (int i = 0; i < 2048; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_macross2: non-blank palette=%d/1024 bgvram=%d/32768 txvram=%d/2048\n",
		             nonzero_pal, nonzero_bg, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_macross2: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
