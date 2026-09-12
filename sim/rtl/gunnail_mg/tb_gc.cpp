// Multi-game testbench for rtl/gunnail/gunnail_core.sv (2026-09-11): the
// gunnail testbench (sim/rtl/gunnail/tb_gunnail.cpp) with the game
// selected at run time — TB_GAME_SEL=<id> drives the core's game_sel,
// TB_PREFIX=<name> names the trace/PPM files. See the Makefile. Frames
// are dumped 384 px wide; the lowres games' picture is columns 0..255.
#include <cstdint>
#include <cstdio>
#include <string>
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
	const int game_sel = std::getenv("TB_GAME_SEL") ? atoi(std::getenv("TB_GAME_SEL")) : 0;
	const std::string prefix = std::getenv("TB_PREFIX") ? std::getenv("TB_PREFIX") : "gunnail";
	top.game_sel = game_sel;
	// TB_DSW1/TB_DSW2: the .mra <switches> bytes (0xFF = every switch off); the core is built with SIM_DSW=1
	top.dsw1_i = 0xFF00 | (std::getenv("TB_DSW1") ? strtoul(std::getenv("TB_DSW1"), nullptr, 16) : 0xFF);
	top.dsw2_i = 0xFF00 | (std::getenv("TB_DSW2") ? strtoul(std::getenv("TB_DSW2"), nullptr, 16) : 0xFF);
	if (game_sel == 3 || game_sel == 12 || game_sel == 20 || game_sel == 22 || (game_sel >= 23 && game_sel <= 44)) top.dsw1_i = (top.dsw2_i << 8) | (top.dsw1_i & 0xFF); // mustang/tharrier/afega/mustangb: one 16-bit port, SW1 in the high byte
	else if (game_sel == 45) top.dsw1_i = ((top.dsw1_i & 0xFF) << 8) | 0xFF; // acrobatmbl: SW1 in the high byte of the DSW1 word, DSW2 as acrobatm
	top.in0_i = 0xFFFF; top.in1_i = 0xFFFF;
	FILE *nmk004_trace = std::fopen("nmk004_sys.trace", "w");
	FILE *nmk004_cyc_trace = std::fopen("nmk004_cyc.trace", "w");
	FILE *prot_trace = std::fopen(std::getenv("TB_PROT_TRACE") ? std::getenv("TB_PROT_TRACE") : "prot_sys.trace", "w");
	FILE *prot_cyc_trace = std::fopen("prot_cyc.trace", "w");
	FILE *prot_reg_trace = std::getenv("TB_LOG_PROT_REGS") != nullptr ? std::fopen("prot_regs.trace", "w") : nullptr;
	// TB_NMK004_REGS=<path>: full NMK004 register-state trace, one line per
	// instruction boundary — "<clk_sys/5> <PC> A=<a> F=<f> BC=<bc> DE=<de>
	// HL=<hl> IX=<ix> IY=<iy> SP=<sp>", for register-level (not just PC)
	// divergence hunting against a matching MAME oracle capture — see
	// docs/hw-bringup.md's GunNail sequencer-divergence investigation.
	FILE *nmk004_reg_trace = std::getenv("TB_NMK004_REGS") ? std::fopen(std::getenv("TB_NMK004_REGS"), "w") : nullptr;
	NmkTraceWriter trace((prefix + "_video.trace").c_str(), prefix.c_str(), 10000000, "", "program", 0, 0xffffff, ":screen");
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
	FILE *m68k_trace = std::fopen((prefix + "_68k.trace").c_str(), "w");
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
	// TB_DUMP_SRC=<prefix>: the four sources before the mix, same rate/format
	// (<prefix>_fm.raw s16, _psg.raw s16 (0..765<<5), _oki0.raw/_oki1.raw s16 = 14-bit x4)
	FILE *src_f[4] = {nullptr, nullptr, nullptr, nullptr};
	if (std::getenv("TB_DUMP_SRC")) {
		const char *names[4] = {"_fm.raw", "_psg.raw", "_oki0.raw", "_oki1.raw"};
		for (int i = 0; i < 4; i++) { std::string n = std::string(std::getenv("TB_DUMP_SRC")) + names[i]; src_f[i] = std::fopen(n.c_str(), "wb"); }
	}
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
				if (src_f[0]) {
					int16_t v[4] = { (int16_t)top.dbg_fm_snd, (int16_t)(top.dbg_psg_snd << 5),
					                 (int16_t)((int16_t)(top.dbg_oki0_snd << 2)), (int16_t)((int16_t)(top.dbg_oki1_snd << 2)) };
					for (int i = 0; i < 4; i++) fwrite(&v[i], 2, 1, src_f[i]);
				}
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
			if (nmk004_reg_trace)
				std::fprintf(nmk004_reg_trace, "%llu %04X A=%02X F=%02X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X\n",
					(unsigned long long)(clk_sys_ticks / 5), pc,
					(unsigned)top.dbg_nmk004_a, (unsigned)top.dbg_nmk004_f, (unsigned)top.dbg_nmk004_bc,
					(unsigned)top.dbg_nmk004_de, (unsigned)top.dbg_nmk004_hl, (unsigned)top.dbg_nmk004_ix,
					(unsigned)top.dbg_nmk004_iy, (unsigned)top.dbg_nmk004_sp);
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

		{	// TB_LOG_PROTBUS: the first 200 protection-MCU shared-bus accesses, with the frame number
			static bool log_pb = std::getenv("TB_LOG_PROTBUS") != nullptr;
			static bool prev_pb = false; static int n_pb = 0;
			bool pb = top.dbg_prot_bus_rd || top.dbg_prot_bus_wr;
			if (pb && !prev_pb) { n_pb++; if (log_pb) std::fprintf(stderr, "F%03u c=%llu PROT %s %05x\n", frame_count, (unsigned long long)clk_sys_ticks, top.dbg_prot_bus_wr ? "W" : "R", (unsigned)top.dbg_prot_addr); }
			prev_pb = pb;
		}
		{	// NMK214 config writes (the NMK-215's port 3/7 strobe), under TB_LOG_HOST
			static bool prev_cw = false;
			bool cw = top.dbg_nmk214_cfg_we;
			if (cw && !prev_cw && log_host) std::fprintf(stderr, "F%03u NMK214 cfg %02x\n", frame_count, (unsigned)top.dbg_nmk214_cfg_data);
			prev_cw = cw;
		}
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
			// TB_YM_TRACE=<path>: every YM2203 write as "<clk_sys cycle> <a0> <data>"
			static FILE *ym_trace = std::getenv("TB_YM_TRACE") ? std::fopen(std::getenv("TB_YM_TRACE"), "w") : nullptr;
			if (ym_trace) std::fprintf(ym_trace, "%llu %d %02X\n", (unsigned long long)clk_sys_ticks, (int)top.dbg_ym_waddr, (unsigned)top.dbg_ym_wdata);
			if (log_ym)
				std::fprintf(stderr, "cycle=%llu ym_we cs=%d dout=%02X irq_n=%d\n",
				             (unsigned long long)clk_sys_ticks, top.dbg_ym_cs,
				             top.dbg_ym_chip_dout, top.dbg_ym_chip_irq_n);
		}
		ym_we_prev_dbg = ym_we_now;
		{	// YM2203 status/data reads by the NMK004: "R <cycle> <a0> <value>" in the same trace
			static bool rd_prev = false;
			bool rd_now = top.dbg_ym_cs && !ym_we_now;
			static FILE *ym_trace_r = std::getenv("TB_YM_TRACE") ? std::fopen((std::string(std::getenv("TB_YM_TRACE")) + ".reads").c_str(), "w") : nullptr;
			if (rd_now && !rd_prev && ym_trace_r)
				std::fprintf(ym_trace_r, "%llu %d %02X\n", (unsigned long long)clk_sys_ticks, (int)top.dbg_ym_waddr, (unsigned)top.dbg_ym_chip_dout);
			rd_prev = rd_now;
		}

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
				std::snprintf(fname, sizeof(fname), "%s_frame_%02u.ppm", prefix.c_str(), frame_count);
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
	if (nmk004_reg_trace) std::fclose(nmk004_reg_trace);
	std::fclose(m68k_trace);
	std::fclose(m68k_cyc_trace);
	if (audio_f) std::fclose(audio_f);
	std::printf("tb_gc: host latch: %u commands, %u distinct replies\n", host_cmds, host_replies);
	std::printf("tb_gc: ran %llu clk_sys cycles (~%llu 68000 bus cycles), NMK004 executed %llu instructions (last PC=$%04X)\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4), (unsigned long long)nmk004_instrs, (unsigned)last_pc);
	std::printf("tb_gc: protection MCU executed %llu instructions (last PC=$%04X), 68000 HALT asserted %llu times\n",
	            (unsigned long long)prot_instrs, (unsigned)prot_last_pc, (unsigned long long)halt_asserts);
	std::printf("tb_gc: 68000 last instruction-fetch PC=$%06X, completed %u write bus cycles total\n",
	            last_fetch_pc, m68k_writes);
	std::printf("tb_gc: NMK004 wrote to YM2203 %u times\n", ym_we_count);
	std::printf("tb_gc: NMK004 wrote to OKI1/OKI2 %u/%u times\n", oki0_we_count, oki1_we_count);
	std::printf("tb_gc: rendered %u video frame(s), wrote gunnail_video.trace\n", frame_count);
	std::printf("tb_gc: 68000 executed %llu instructions, wrote gunnail_68k.trace\n", (unsigned long long)m68k_instrs);

	if (std::getenv("TB_DUMP_STATE") != nullptr) { // palette + BG VRAM words at the end of the run, for MAME probes
		FILE *sf = std::fopen(std::getenv("TB_DUMP_STATE"), "w");
		std::fprintf(sf, "PAL");
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); std::fprintf(sf, " %04X", top.dbg_pal_data); }
		std::fprintf(sf, "\nBGVRAM");
		for (int i = 0; i < 8192; i++) { top.dbg_bgvram_addr = i; top.eval(); std::fprintf(sf, " %04X", top.dbg_bgvram_data); }
		std::fprintf(sf, "\n"); std::fclose(sf);
	}
	if (std::getenv("TB_DUMP_VRAM") != nullptr) {
		int nonzero_pal = 0, nonzero_bg = 0, nonzero_tx = 0;
		for (int i = 0; i < 1024; i++) { top.dbg_pal_addr = i; top.eval(); if (top.dbg_pal_data) nonzero_pal++; }
		for (int i = 0; i < 8192; i++) { top.dbg_bgvram_addr = i; top.eval(); if (top.dbg_bgvram_data != 0xFFFF) nonzero_bg++; }
		for (int i = 0; i < 2048; i++) { top.dbg_txvram_addr = i; top.eval(); if (top.dbg_txvram_data != 0x0020) nonzero_tx++; }
		std::fprintf(stderr, "tb_gc: non-blank palette=%d/1024 bgvram=%d/8192 txvram=%d/2048\n",
		             nonzero_pal, nonzero_bg, nonzero_tx);

		int nonzero_px = 0;
		for (int y = 0; y < SCREEN_H; y++) {
			for (int x = 0; x < SCREEN_W; x++) {
				top.rd_x = x; top.rd_y = y; top.eval();
				if (top.rd_rgb != 0) nonzero_px++;
			}
		}
		std::fprintf(stderr, "tb_gc: %d/%d rendered pixels nonzero\n", nonzero_px, SCREEN_W * SCREEN_H);
	}
	return 0;
}
