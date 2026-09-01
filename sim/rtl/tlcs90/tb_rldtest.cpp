// Standalone verification for the TLCS-90 CPU core's RLD/RRD (see
// docs/tier2-tlcs90.md), independent of nmk004_periph.sv/nmk004_core.sv.
// No currently-known NMK004 game's boot trace reaches these opcodes
// (same rationale as tb_banktest.cpp/tb_blocktest.cpp), so this drives
// the CPU core directly against a synthetic program (assembled by
// gen_rldtest_rom.py — see that file for the full derivation) and a flat
// 64KB memory model, checking the memory-side result directly and the
// register-side result (A, F — neither has any other observable path)
// via LD ($FF00+n),A and a PUSH AF/POP HL/LD (nn),HL trick.
//
// Two sub-tests, deliberately using two *different* addressing forms
// (RLD via the (gg) register-indirect group, RRD via the (mn) direct-
// address group) to prove the shared mem_mode decode wiring genuinely
// works for more than the one form that happened to be implemented
// first, not just coincidentally for a single case:
//   1. RLD (HL): A=0x3F, M[0x2000]=0xA5 -> A=0x3A, M[0x2000]=0x5F,
//      F=0x05 (PF set from even parity, CF=1 preserved from a
//      preceding SCF).
//   2. RRD (0x2100): A=0x7C, M[0x2100]=0x91 -> A=0x71, M[0x2100]=0xC9,
//      F=0x04 (PF set, CF=0 preserved from a preceding RCF — proving
//      the preserved bit is really carried through, not just
//      coincidentally zero).
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 500;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_rldtest_rom.py for the derivation.
	static const uint8_t prog[] = {
		0x3A, 0x00, 0x20, 0x36, 0x3F, 0x0D, 0xE2, 0x10, 0x2F, 0xE0, 0x56, 0x5A, 0xEB, 0x02, 0x90, 0x42,
		0x36, 0x7C, 0x0C, 0xE3, 0x00, 0x21, 0x11, 0x2F, 0xE1, 0x56, 0x5A, 0xEB, 0x06, 0x90, 0x42, 0xC8,
		0xFE,
	};
	std::memcpy(mem, prog, sizeof(prog));
	mem[0x2000] = 0xA5; // RLD's memory operand
	mem[0x2100] = 0x91; // RRD's memory operand

	Vtlcs90 top{&contextp};
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

	int fails = 0;
	auto check = [&](const char *what, uint8_t got, uint8_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%02X, expected 0x%02X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%02X\n", what, got);
	};

	check("RLD (HL): M[0x2000] after", mem[0x2000], 0x5F);
	check("RLD (HL): A after (observed via $FFE0)", mem[0xFFE0], 0x3A);
	check("RLD (HL): F after", mem[0x9002], 0x05);

	check("RRD (0x2100): M[0x2100] after", mem[0x2100], 0xC9);
	check("RRD (0x2100): A after (observed via $FFE1)", mem[0xFFE1], 0x71);
	check("RRD (0x2100): F after", mem[0x9006], 0x04);

	if (fails == 0) std::printf("tb_rldtest: PASS (all checks)\n");
	else            std::printf("tb_rldtest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
