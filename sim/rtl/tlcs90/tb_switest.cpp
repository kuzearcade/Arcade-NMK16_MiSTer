// Standalone verification for the TLCS-90 CPU core's SWI (see
// docs/tier2-tlcs90.md), independent of nmk004_periph.sv/nmk004_core.sv.
// No currently-known NMK004 game's boot trace reaches this opcode (same
// rationale as every other synthetic-only milestone this session), so
// this drives the CPU core directly against a synthetic program
// (assembled by gen_switest_rom.py — see that file for the full
// derivation and address layout) and a flat 64KB memory model.
//
// One scenario, checked four independent ways:
//   - `DI` immediately before `SWI` proves SWI is genuinely non-maskable
//     in this model (unlike NMI — see the interrupt-model doc) by simply
//     still working with IF=0: if OP_SWI's dispatch were accidentally
//     gated on f[IFB] (e.g. copy-paste residue from the maskable-IRQ
//     dispatch path it reuses), none of the other checks below would
//     pass either.
//   - Two "poison" blocks sit at 0x0008 (no real source there, but a
//     plausible landing spot for a vector-arithmetic off-by-one) and
//     0x0018 (NMI's own real vector, a plausible landing spot for "used
//     the wrong irq index somewhere"). Each writes its own marker and
//     then self-loops forever if ever reached, so a wrong-vector bug is
//     guaranteed to leave the real ISR's marker unwritten, not just
//     executed a cycle late.
//   - The real ISR at 0x0010 deliberately corrupts A before returning,
//     so checking A is back to its pre-SWI value afterward proves RETI's
//     restore is real, not just "nothing happened to touch it".
//   - F is checked the same way, via the standard PUSH AF/POP HL/
//     LD (nn),HL observation trick.
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

	// {address, byte} pairs — see gen_switest_rom.py for the derivation.
	static const struct { uint16_t addr; uint8_t val; } prog[] = {
		{0x0000, 0x1A}, {0x0001, 0x00}, {0x0002, 0x01},
		{0x0008, 0x36}, {0x0009, 0xBA}, {0x000A, 0xEB}, {0x000B, 0x06},
		{0x000C, 0x90}, {0x000D, 0x26}, {0x000E, 0xC8}, {0x000F, 0xFE},
		{0x0010, 0x36}, {0x0011, 0x99}, {0x0012, 0xEB}, {0x0013, 0x00},
		{0x0014, 0x90}, {0x0015, 0x26}, {0x0016, 0x1F}, {0x0017, 0x00},
		{0x0018, 0x36}, {0x0019, 0xBB}, {0x001A, 0xEB}, {0x001B, 0x08},
		{0x001C, 0x90}, {0x001D, 0x26}, {0x001E, 0xC8}, {0x001F, 0xFE},
		{0x0100, 0x3E}, {0x0101, 0x00}, {0x0102, 0xF0}, {0x0103, 0x36},
		{0x0104, 0x42}, {0x0105, 0x0D}, {0x0106, 0x02}, {0x0107, 0xFF},
		{0x0108, 0xEB}, {0x0109, 0x02}, {0x010A, 0x90}, {0x010B, 0x26},
		{0x010C, 0x56}, {0x010D, 0x5A}, {0x010E, 0xEB}, {0x010F, 0x04},
		{0x0110, 0x90}, {0x0111, 0x42}, {0x0112, 0xC8}, {0x0113, 0xFE},
	};
	for (auto &e : prog) mem[e.addr] = e.val;

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
	auto check8 = [&](const char *what, uint8_t got, uint8_t want) {
		if (got != want) { std::fprintf(stderr, "FAIL: %s = 0x%02X, expected 0x%02X\n", what, got, want); fails++; }
		else std::printf("OK:   %s = 0x%02X\n", what, got);
	};

	check8("SWI: real ISR ran (vector 0x0010)", mem[0x9000], 0x99);
	check8("SWI: A restored by RETI", mem[0x9002], 0x42);
	check8("SWI: F restored by RETI (CF=1,XCF=1)", mem[0x9004], 0x09);
	check8("SWI: never landed on 0x0008", mem[0x9006], 0x00);
	check8("SWI: never landed on NMI's vector (0x0018)", mem[0x9008], 0x00);

	if (fails == 0) std::printf("tb_switest: PASS (all checks)\n");
	else            std::printf("tb_switest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
