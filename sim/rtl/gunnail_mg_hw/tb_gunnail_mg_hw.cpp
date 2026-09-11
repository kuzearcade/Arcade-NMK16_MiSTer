// Hardware-mode verification for gunnail_core (HW_ROMS=1) — see
// docs/hw-bringup.md and sim/rtl/tdragon2_hw/tb_tdragon2_hw.cpp (same
// structure: real ioctl_download of the zip content into a simulated
// SDRAM, then CPU-progress, sound-write and rendered-pixel checks, with
// pixels sampled continuously from the live raster like a capture
// device). Frames land in gunnail_hw_frame_NN.ppm with TB_DUMP_PPM=1;
// TB_DUMP_AUDIO=<path> writes 48kHz s16 mono.
#include <cstdint>
#include <cstdio>
#include <string>
#include <cstdlib>
#include <vector>
#include <set>

#include "Vgunnail_mg_hw_top.h"
#include "verilated.h"

static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

static uint64_t g_run_cycles = 300000000;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);
	if (argc > 1) g_run_cycles = strtoull(argv[1], nullptr, 0);
	Vgunnail_mg_hw_top top{&contextp};

	// clk_ram at TB_RAM_PER2 cycles per two clk_sys cycles (default 6 =
	// 120MHz-equivalent; 5 = 100MHz, closest to the real 96MHz).
	const int ram_per2 = std::getenv("TB_RAM_PER2") ? std::atoi(std::getenv("TB_RAM_PER2")) : 6;
	int tick_phase = 0;
	auto tick = [&]() {
		const int n = (tick_phase++ & 1) ? (ram_per2 - ram_per2 / 2) : (ram_per2 / 2);
		top.clk_sys = 0; top.eval();
		for (int k = 0; k < n; k++) {
			top.clk_ram = 1; top.eval();
			top.clk_ram = 0; top.eval();
			if (k == n / 2) { top.clk_sys = 1; top.eval(); }
		}
	};

	top.reset = 1;
	top.ioctl_download = 0;
	top.ioctl_wr = 0;
	for (int i = 0; i < 20; i++) tick();

	uint64_t waited = 0;
	while (!top.sdram_ready && waited < 500000) { tick(); waited++; }
	if (!top.sdram_ready) { printf("FAIL: sdram never became ready\n"); return 1; }
	printf("sdram ready after %llu cycles\n", (unsigned long long)waited);

	const std::string prefix = std::getenv("TB_PREFIX") ? std::getenv("TB_PREFIX") : "gunnail";
	FILE *m68k_trace = fopen((prefix + "_hw_68k.trace").c_str(), "w");

	const std::string ioctl_path = "roms/" + prefix + "_ioctl.bin";
	FILE *f = fopen(ioctl_path.c_str(), "rb");
	if (!f) { printf("FAIL: could not open %s\n", ioctl_path.c_str()); return 1; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> rom(len);
	if (fread(rom.data(), 1, len, f) != (size_t)len) { printf("FAIL: short read\n"); return 1; }
	fclose(f);
	printf("loaded %ld bytes of ROM image for download\n", len);

	top.ioctl_download = 1;
	uint64_t download_ticks = 0;
	for (long i = 0; i < len; i++) {
		top.ioctl_addr = i;
		top.ioctl_dout = rom[i];
		top.ioctl_wr = 1;
		tick(); download_ticks++;
		top.ioctl_wr = 0;
		tick(); download_ticks++;
		while (top.ioctl_wait) { tick(); download_ticks++; }
	}
	top.ioctl_download = 0;
	printf("download used %llu clk_sys ticks total (%.2f ticks/byte avg)\n",
	       (unsigned long long)download_ticks, (double)download_ticks / len);
	for (int i = 0; i < 20; i++) tick();
	printf("ioctl download complete: %ld bytes written\n", len);

	top.reset = 0;

	uint64_t clk_sys_ticks = 0;
	bool log_host = std::getenv("TB_LOG_HOST") != nullptr;
	bool prev_cmd_we = false, prev_reply_we = false;
	int last_reply = -1;
	uint32_t host_cmds = 0, host_replies = 0;
	bool prev_prot_valid = false;
	long prot_instrs = 0;
	uint16_t prot_last_pc = 0;
	bool prev_prot_bus = false;
	long prot_bus_accesses = 0;
	bool prev_cfg_we = false;
	uint32_t cfg_writes = 0;
	bool prev_snd_valid = false;
	long snd_instrs = 0;
	uint16_t snd_last_pc = 0;

	bool prev_as_n = true;
	long m68k_instrs = 0;
	uint32_t m68k_last_pc = 0;

	long ym_writes = 0, oki0_writes = 0, oki1_writes = 0;
	bool prev_ym_we = false, prev_oki0_we = false, prev_oki1_we = false;

	std::set<uint32_t> recent_pcs;
	uint64_t last_quarter_start = g_run_cycles - g_run_cycles / 4;

	uint32_t frame_count = 0;
	bool prev_frame_done = false;
	long last_frame_nonzero_px = -1;
	bool dump_ppm = std::getenv("TB_DUMP_PPM") != nullptr;

	static uint32_t framebuf[SCREEN_H][SCREEN_W];

	FILE *audio_f = std::getenv("TB_DUMP_AUDIO") ? fopen(std::getenv("TB_DUMP_AUDIO"), "wb") : nullptr;
	uint64_t audio_phase = 0;

	for (; clk_sys_ticks < g_run_cycles; clk_sys_ticks++) {
		tick();

		if (audio_f) {
			audio_phase += 48000;
			if (audio_phase >= 40000000ULL) {
				audio_phase -= 40000000ULL;
				int16_t s = (int16_t)top.audio_l;
				fwrite(&s, 2, 1, audio_f);
			}
		}

		if (top.ce_pix_o && !top.hblank_o && !top.vblank_o) {
			int x = (int)top.hcount_o - (top.lowres_o ? 92 : 28);
			int y = (int)top.vcount_o - 16;
			if (x >= 0 && x < SCREEN_W && y >= 0 && y < SCREEN_H) framebuf[y][x] = top.rd_rgb;
		}

		bool frame_done_now = top.frame_done;
		if (!prev_frame_done && frame_done_now) {
			long nonzero_px = 0;
			FILE *ppm = nullptr;
			if (dump_ppm) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "%s_hw_frame_%03u.ppm", prefix.c_str(), frame_count);
				ppm = std::fopen(fname, "wb");
				std::fprintf(ppm, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
			}
			for (int y = 0; y < SCREEN_H; y++) {
				for (int x = 0; x < SCREEN_W; x++) {
					uint32_t rgb = framebuf[y][x];
					if (rgb != 0) nonzero_px++;
					if (ppm) {
						uint8_t rgb_bytes[3] = {
							(uint8_t)((rgb >> 16) & 0xFF),
							(uint8_t)((rgb >> 8) & 0xFF),
							(uint8_t)(rgb & 0xFF)
						};
						std::fwrite(rgb_bytes, 1, 3, ppm);
					}
				}
			}
			if (ppm) std::fclose(ppm);
			last_frame_nonzero_px = nonzero_px;
			if (frame_count < 5 || frame_count % 50 == 0)
				printf("tb_mg_hw: frame %u: %ld/%d nonzero pixels\n", frame_count, nonzero_px, SCREEN_W * SCREEN_H);
			frame_count++;
		}
		prev_frame_done = frame_done_now;

		{
			bool cw = top.dbg_host_cmd_we, rw = top.dbg_mcu_reply_we;
			if (cw && !prev_cmd_we) { host_cmds++; if (log_host) fprintf(stderr, "F%03u 68K W cmd %02x\n", frame_count, (unsigned)top.dbg_host_cmd); }
			if (rw && !prev_reply_we && (int)top.dbg_mcu_reply != last_reply) { host_replies++; last_reply = top.dbg_mcu_reply; if (log_host) fprintf(stderr, "F%03u MCU reply %02x\n", frame_count, (unsigned)top.dbg_mcu_reply); }
			prev_cmd_we = cw; prev_reply_we = rw;
			bool pv = top.dbg_prot_valid;
			static FILE *prot_tf = std::getenv("TB_PROT_TRACE") ? fopen(std::getenv("TB_PROT_TRACE"), "w") : nullptr;
			if (pv && !prev_prot_valid) { prot_instrs++; prot_last_pc = top.dbg_prot_pc; if (prot_tf) fprintf(prot_tf, "%04X\n", (unsigned)prot_last_pc); }
			prev_prot_valid = pv;
			bool pb = top.dbg_prot_bus_rd || top.dbg_prot_bus_wr;
			static bool log_pb = std::getenv("TB_LOG_PROTBUS") != nullptr;
			if (pb && !prev_prot_bus) { prot_bus_accesses++; if (log_pb || (log_host && prot_bus_accesses <= 40)) fprintf(stderr, "F%03u c=%llu PROT %s %05x\n", frame_count, (unsigned long long)clk_sys_ticks, top.dbg_prot_bus_wr ? "W" : "R", (unsigned)top.dbg_prot_addr); }
			prev_prot_bus = pb;
			bool cf = top.dbg_nmk214_cfg_we;
			if (cf && !prev_cfg_we) { cfg_writes++; if (log_host) fprintf(stderr, "F%03u NMK214 cfg %02x\n", frame_count, (unsigned)top.dbg_nmk214_cfg_data); }
			prev_cfg_we = cf;
		}
		bool snd_valid_now = top.dbg_nmk004_valid;
		if (snd_valid_now && !prev_snd_valid) {
			snd_instrs++;
			snd_last_pc = top.dbg_nmk004_pc;
		}
		prev_snd_valid = snd_valid_now;

		// TB_TRAP_PC=<hex>: ring-buffer the last 64 completed bus cycles
		// (addr, data at AS release, R/W, FC) and dump them when the CPU
		// fetches from that PC (an exception handler, say), then stop.
		static uint32_t trap_pc = std::getenv("TB_TRAP_PC") ? strtoul(std::getenv("TB_TRAP_PC"), nullptr, 16) : 0xFFFFFFFF;
		static uint32_t ring_addr[64], ring_data[64]; static uint8_t ring_w[64], ring_fc[64]; static uint64_t ring_t[64]; static int ring_n = 0;
		static uint32_t cur_addr = 0, cur_data = 0; static uint8_t cur_w = 0, cur_fc = 0;
		if (!top.dbg_as_n) { cur_addr = (uint32_t)top.dbg_eab << 1; cur_data = top.dbg_data; cur_w = top.dbg_write; cur_fc = (top.dbg_fc2 << 2) | (top.dbg_fc1 << 1) | top.dbg_fc0; }
		if (!prev_as_n && top.dbg_as_n) {
			int i = ring_n++ & 63; ring_addr[i] = cur_addr; ring_data[i] = cur_data; ring_w[i] = cur_w; ring_fc[i] = cur_fc; ring_t[i] = clk_sys_ticks;
		}
		bool as_n_now = top.dbg_as_n;
		if (prev_as_n && !as_n_now && top.dbg_fc1 && !top.dbg_fc0 && ((uint32_t)top.dbg_eab << 1) == trap_pc) {
			fprintf(stderr, "TRAP: fetch at %06X after %ld instructions; last bus cycles (tick addr data rw fc):\n", trap_pc, m68k_instrs);
			for (int k = 0; k < 64; k++) { int i = (ring_n + k) & 63; if (ring_n < 64 && i >= ring_n) continue;
				fprintf(stderr, "  %llu %06X %04X %c fc%d\n", (unsigned long long)ring_t[i], ring_addr[i], ring_data[i], ring_w[i] ? 'W' : 'R', ring_fc[i]); }
			break;
		}
		if (prev_as_n && !as_n_now && top.dbg_fc1 && !top.dbg_fc0) {
			m68k_instrs++;
			m68k_last_pc = (uint32_t)top.dbg_eab << 1;
			if (clk_sys_ticks >= last_quarter_start) recent_pcs.insert(m68k_last_pc);
			if (m68k_trace && m68k_instrs <= 2000000) fprintf(m68k_trace, "%06X\n", m68k_last_pc);
		}
		prev_as_n = as_n_now;

		bool ym_we_now = top.dbg_ym_we;
		if (ym_we_now && !prev_ym_we) ym_writes++;
		prev_ym_we = ym_we_now;

		bool oki0_we_now = top.dbg_oki0_we;
		if (oki0_we_now && !prev_oki0_we) oki0_writes++;
		prev_oki0_we = oki0_we_now;

		bool oki1_we_now = top.dbg_oki1_we;
		if (oki1_we_now && !prev_oki1_we) oki1_writes++;
		prev_oki1_we = oki1_we_now;
	}

	printf("tb_mg_hw: ran %llu clk_sys cycles\n", (unsigned long long)g_run_cycles);
	printf("tb_mg_hw: distinct 68000 fetch PCs in the final quarter of the run: %zu\n", recent_pcs.size());
	{
		int shown = 0;
		printf("  sample: ");
		for (auto pc : recent_pcs) { if (shown++ > 20) { printf("..."); break; } printf("$%06X ", pc); }
		printf("\n");
	}
	printf("tb_mg_hw: NMK004 executed %ld instructions, last fetch PC=$%04X\n", snd_instrs, snd_last_pc);
	printf("tb_mg_hw: NMK004 clock: %u pulses delivered, %u withheld for ROM fetches (%.3f%%)\n",
	       (unsigned)top.dbg_nmk004_cen_total, (unsigned)top.dbg_nmk004_stall_total,
	       top.dbg_nmk004_cen_total ? 100.0 * top.dbg_nmk004_stall_total / (top.dbg_nmk004_cen_total + top.dbg_nmk004_stall_total) : 0.0);
	printf("tb_mg_hw: 68000 executed %ld instructions, last fetch PC=$%06X\n", m68k_instrs, m68k_last_pc);
	printf("tb_mg_hw: protection MCU executed %ld instructions, last PC=$%04X, %ld shared-bus accesses, 68000 HALT=%d, NMK214 config writes %u\n",
	       prot_instrs, prot_last_pc, prot_bus_accesses, (int)top.dbg_halt_68k, cfg_writes);
	printf("tb_mg_hw: host latch: %u commands, %u distinct replies\n", host_cmds, host_replies);
	printf("tb_mg_hw: NMK004 wrote to YM2203 %ld times, OKI0 %ld times, OKI1 %ld times\n", ym_writes, oki0_writes, oki1_writes);
	printf("tb_mg_hw: OKI ADPCM fetch audit: oki0 %u of %u sample bytes unserved at latch, oki1 %u of %u\n",
	       (unsigned)top.dbg_oki0_adpcm_unserved, (unsigned)top.dbg_oki0_adpcm_total,
	       (unsigned)top.dbg_oki1_adpcm_unserved, (unsigned)top.dbg_oki1_adpcm_total);
	printf("tb_mg_hw: OKI cen stall audit: %u cen pulses, withheld by cache stall oki0 %u (%.4f%%), oki1 %u (%.4f%%)\n",
	       (unsigned)top.dbg_oki_cen_total,
	       (unsigned)top.dbg_oki0_stall_cen, top.dbg_oki_cen_total ? 100.0 * top.dbg_oki0_stall_cen / top.dbg_oki_cen_total : 0.0,
	       (unsigned)top.dbg_oki1_stall_cen, top.dbg_oki_cen_total ? 100.0 * top.dbg_oki1_stall_cen / top.dbg_oki_cen_total : 0.0);
	if (audio_f) fclose(audio_f);
	printf("tb_mg_hw: rendered %u video frame(s); last frame had %ld/%d nonzero pixels\n",
	       frame_count, last_frame_nonzero_px, SCREEN_W * SCREEN_H);
	if (m68k_trace) fclose(m68k_trace);
	top.final();

	return 0;
}
