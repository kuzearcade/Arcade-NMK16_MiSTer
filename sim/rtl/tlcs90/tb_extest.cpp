// Standalone verification for the TLCS-90 CPU core's memory-operand forms
// of EX (see docs/tier2-tlcs90.md), independent of
// nmk004_periph.sv/nmk004_core.sv. No currently-known NMK004 game's boot
// trace reaches these opcodes (same rationale as every other
// synthetic-only milestone this session), so this drives the CPU core
// directly against a synthetic program (assembled by gen_extest_rom.py —
// see that file for the full derivation) and a flat 64KB memory model.
//
// Two sub-tests, deliberately using two *different* addressing forms
// (register-indirect and direct-address) — this decode branch is shared
// with RLD/RRD, which tb_rldtest.cpp already proved needs exercising
// through more than one form to catch a bug specific to one prefix
// group's own address resolution:
//   1. EX (HL),DE
//   2. EX (0x2100),BC
// Both directions of the swap are checked independently for each: the
// register ends up holding the memory word's original value, AND the
// memory word ends up holding the register's original value.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 400;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_extest_rom.py for the derivation.
	static const uint8_t prog[] = {
		0x3A, 0x00, 0x20, 0x39, 0xCD, 0xAB, 0xE2, 0x51, 0xEB, 0x00, 0x90, 0x41, 0x38, 0xBC, 0x9A, 0xE3,
		0x00, 0x21, 0x50, 0xEB, 0x02, 0x90, 0x40, 0xC8, 0xFE,
	};
	std::memcpy(mem, prog, sizeof(prog));
	mem[0x2000] = 0x34; mem[0x2001] = 0x12; // EX (HL),DE's memory operand: 0x1234
	mem[0x2100] = 0x78; mem[0x2101] = 0x56; // EX (0x2100),BC's memory operand: 0x5678

	Vtlcs90 top{&contextp};
	top.cen = 1;   // tlcs90.sv gained a clock-enable input (raphero's 14 MHz path); the raw-module testbenches must tie it high or the core never steps
	top.reset = 1;
	top.nmi = 0;
	top.irq_req = 0;
	top.irq_mask = 0;
	top.ix_bank = 0;
	top.iy_bank = 0;
	top.din = 0;

	auto tick = [&]() {
		top.din = mem[top.addr];
		top.eval();
		top.clk = 1;
		top.eval();
		if (top.mem_wr) mem[top.addr] = top.dout;
		top.clk = 0;
		top.eval();
	};

	for (int i = 0; i < 8; i++) tick();
	top.reset = 0;
	for (uint64_t i = 0; i < RUN_CYCLES; i++) tick();

	auto rd16 = [&](uint16_t a) -> uint16_t { return mem[a] | (mem[a+1] << 8); };

	int fails = 0;
	auto check16 = [&](const char *what, uint16_t got, uint16_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%04X, expected 0x%04X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%04X\n", what, got);
	};

	check16("EX (HL),DE: DE after (was M[0x2000])",      rd16(0x9000), 0x1234);
	check16("EX (HL),DE: M[0x2000] after (was DE)",        rd16(0x2000), 0xABCD);
	check16("EX (0x2100),BC: BC after (was M[0x2100])",    rd16(0x9002), 0x5678);
	check16("EX (0x2100),BC: M[0x2100] after (was BC)",    rd16(0x2100), 0x9ABC);

	if (fails == 0) std::printf("tb_extest: PASS (all checks)\n");
	else            std::printf("tb_extest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
