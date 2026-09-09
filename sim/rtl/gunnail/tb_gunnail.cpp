// Testbench for rtl/gunnail/gunnail_core.sv — the third Family D
// (TLCS-90 protection MCU) game, macross's own sibling (byte-identical
// protection ROM, same NMK-215/TMP90840/dual-NMK214 mechanism). Built
// directly on tb_macross.cpp's own pattern — same clk_sys architecture
// (40MHz, /4=10MHz 68000, /5=8MHz NMK004/pixel, /10=4MHz protcpu).
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vgunnail_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static uint64_t RUN_CYCLES = 300000000; // override via argv[1]
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);
	if (argc > 1) RUN_CYCLES = strtoull(argv[1], nullptr, 0);

	Vgunnail_core top{&contextp};
	FILE *nmk004_trace = std::fopen("nmk004_sys.trace", "w");
	FILE *nmk004_cyc_trace = std::fopen("nmk004_cyc.trace", "w");
	FILE *prot_trace = std::fopen("prot_sys.trace", "w");
	FILE *prot_cyc_trace = std::fopen("prot_cyc.trace", "w");
	FILE *prot_reg_trace = std::getenv("TB_LOG_PROT_REGS") != nullptr ? std::fopen("prot_regs.trace", "w") : nullptr;
	NmkTraceWriter trace("gunnail_video.trace", "gunnail", 10000000, "", "program", 0, 0xffffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	uint32_t frame_count = 0;
	bool     prev_frame_done = false;
	uint64_t nmk004_instrs = 0;
	uint64_t last_pc = 0;
	bool     prev_dbg_valid = false;

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
	FILE *m68k_trace = std::fopen("gunnail_68k.trace", "w");
	FILE *m68k_cyc_trace = std::fopen("m68k_cyc.trace", "w");
	uint64_t m68k_instrs = 0;

	bool ym_we_prev_dbg = false;
	uint32_t ym_we_count = 0;
	bool log_ym = std::getenv("TB_LOG_YM") != nullptr;

	bool oki0_we_prev_dbg = false, oki1_we_prev_dbg = false;
	uint32_t oki0_we_count = 0, oki1_we_count = 0;
	bool log_oki = std::getenv("TB_LOG_OKI") != nullptr;

	// TB_DUMP_AUDIO=<path>: raw signed 16-bit mono at 48kHz. TB_LOG_HOST:
	// print every 68000->NMK004 command and NMK004->68000 reply (the boot
	// handshake), with the frame number, for comparison with a MAME Lua tap.
	FILE *audio_f = std::getenv("TB_DUMP_AUDIO") ? std::fopen(std::getenv("TB_DUMP_AUDIO"), "wb") : nullptr;
	uint64_t audio_phase = 0;
	bool log_host = std::getenv("TB_LOG_HOST") != nullptr;
	bool prev_cmd_we = false, prev_reply_we = false;
	int  last_reply = -1;
	uint32_t host_cmds = 0, host_replies = 0;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;

		if (audio_f) {
			audio_phase += 48000;
			if (audio_phase >= 40000000ULL) {
				audio_phase -= 40000000ULL;
				int16_t s = (int16_t)top.audio_l;
				fwrite(&s, 2, 1, audio_f);
			}
		}
		{
			bool cw = top.dbg_host_cmd_we, rw = top.dbg_mcu_reply_we;
			if (cw && !prev_cmd_we) { host_cmds++; if (log_host) std::fprintf(stderr, "F%03u 68K W cmd %02x\n", frame_count, (unsigned)top.dbg_host_cmd); }
			if (rw && !prev_reply_we && (int)top.dbg_mcu_reply != last_reply) { host_replies++; last_reply = top.dbg_mcu_reply; if (log_host) std::fprintf(stderr, "F%03u MCU reply %02x\n", frame_count, (unsigned)top.dbg_mcu_reply); }
			prev_cmd_we = cw; prev_reply_we = rw;
		}

		bool dbg_valid_now = top.dbg_nmk004_valid;
		if (dbg_valid_now && !prev_dbg_valid) {
			uint16_t pc = top.dbg_nmk004_pc;
			std::fprintf(nmk004_trace, "%04X\n", pc);
			std::fprintf(nmk004_cyc_trace, "%llu %04X\n", (unsigned long long)(clk_sys_ticks / 5), pc);
			nmk004_instrs++;
			last_pc = pc;
		}
		prev_dbg_valid = dbg_valid_now;

		bool prot_dbg_valid_now = top.dbg_prot_valid;
		if (prot_dbg_valid_now && !prot_prev_dbg_valid) {
			uint16_t pc = top.dbg_prot_pc;
			std::fprintf(prot_trace, "%04X\n", pc);
			std::fprintf(prot_cyc_trace, "%llu %04X\n", (unsigned long long)(clk_sys_ticks / 10), pc);
			if (prot_reg_trace)
				std::fprintf(prot_reg_trace, "%llu %04X HL=%04X VCOUNT=%u RAMHL=%02X\n", (unsigned long long)(clk_sys_ticks / 10), pc, (unsigned)top.dbg_prot_hl, (unsigned)top.dbg_vt_vcount, (unsigned)top.dbg_prot_int_ram_at_hl);
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
		// edge), matching MAME's own totalcycles sample point. The
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
			uint64_t cpu_cycle = clk_sys_ticks / 4;
			trace.frame(cpu_cycle, frame_count, frame_crc);

			static const unsigned ppm_from = std::getenv("TB_PPM_FROM") ? (unsigned)strtoul(std::getenv("TB_PPM_FROM"), nullptr, 0) : 0; // TB_PPM_FROM=N: only dump frames >= N
			if (std::getenv("TB_DUMP_PPM") != nullptr && frame_count >= ppm_from) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "gunnail_frame_%02u.ppm", frame_count);
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
	std::fclose(prot_trace);
	std::fclose(prot_cyc_trace);
	if (prot_reg_trace) std::fclose(prot_reg_trace);
	std::fclose(m68k_trace);
	std::fclose(m68k_cyc_trace);
	if (audio_f) std::fclose(audio_f);
	std::printf("tb_gunnail: host latch: %u commands, %u distinct replies\n", host_cmds, host_replies);
	std::printf("tb_gunnail: ran %llu clk_sys cycles (~%llu 68000 bus cycles), NMK004 executed %llu instructions (last PC=$%04X)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4), (unsigned long long)nmk004_instrs, (unsigned)last_pc);
	std::printf("tb_gunnail: protection MCU executed %llu instructions (last PC=$%04X), 68000 HALT asserted %llu times\n",
	            (unsigned long long)prot_instrs, (unsigned)prot_last_pc, (unsigned long long)halt_asserts);
	std::printf("tb_gunnail: 68000 last instruction-fetch PC=$%06X, completed %u write bus cycles total\n",
	            last_fetch_pc, m68k_writes);
	std::printf("tb_gunnail: NMK004 wrote to YM2203 %u times\n", ym_we_count);
	std::printf("tb_gunnail: NMK004 wrote to OKI1/OKI2 %u/%u times\n", oki0_we_count, oki1_we_count);
	std::printf("tb_gunnail: rendered %u video frame(s), wrote gunnail_video.trace\n", frame_count);
	std::printf("tb_gunnail: 68000 executed %llu instructions, wrote gunnail_68k.trace\n", (unsigned long long)m68k_instrs);

	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 8192; i++) { top.dbg_bgvram_addr = i; top.eval(); if (top.dbg_bgvram_data != 0xFFFF) nonzero_bg++; }
		for (int i = 0; i < 2048; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_gunnail: non-blank palette=%d/1024 bgvram=%d/8192 txvram=%d/2048\n",
		             nonzero_pal, nonzero_bg, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_gunnail: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
