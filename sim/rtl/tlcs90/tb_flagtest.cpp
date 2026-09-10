// Standalone regression gate for the TLCS-90 CPU-core bugs found by
// register-state tracing against a MAME oracle during the GunNail
// sound-sequencer investigation (docs/hw-bringup.md "Fourth pass",
// docs/known-issues.md NMK-5), independent of nmk004_periph.sv /
// nmk004_core.sv. Drives the core directly against a synthetic program
// (assembled by gen_flagtest_rom.py — see that file for the derivation
// and the reference semantics quoted from tlcs90.cpp) and a flat 64KB
// memory model, exactly like tb_extest.cpp / tb_muldivtest.cpp.
//
// What it pins down:
//   - 8-bit INC/DEC recompute XCF every time (set only on a zero result),
//     with CF preserved across them.
//   - INCX/DECX execute only while XCF is set (the "INC lo; INCX hi"
//     16-bit chaining idiom) — checked in both the fires and must-not-fire
//     directions on a memory pair, so an always-run or never-run INCX/
//     DECX each fails a distinct check.
//   - SET/RES b,g under the 0xF8+g prefix write back to register g: A for
//     prefix 0xFE (the only form GunNail uses), and B/C for 0xF8/0xF9 —
//     with bit choices that would visibly corrupt A if the writeback
//     went to A regardless of g (the bug the first GunNail fix left).
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 800;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_flagtest_rom.py for the derivation.
	static const uint8_t prog[] = {
		0x0D, 0x36, 0x01, 0x8E, 0x56, 0x5A, 0xEB, 0x00, 0x90, 0x42, 0x36, 0x02, 0x8E, 0x56, 0x5A, 0xEB,
		0x02, 0x90, 0x42, 0x36, 0xFF, 0x86, 0x56, 0x5A, 0xEB, 0x04, 0x90, 0x42, 0x87, 0x10, 0x07, 0x11,
		0x87, 0x10, 0x07, 0x11, 0x8F, 0x20, 0x0F, 0x21, 0x8F, 0x20, 0x0F, 0x21, 0x36, 0x00, 0xFE, 0xBF,
		0xFE, 0xB8, 0xFE, 0xB7, 0x30, 0x00, 0x31, 0xFF, 0xF8, 0xBD, 0xF9, 0xB4, 0xEB, 0x06, 0x90, 0x40,
		0x56, 0x5A, 0xEB, 0x08, 0x90, 0x42, 0xC8, 0xFE,
	};
	std::memcpy(mem, prog, sizeof(prog));
	mem[0xFF10] = 0xFF; mem[0xFF11] = 0x12; // INCX chain pair: lo wraps 0xFF->0x00, hi must go 0x12->0x13 exactly once
	mem[0xFF20] = 0x01; mem[0xFF21] = 0x34; // DECX chain pair: lo 0x01->0x00, hi must go 0x34->0x33 exactly once

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
	auto check8 = [&](const char *what, uint8_t got, uint8_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%02X, expected 0x%02X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%02X\n", what, got);
	};

	// Flag bits per tlcs90.cpp: CF=0x01 NF=0x02 PF/VF=0x04 XCF=0x08 HF=0x10 IF=0x20 ZF=0x40 SF=0x80.
	// Observation words are {A, F} (PUSH AF; POP HL; LD (mn),HL).
	check16("DEC A 1->0: AF (F = ZF|NF|XCF|CF, CF kept from SCF)", rd16(0x9000), 0x004B);
	check16("DEC A 2->1: AF (F = NF|CF; XCF recomputed clear)",    rd16(0x9002), 0x0103);
	check16("INC A 0xFF->0: AF (F = ZF|HF|XCF|CF)",                rd16(0x9004), 0x0059);

	check8("INCX chain: lo after INC,INCX,INC,INCX",               mem[0xFF10], 0x01);
	check8("INCX chain: hi ran exactly once (0x12->0x13)",         mem[0xFF11], 0x13);
	check8("DECX chain: lo after DEC,DECX,DEC,DECX",               mem[0xFF20], 0xFF);
	check8("DECX chain: hi ran exactly once (0x34->0x33)",         mem[0xFF21], 0x33);

	check16("SET 5,B / RES 4,C: BC (writeback to g, not A)",       rd16(0x9006), 0x20EF);
	check8("SET 7,A; SET 0,A; RES 7,A: A (untouched by the B/C forms)", mem[0x9009], 0x01);

	if (fails == 0) std::printf("tb_flagtest: PASS (all checks)\n");
	else            std::printf("tb_flagtest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
