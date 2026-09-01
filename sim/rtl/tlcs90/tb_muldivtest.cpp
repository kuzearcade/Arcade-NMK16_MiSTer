// Standalone verification for the TLCS-90 CPU core's MUL/DIV (see
// docs/tier2-tlcs90.md), independent of nmk004_periph.sv/nmk004_core.sv.
// No currently-known NMK004 game's boot trace reaches these opcodes (same
// rationale as the RLD/RRD, block-transfer, and IX/IY bank-extension
// milestones), so this drives the CPU core directly against a synthetic
// program (assembled by gen_muldivtest_rom.py — see that file for the
// full derivation) and a flat 64KB memory model, checking HL (read back
// directly from the flat memory model after each test writes it out via
// LD (nn),HL) and F (via the PUSH AF/POP HL/LD (nn),HL trick established
// by tb_blocktest.cpp/tb_rldtest.cpp, since F has no other path to
// memory).
//
// Four sub-tests, with F deliberately chained across the three DIV tests
// (not re-primed each time) so the same running flag register proves both
// the "set VF" and "clear VF" paths key off *this* test's own quotient,
// not a coincidentally-already-right flag value:
//   1. MUL: 200*3=600 (0x0258) — a genuine 16-bit product, not an 8-bit
//      truncation; the old H (a 0xFF sentinel) is fully replaced; and,
//      checked against an SCF-primed F, that MUL touches no flags at all
//      (confirmed by reading the reference directly — no F=... line for
//      this op).
//   2. DIV (quotient=400>255): sets VF/PF.
//   3. DIV (quotient=14<=255): clears VF/PF — run immediately after test
//      2 left it set, so this only passes if the clear path is real.
//   4. DIV by zero: RCF first for a known F=0 baseline, then HL becomes
//      {old L, ~old H} per the reference's exact formula, VF forced set
//      unconditionally.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 700;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_muldivtest_rom.py for the derivation.
	static const uint8_t prog[] = {
		0x3A, 0xC8, 0xFF, 0x38, 0x03, 0x00, 0x0D, 0xF9, 0x12, 0xEB, 0x00, 0x90, 0x42, 0x56, 0x5A, 0xEB,
		0x02, 0x90, 0x42, 0x3A, 0xA0, 0x0F, 0x38, 0x00, 0x0A, 0xF8, 0x13, 0xEB, 0x04, 0x90, 0x42, 0x56,
		0x5A, 0xEB, 0x06, 0x90, 0x42, 0x3A, 0x64, 0x00, 0x38, 0x00, 0x07, 0xF8, 0x13, 0xEB, 0x08, 0x90,
		0x42, 0x56, 0x5A, 0xEB, 0x0A, 0x90, 0x42, 0x0C, 0x3A, 0x34, 0x12, 0x39, 0x00, 0x00, 0xFB, 0x13,
		0xEB, 0x0C, 0x90, 0x42, 0x56, 0x5A, 0xEB, 0x0E, 0x90, 0x42, 0xC8, 0xFE,
	};
	std::memcpy(mem, prog, sizeof(prog));

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

	auto rd16 = [&](uint16_t a) -> uint16_t { return mem[a] | (mem[a+1] << 8); };

	int fails = 0;
	auto check16 = [&](const char *what, uint16_t got, uint16_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%04X, expected 0x%04X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%04X\n", what, got);
	};
	auto check8 = [&](const char *what, uint8_t got, uint8_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%02X, expected 0x%02X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%02X\n", what, got);
	};

	check16("MUL 200*3: HL after", rd16(0x9000), 0x0258);
	check8 ("MUL: F after (unchanged from SCF)", mem[0x9002], 0x09);

	check16("DIV 4000/10: HL after", rd16(0x9004), 0x0090);
	check8 ("DIV 4000/10: F after (VF set, quotient>255)", mem[0x9006], 0x0D);

	check16("DIV 100/7: HL after", rd16(0x9008), 0x020E);
	check8 ("DIV 100/7: F after (VF cleared, quotient<=255)", mem[0x900A], 0x09);

	check16("DIV by zero: HL after ({old L, ~old H})", rd16(0x900C), 0x34ED);
	check8 ("DIV by zero: F after (VF forced set)", mem[0x900E], 0x04);

	if (fails == 0) std::printf("tb_muldivtest: PASS (all checks)\n");
	else            std::printf("tb_muldivtest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
