// Hardware-mode verification for macross2_core (HW_ROMS=1) — see
// docs/hw-bringup.md. Loads the real ROM zip content through a
// simulated ioctl_download stream (sim/rtl/macross2_hw/roms/
// macross2_ioctl.bin, built by tools/mk_ioctl_stream.py) into a real
// rtl/sdram.sv + sim/models/sdram_model.sv, instead of $readmemh, then
// runs the same class of check sim/rtl/macross2/tb_macross2.cpp already
// does (instruction progression, YM/OKI write activity) — NOT a full
// oracle re-diff (cycle timing genuinely differs now, by design, with
// real SDRAM wait states), just confirmation that the real hardware
// ROM-loading/wait-state path produces a CPU that boots and runs
// real, varied instructions rather than getting stuck or crashing.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <set>

#include "Vmacross2_hw_top.h"
#include "verilated.h"

static uint64_t g_run_cycles = 300000000; // same clk_sys budget as the sim testbench, override via argv[1]

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);
	if (argc > 1) g_run_cycles = strtoull(argv[1], nullptr, 0);
	Vmacross2_hw_top top{&contextp};

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

	FILE *m68k_trace = fopen("macross2_hw_68k.trace", "w");

	FILE *f = fopen("roms/macross2_ioctl.bin", "rb");
	if (!f) { printf("FAIL: could not open roms/macross2_ioctl.bin\n"); return 1; }
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

	for (; clk_sys_ticks < g_run_cycles; clk_sys_ticks++) {
		tick();

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

	printf("tb_macross2_hw: ran %llu clk_sys cycles\n", (unsigned long long)g_run_cycles);
	printf("tb_macross2_hw: distinct 68000 fetch PCs in the final quarter of the run: %zu\n", recent_pcs.size());
	{
		int shown = 0;
		printf("  sample: ");
		for (auto pc : recent_pcs) { if (shown++ > 20) { printf("..."); break; } printf("$%06X ", pc); }
		printf("\n");
	}
	printf("tb_macross2_hw: Z80 executed %ld instructions, last fetch PC=$%04X\n", z80_instrs, z80_last_pc);
	printf("tb_macross2_hw: 68000 executed %ld instructions, last fetch PC=$%06X\n", m68k_instrs, m68k_last_pc);
	printf("tb_macross2_hw: Z80 wrote to YM2203 %ld times, OKI0 %ld times, OKI1 %ld times\n", ym_writes, oki0_writes, oki1_writes);
	printf("tb_macross2_hw: final dbg_z80_reset_n=%d dbg_z80_m1_n=%d dbg_z80_mreq_n=%d\n",
	       top.dbg_z80_reset_n, top.dbg_z80_m1_n, top.dbg_z80_mreq_n);
	if (m68k_trace) fclose(m68k_trace);

	return 0;
}
