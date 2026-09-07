// Hardware-mode verification for tdragon2_core (HW_ROMS=1) — see
// docs/hw-bringup.md. Loads the real ROM zip content through a
// simulated ioctl_download stream (sim/rtl/tdragon2_hw/roms/
// tdragon2_ioctl.bin, built by tools/mk_ioctl_stream.py) into a real
// rtl/sdram.sv + sim/models/sdram_model.sv, instead of $readmemh, then
// runs the same class of check sim/rtl/tdragon2/tb_tdragon2.cpp already
// does (instruction progression, YM/OKI write activity) — NOT a full
// oracle re-diff (cycle timing genuinely differs now, by design, with
// real SDRAM wait states), just confirmation that the real hardware
// ROM-loading/wait-state path produces a CPU that boots and runs
// real, varied instructions rather than getting stuck or crashing.
//
// Also checks actual RENDERED VIDEO CONTENT, unlike this testbench's own
// original shape — added after real hardware bring-up showed a solid
// black screen on both tdragon2 and macross2 despite this testbench's
// own CPU-instruction checks passing; that gap (never having actually
// sampled rd_rgb under HW_ROMS=1 at all) is exactly the kind of thing
// that class of check can't catch, so this closes it directly.
//
// Pixels are sampled CONTINUOUSLY during the main run loop, gated by
// ce_pix_o/hblank_o/vblank_o, from rd_rgb driven by tdragon2_hw_top.sv's
// own internally-computed rd_x/rd_y (tracking the core's live hcount_o/
// vcount_o raster counters, exactly as Macross2.sv's own real hardware
// top does) — NOT a post-frame sweep setting rd_x/rd_y directly (an
// earlier version of this testbench did that, matching the plain
// HW_ROMS=0 sim testbenches' own long-established technique, but that
// changes rd_x every 1-2 clk_sys cycles versus real hardware's own
// 5-cycles-per-pixel ce_pix pacing — a strictly harsher, faster
// address-change rate for video_macross2.sv's own HW_ROMS=1 real-time
// BG/TX tile-byte SDRAM fetch than real hardware ever produces, which
// would overstate any tile-fetch-staleness symptom rather than reproduce
// what real hardware actually shows).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <set>

#include "Vtdragon2_hw_top.h"
#include "verilated.h"

static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

static uint64_t g_run_cycles = 300000000; // same clk_sys budget as the sim testbench, override via argv[1]

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);
	if (argc > 1) g_run_cycles = strtoull(argv[1], nullptr, 0);
	Vtdragon2_hw_top top{&contextp};

	auto tick = [&]() {
		top.clk_sys = 0; top.eval();
		top.clk_sys = 1; top.eval();
	};

	top.reset = 1;
	top.ioctl_download = 0;
	top.ioctl_wr = 0;
	for (int i = 0; i < 20; i++) tick();

	// Wait for the SDRAM controller's own init sequence before downloading.
	uint64_t waited = 0;
	while (!top.sdram_ready && waited < 500000) { tick(); waited++; }
	if (!top.sdram_ready) { printf("FAIL: sdram never became ready\n"); return 1; }
	printf("sdram ready after %llu cycles\n", (unsigned long long)waited);

	FILE *m68k_trace = fopen("tdragon2_hw_68k.trace", "w");

	FILE *f = fopen("roms/tdragon2_ioctl.bin", "rb");
	if (!f) { printf("FAIL: could not open roms/tdragon2_ioctl.bin\n"); return 1; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> rom(len);
	if (fread(rom.data(), 1, len, f) != (size_t)len) { printf("FAIL: short read\n"); return 1; }
	fclose(f);
	printf("loaded %ld bytes of ROM image for download\n", len);

	// Real hps_io.sv already has this exact backpressure mechanism
	// (ioctl_wait) for exactly this reason: an SDRAM write takes several
	// clk_sys cycles, far more than one ioctl_wr pulse's own spacing —
	// without waiting for it, most byte writes are silently dropped
	// (sdram_req.sv correctly refuses a new request while the previous
	// one is still in flight). Pulse ioctl_wr for one cycle, tick once
	// more so `ioctl_wait` has had a chance to actually assert, then
	// wait for it to clear before moving to the next byte.
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
		if (i < 5) printf("byte %ld: ticks so far this byte batch, ioctl_wait now=%d\n", i, top.ioctl_wait);
	}
	top.ioctl_download = 0;
	printf("download used %llu clk_sys ticks total (%.2f ticks/byte avg)\n",
	       (unsigned long long)download_ticks, (double)download_ticks / len);
	for (int i = 0; i < 20; i++) tick();
	printf("ioctl download complete: %ld bytes written\n", len);

	// release reset, same as the sim testbench's own RESET_CYCLES gap
	top.reset = 0;

	uint64_t clk_sys_ticks = 0;
	bool prev_m1_n = true;
	long z80_instrs = 0;
	uint16_t z80_last_pc = 0;

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

	// Live framebuffer, continuously overwritten pixel-by-pixel as the
	// core's own real-time raster scan produces them (ce_pix_o-gated,
	// like a real capture device would sample the analog output) —
	// filled in over the course of each frame, then read out (nonzero
	// count + optional PPM) at that frame's own frame_done.
	static uint32_t framebuf[SCREEN_H][SCREEN_W];

	for (; clk_sys_ticks < g_run_cycles; clk_sys_ticks++) {
		tick();

		if (top.ce_pix_o && !top.hblank_o && !top.vblank_o) {
			int x = (int)top.hcount_o - 28;
			int y = (int)top.vcount_o - 16;
			if (x >= 0 && x < SCREEN_W && y >= 0 && y < SCREEN_H) framebuf[y][x] = top.rd_rgb;
		}

		bool frame_done_now = top.frame_done;
		if (!prev_frame_done && frame_done_now) {
			long nonzero_px = 0;
			FILE *ppm = nullptr;
			if (dump_ppm) {
				char fname[64];
				std::snprintf(fname, sizeof(fname), "tdragon2_hw_frame_%02u.ppm", frame_count);
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
				printf("tb_tdragon2_hw: frame %u: %ld/%d nonzero pixels\n", frame_count, nonzero_px, SCREEN_W * SCREEN_H);
			frame_count++;
		}
		prev_frame_done = frame_done_now;

		bool m1_n_now = top.dbg_z80_m1_n;
		if (top.dbg_z80_reset_n && prev_m1_n && !m1_n_now) {
			z80_instrs++;
			z80_last_pc = top.dbg_z80_pc;
		}
		prev_m1_n = m1_n_now;

		bool as_n_now = top.dbg_as_n;
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

	printf("tb_tdragon2_hw: ran %llu clk_sys cycles\n", (unsigned long long)g_run_cycles);
	printf("tb_tdragon2_hw: distinct 68000 fetch PCs in the final quarter of the run: %zu\n", recent_pcs.size());
	{
		int shown = 0;
		printf("  sample: ");
		for (auto pc : recent_pcs) { if (shown++ > 20) { printf("..."); break; } printf("$%06X ", pc); }
		printf("\n");
	}
	printf("tb_tdragon2_hw: Z80 executed %ld instructions, last fetch PC=$%04X\n", z80_instrs, z80_last_pc);
	printf("tb_tdragon2_hw: 68000 executed %ld instructions, last fetch PC=$%06X\n", m68k_instrs, m68k_last_pc);
	printf("tb_tdragon2_hw: Z80 wrote to YM2203 %ld times, OKI0 %ld times, OKI1 %ld times\n", ym_writes, oki0_writes, oki1_writes);
	printf("tb_tdragon2_hw: final dbg_z80_reset_n=%d dbg_z80_m1_n=%d dbg_z80_mreq_n=%d\n",
	       top.dbg_z80_reset_n, top.dbg_z80_m1_n, top.dbg_z80_mreq_n);
	printf("tb_tdragon2_hw: rendered %u video frame(s); last frame had %ld/%d nonzero pixels\n",
	       frame_count, last_frame_nonzero_px, SCREEN_W * SCREEN_H);
	if (m68k_trace) fclose(m68k_trace);

	return 0;
}
