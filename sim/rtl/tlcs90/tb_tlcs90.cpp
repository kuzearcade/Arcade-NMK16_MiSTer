// Testbench for rtl/tlcs90/tlcs90.sv — runs the real NMK004 boot ROM
// (nmk004.bin) chained into mustang's external program (90058-7) and logs
// every instruction boundary's PC, for direct comparison against a MAME
// oracle trace captured via the debugger `trace` command
// (`trace file,:nmk004:mcu`, see docs/tier2-tlcs90.md "Verification plan").
//
// Memory model lives here rather than in Verilog, since the CPU module's
// bus is a plain external din/dout/addr/mem_rd/mem_wr interface (see that
// module's header for the protocol: reads are combinational — addr valid
// for one full cycle, din must already reflect mem[addr] by the next
// posedge). This smoke test treats the whole 0xf000-0xffff region as
// generic RAM (real work RAM, internal CPU RAM, and every peripheral
// register are NOT distinguished) — adequate for a first PC-trace
// comparison against a write-heavy boot sequence, not yet a real
// peripheral model.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 500000;

static uint8_t boot_rom[0x2000];
static uint8_t ext_rom[0x10000];
static uint8_t ram[0x1000];

static uint8_t read_mem(uint16_t addr) {
	if (addr < 0x2000) return boot_rom[addr];
	if (addr < 0xf000) return ext_rom[addr];
	return ram[addr - 0xf000];
}
static void write_mem(uint16_t addr, uint8_t data) {
	if (addr >= 0xf000) ram[addr - 0xf000] = data;
}

static void load_hex(const char *path, uint8_t *dst, size_t n) {
	FILE *f = std::fopen(path, "r");
	if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(1); }
	for (size_t i = 0; i < n; i++) {
		unsigned v;
		if (std::fscanf(f, "%x", &v) != 1) { std::fprintf(stderr, "%s: short read at %zu\n", path, i); std::exit(1); }
		dst[i] = (uint8_t)v;
	}
	std::fclose(f);
}

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	load_hex("roms/nmk004_boot.hex", boot_rom, sizeof(boot_rom));
	load_hex("roms/mustang_ext.hex", ext_rom, sizeof(ext_rom));

	Vtlcs90 top{&contextp};
	FILE *out = std::fopen("tlcs90_rtl.trace", "w");

	top.cen = 1;   // tlcs90.sv gained a clock-enable input (raphero's 14 MHz path); the raw-module testbenches must tie it high or the core never steps
	top.reset = 1;
	top.nmi = 0;
	top.irq_req = 0;
	top.irq_mask = 0;
	top.ix_bank = 0;
	top.iy_bank = 0;
	top.din = 0;

	auto tick = [&]() {
		top.din = read_mem(top.addr);
		top.eval();
		top.clk = 1;
		top.eval();
		if (top.mem_wr) write_mem(top.addr, top.dout);
		if (top.dbg_valid) std::fprintf(out, "%04X\n", top.dbg_pc);
		top.clk = 0;
		top.eval();
	};

	for (int i = 0; i < 8; i++) tick();
	top.reset = 0;

	uint64_t n_instr = 0;
	for (uint64_t i = 0; i < RUN_CYCLES; i++) {
		tick();
		if (top.dbg_valid) n_instr++;
	}

	std::fclose(out);
	std::printf("tb_tlcs90: ran %llu clk cycles, logged instruction boundaries, wrote tlcs90_rtl.trace\n",
	            (unsigned long long)RUN_CYCLES);
	return 0;
}
