// Testbench for rtl/tdragonb/tdragonb_core.sv — Tier 5's second
// system-level integration milestone (see that module's header for full
// scope/simplifications). Runs the real, offline-decrypted 68000 program
// ROM alongside the real Z80 (T80, via rtl/third_party_gen/t80/T80s.v)
// running tdragonb's own Seibu-sound program (byte-identical to
// mustangb's own), and checks whether the RST18/RST10 IM0
// interrupt-vector arbitration in rtl/seibu/seibu_sound.sv still
// resolves correctly at a different (10MHz, not 8MHz) main-CPU clock.
//
// PC tracking: same techniques as tb_mustangb.cpp (Z80: M1_n falling
// edge + address bus; 68000: ASn falling/rising edge). The only real
// difference from tb_mustangb.cpp: the 68000's own clock-equivalent
// tick count can't be derived via a fixed clk_sys_ticks/4 division
// (tdragonb's own ratio is 5/16, not a clean /4) — dbg_cpu_cen (enPhi1)
// pulses are edge-detected and counted instead, mirroring how z80_cen
// ticks are already counted.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vtdragonb_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 60000000; // clk_sys (32MHz) cycles
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vtdragonb_core top{&contextp};

	FILE *z80_trace = std::fopen("tdragonb_z80.trace", "w");
	FILE *z80_cyc_trace = std::fopen("z80_cyc.trace", "w");
	FILE *m68k_trace = std::fopen("tdragonb_68k.trace", "w");
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");
	NmkTraceWriter trace("tdragonb_video.trace", "tdragonb", 10000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;

	// Z80 side (identical technique to tb_mustangb.cpp).
	bool     prev_m1_n = true;
	uint64_t z80_instrs = 0;
	uint16_t last_z80_pc = 0;
	uint64_t z80_cen_ticks = 0;
	bool     prev_z80_cen = false;
	bool     log_z80 = std::getenv("TB_LOG_Z80") != nullptr;

	// IRQ/vector tracking
	bool     prev_iack = false;
	uint64_t iack_count = 0, iack_rst10_count = 0, iack_rst18_count = 0, iack_spurious_count = 0;
	bool     log_irq = std::getenv("TB_LOG_IRQ") != nullptr;

	// 68000 side. cpu_cen_ticks counts dbg_cpu_cen (enPhi1) pulses — the
	// real 10MHz-equivalent tick count, since this port's ratio (5/16)
	// isn't a clean clk_sys/N division like every prior port's own /4.
	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0;
	uint32_t last_fetch_pc = 0;
	uint64_t fetch_start_cen_ticks = 0;
	uint32_t m68k_writes = 0;
	bool log_m68k = std::getenv("TB_LOG_M68K") != nullptr;
	uint64_t m68k_instrs = 0;
	uint64_t cpu_cen_ticks = 0;
	bool     prev_cpu_cen = false;

	bool ym_we_prev_dbg = false;
	uint32_t ym_we_count = 0;
	bool oki_we_prev_dbg = false;
	uint32_t oki_we_count = 0;
	bool log_snd = std::getenv("TB_LOG_SND") != nullptr;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		bool z80_cen_now = top.dbg_z80_cen;
		if (z80_cen_now && !prev_z80_cen) z80_cen_ticks++;
		prev_z80_cen = z80_cen_now;

		bool cpu_cen_now = top.dbg_cpu_cen;
		if (cpu_cen_now && !prev_cpu_cen) cpu_cen_ticks++;
		prev_cpu_cen = cpu_cen_now;

		// Z80 instruction-fetch PC (M1_n falling edge = fetch cycle start,
		// address bus is the fetch PC at that point).
		bool m1_n_now = top.dbg_z80_m1_n;
		if (prev_m1_n && !m1_n_now) {
			uint16_t pc = top.dbg_z80_pc;
			last_z80_pc = pc;
			z80_instrs++;
			std::fprintf(z80_trace, "%04X\n", pc);
			std::fprintf(z80_cyc_trace, "%llu %04X\n", (unsigned long long)z80_cen_ticks, pc);
			if (log_z80)
				std::fprintf(stderr, "cycle=%llu z80 fetch PC=%04X\n", (unsigned long long)z80_cen_ticks, pc);
		}
		prev_m1_n = m1_n_now;

		bool iack_now = top.dbg_z80_iack_active;
		if (iack_now && !prev_iack) {
			iack_count++;
			uint8_t vec = top.dbg_z80_iack_vector;
			if (vec == 0xD7) iack_rst10_count++;
			else if (vec == 0xDF) iack_rst18_count++;
			else iack_spurious_count++;
			if (log_irq)
				std::fprintf(stderr, "cycle=%llu z80 IACK vector=%02X\n", (unsigned long long)clk_sys_ticks, vec);
		}
		prev_iack = iack_now;

		bool ym_we_now = top.dbg_ym_we;
		if (ym_we_now && !ym_we_prev_dbg) {
			ym_we_count++;
			if (log_snd)
				std::fprintf(stderr, "cycle=%llu ym_we cs=%d dout=%02X irq_n=%d\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_ym_cs, top.dbg_ym_chip_dout, top.dbg_ym_irq_n);
		}
		ym_we_prev_dbg = ym_we_now;

		bool oki_we_now = top.dbg_oki_we;
		if (oki_we_now && !oki_we_prev_dbg) {
			oki_we_count++;
			if (log_snd)
				std::fprintf(stderr, "cycle=%llu oki_we cs=%d dout=%02X\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_oki_cs, top.dbg_oki_chip_dout);
		}
		oki_we_prev_dbg = oki_we_now;

		// 68000 side
		if (prev_as_n && !top.dbg_as_n) fetch_start_cen_ticks = cpu_cen_ticks;
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
				std::fprintf(m68k_cyc_trace, "%llu %06X\n", (unsigned long long)fetch_start_cen_ticks, last_fetch_pc);
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
			trace.frame(cpu_cen_ticks, frame_count, frame_crc);

			if (std::getenv("TB_DUMP_PPM") != nullptr) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "tdragonb_frame_%02u.ppm", frame_count);
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

	std::printf("tb_tdragonb: ran %llu clk_sys cycles (~%llu 68000 clock-enable ticks)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)cpu_cen_ticks);
	std::printf("tb_tdragonb: Z80 executed %llu instructions, last fetch PC=$%04X\n",
	            (unsigned long long)z80_instrs, last_z80_pc);
	std::printf("tb_tdragonb: 68000 executed %llu instructions, completed %u write bus cycles, last fetch PC=$%06X\n",
	            (unsigned long long)m68k_instrs, m68k_writes, last_fetch_pc);
	std::printf("tb_tdragonb: Z80 IM0 interrupt-acknowledge cycles: %llu total (RST10/YM3812=%llu, RST18/main=%llu, spurious=%llu)\n",
	            (unsigned long long)iack_count, (unsigned long long)iack_rst10_count,
	            (unsigned long long)iack_rst18_count, (unsigned long long)iack_spurious_count);
	std::printf("tb_tdragonb: Z80 wrote to YM3812 %u times, OKI %u times\n", ym_we_count, oki_we_count);
	std::printf("tb_tdragonb: rendered %u video frame(s), wrote tdragonb_video.trace\n", frame_count);

	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 8192; i++) { top.dbg_bgvram_addr = i; top.eval(); if (top.dbg_bgvram_data != 0xFFFF) nonzero_bg++; }
		for (int i = 0; i < 1024; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_tdragonb: non-blank palette=%d/1024 bgvram=%d/8192 txvram=%d/1024\n",
		             nonzero_pal, nonzero_bg, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_tdragonb: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
