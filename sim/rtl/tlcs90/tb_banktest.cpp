// Standalone verification for the TLCS-90 CPU core's IX/IY bank extension
// (tlcs90.sv's `bank1`/`bank2`/`addr_bank`, see docs/tier2-tlcs90.md) —
// independent of nmk004_periph.sv/nmk004_core.sv, which don't back a
// nonzero bank with real memory yet. Drives `ix_bank` directly (BX/BY
// themselves live in a peripheral module, not the CPU, so no peripheral is
// needed to exercise the CPU's own address computation) and runs a tiny
// synthetic program against a 16-bank x 64KB memory model that can tell
// which bank each access actually landed in — something a single flat
// address space can't distinguish.
//
// Program (see the addr/opcode table below), with IX=0x1000 and
// ix_bank=5 for the whole run:
//   LD IX,0x1000
//   LD A,(IX)            ; M_MR16 read  (bank2 path) -> must read bank 5
//   LD ($FFE0),A          ; direct write (never banked) -> must land in bank 0
//   LD A,0x77
//   LD (IX),A             ; M_MR16 write (bank1 path) -> must land in bank 5
//   LD A,(IX+0x10)        ; IXD read     (bank2 path, via `gg`/pfx) -> bank 5
//   LD ($FFE1),A          ; direct write (never banked) -> bank 0
//   LD A,0x88
//   LD (IX+0x10),A        ; IXD write    (bank1 path) -> bank 5
//   JR T,-2                ; self-loop (park)
//
// Bank 0 and bank 5 are pre-seeded with different sentinel bytes at
// 0x1000/0x1010 so a read that landed in the wrong bank is immediately
// visible, and the post-run check confirms the "wrong" bank's sentinel is
// untouched (proving OR-not-add: no aliasing/bleed into bank 0).
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 400;
static constexpr uint8_t  TEST_BANK  = 5;

static uint8_t mem[16][65536];

static uint8_t read_mem(uint8_t bank, uint16_t addr) { return mem[bank][addr]; }
static void write_mem(uint8_t bank, uint16_t addr, uint8_t data) { mem[bank][addr] = data; }

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	static const struct { uint16_t addr; uint8_t val; } prog[] = {
		{0x0000, 0x3C}, {0x0001, 0x00}, {0x0002, 0x10}, // LD IX,0x1000
		{0x0003, 0xE4}, {0x0004, 0x2E},                 // LD A,(IX)
		{0x0005, 0x2F}, {0x0006, 0xE0},                 // LD ($FFE0),A
		{0x0007, 0x36}, {0x0008, 0x77},                 // LD A,0x77
		{0x0009, 0xEC}, {0x000A, 0x26},                 // LD (IX),A
		{0x000B, 0xF0}, {0x000C, 0x10}, {0x000D, 0x2E}, // LD A,(IX+0x10)
		{0x000E, 0x2F}, {0x000F, 0xE1},                 // LD ($FFE1),A
		{0x0010, 0x36}, {0x0011, 0x88},                 // LD A,0x88
		{0x0012, 0xF4}, {0x0013, 0x10}, {0x0014, 0x26}, // LD (IX+0x10),A
		{0x0015, 0xC8}, {0x0016, 0xFE},                 // JR T,-2
	};
	for (auto &e : prog) mem[0][e.addr] = e.val;

	mem[0][0x1000] = 0xAA; mem[TEST_BANK][0x1000] = 0x55; // M_MR16 read/write sentinels
	mem[0][0x1010] = 0xBB; mem[TEST_BANK][0x1010] = 0x66; // IXD read/write sentinels

	Vtlcs90 top{&contextp};
	top.reset = 1;
	top.nmi = 0;
	top.irq_req = 0;
	top.irq_mask = 0;
	top.ix_bank = TEST_BANK;
	top.iy_bank = 0;
	top.din = 0;

	auto tick = [&]() {
		top.din = read_mem(top.addr_bank, top.addr);
		top.eval();
		top.clk = 1;
		top.eval();
		if (top.mem_wr) {
			write_mem(top.addr_bank, top.addr, top.dout);
			// Direct ($FF00+n) writes must never carry a bank.
			if ((top.addr == 0xFFE0 || top.addr == 0xFFE1) && top.addr_bank != 0)
				std::fprintf(stderr, "FAIL: direct write to $%04X carried bank %u (expected 0)\n",
				             top.addr, top.addr_bank);
		}
		top.clk = 0;
		top.eval();
	};

	for (int i = 0; i < 8; i++) tick();
	top.reset = 0;
	for (uint64_t i = 0; i < RUN_CYCLES; i++) tick();

	int fails = 0;
	auto check = [&](const char *what, uint8_t got, uint8_t want) {
		if (got != want) {
			std::fprintf(stderr, "FAIL: %s = 0x%02X, expected 0x%02X\n", what, got, want);
			fails++;
		} else {
			std::printf("OK:   %s = 0x%02X\n", what, got);
		}
	};

	check("bank0[$FFE0] (LD A,(IX) then LD ($FFE0),A)", mem[0][0xFFE0], 0x55);
	check("bank5[0x1000] (LD (IX),A)",                   mem[TEST_BANK][0x1000], 0x77);
	check("bank0[0x1000] (must be untouched)",           mem[0][0x1000], 0xAA);
	check("bank0[$FFE1] (LD A,(IX+0x10) then LD ($FFE1),A)", mem[0][0xFFE1], 0x66);
	check("bank5[0x1010] (LD (IX+0x10),A)",              mem[TEST_BANK][0x1010], 0x88);
	check("bank0[0x1010] (must be untouched)",           mem[0][0x1010], 0xBB);

	if (fails == 0) std::printf("tb_banktest: PASS (all 6 checks)\n");
	else            std::printf("tb_banktest: FAIL (%d/6 checks failed)\n", fails);
	return fails ? 1 : 0;
}
