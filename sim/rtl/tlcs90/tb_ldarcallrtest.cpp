// Standalone verification for the TLCS-90 CPU core's LDAR/CALLR and the
// base table's 16-bit-relative JR form (see docs/tier2-tlcs90.md),
// independent of nmk004_periph.sv/nmk004_core.sv. No currently-known
// NMK004 game's boot trace reaches these opcodes (same rationale as the
// other synthetic-only milestones this session), so this drives the CPU
// core directly against a synthetic program (assembled by
// gen_ldarcallrtest_rom.py — see that file for the full derivation,
// including how the M_D16 "raw-1" displacement for each instruction is
// computed from its own address) and a flat 64KB memory model.
//
// Three sub-tests, all sharing the same underlying M_D16 arithmetic
// (`target = pc_after_instruction + raw16 - 1`) through three different
// consumers:
//   1. LDAR HL,+cd: HL becomes PC-relative (0x5000), no bus access, no
//      flags.
//   2. CALLR +cd: unconditional push+jump to a small subroutine at a
//      fixed address that writes a marker and RETs. Checks *two* things
//      independently: the subroutine's own marker (proves the jump
//      landed exactly on the subroutine's first instruction, not
//      mid-instruction) and a *second* marker written immediately after
//      the CALLR site once control returns (proves the pushed return
//      address is exactly right — RET landed on the very next
//      instruction after CALLR, not off by one).
//   3. JR T,+cd (16-bit form, opcode 0x1b, unconditional): jumps over an
//      8-byte "poison" block that writes a *different* marker and then
//      self-loops forever if ever reached. An off-by-one landing either
//      short or long is guaranteed to leave the real marker unwritten
//      (either the poison marker got written instead and the CPU is
//      stuck in its trap loop, or neither marker was ever reached) —
//      not just executed a cycle late and still passing by accident.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 1500;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_ldarcallrtest_rom.py for the derivation.
	static const uint8_t prog[] = {
		0x3E, 0x00, 0xF0, 0x17, 0xFB, 0x4F, 0xEB, 0x00, 0x90, 0x42, 0x1D, 0xF4, 0x00, 0x36, 0xAB, 0xEB,
		0x04, 0x90, 0x26, 0x1B, 0x09, 0x00, 0x36, 0xBA, 0xEB, 0x06, 0x90, 0x26, 0xC8, 0xFE, 0x36, 0xEF,
		0xEB, 0x06, 0x90, 0x26, 0xC8, 0xFE,
	};
	static const uint8_t sub[] = {
		0x36, 0xCD, 0xEB, 0x02, 0x90, 0x26, 0x1E,
	};
	std::memcpy(mem, prog, sizeof(prog));
	std::memcpy(&mem[0x0100], sub, sizeof(sub));

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

	check16("LDAR HL,+cd: HL after", rd16(0x9000), 0x5000);
	check8 ("CALLR: subroutine marker (jump landed exactly)", mem[0x9002], 0xCD);
	check8 ("CALLR: post-return marker (RET landed exactly)", mem[0x9004], 0xAB);
	check8 ("JR (16-bit): marker (jump landed exactly, no poison hit)", mem[0x9006], 0xEF);

	if (fails == 0) std::printf("tb_ldarcallrtest: PASS (all checks)\n");
	else            std::printf("tb_ldarcallrtest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
