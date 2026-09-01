// Standalone verification for the TLCS-90 CPU core's block-transfer/compare
// family (LDI/LDIR/LDD/LDDR/CPI/CPIR/CPD/CPDR — see docs/tier2-tlcs90.md),
// independent of nmk004_periph.sv/nmk004_core.sv. No currently-known
// NMK004 game's boot trace exercises these opcodes (they weren't reached
// before the host-handshake boundary the existing 175-checkpoint oracle
// trace stops at), so — same rationale and technique as tb_banktest.cpp —
// this drives the CPU core directly against a synthetic program and a
// flat 64KB memory model, checking results the CPU has no debug port to
// expose directly (BC/HL/DE/F after each block op) by having the program
// itself write them out to fixed "observe" addresses via LD (nn),rr and a
// PUSH AF/POP HL/LD (nn),HL trick for flags.
//
// Five sub-tests, assembled by gen_blocktest_rom.py (see that file for the
// full program and the address/opcode derivation):
//   1. LDIR:  copy 5 bytes 0x2000->0x3000. Checks the copy is byte-exact,
//      nothing was written past the end, and BC/HL/DE land where the
//      reference's algorithm says they should (BC=0, HL/DE past the end).
//   2. LDDR:  copy 4 bytes 0x2100->0x3100 *descending* (HL/DE start at the
//      end of each block). Same checks, plus the descending equivalent of
//      "nothing written past the end" (one byte *before* the destination
//      block must stay untouched).
//   3. CPIR:  search for 0xCC in a 5-byte block that contains it at index
//      2. Checks BC/HL land where a found-and-stopped-early search should,
//      and F (via the PUSH AF/POP HL/LD (nn),HL trick, since F has no
//      other observable path) matches the reference's exact flag formula
//      for a match (Z=1, N=1, PF=1 since BC!=0, CF preserved from a
//      preceding SCF).
//   4. CPDR:  search for 0xCC in a 5-byte block that does *not* contain
//      it, descending. Checks the search correctly exhausts BC to 0
//      (never finding a false match) and F matches the not-found case
//      (Z=0, N=1, PF=0 since BC==0, SF set from the last comparison).
//   5. LDI (single-step, not LDIR): copies exactly one byte and does NOT
//      repeat — checks BC is decremented by exactly 1, not driven to 0,
//      and the second source byte was never touched.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Vtlcs90.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 2000;

static uint8_t mem[65536];

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	// Program bytes — see gen_blocktest_rom.py for the source of this
	// exact sequence (address/opcode derivation, symbolic labels).
	static const uint8_t prog[] = {
		0x3A, 0x00, 0x20, 0x39, 0x00, 0x30, 0x38, 0x05, 0x00, 0xFE, 0x59, 0xEB, 0x00, 0x90, 0x40, 0xEB,
		0x02, 0x90, 0x42, 0xEB, 0x04, 0x90, 0x41, 0x3A, 0x03, 0x21, 0x39, 0x03, 0x31, 0x38, 0x04, 0x00,
		0xFE, 0x5B, 0xEB, 0x06, 0x90, 0x40, 0xEB, 0x08, 0x90, 0x42, 0xEB, 0x0A, 0x90, 0x41, 0x3A, 0x00,
		0x22, 0x38, 0x05, 0x00, 0x0D, 0x36, 0xCC, 0xFE, 0x5D, 0xEB, 0x0C, 0x90, 0x40, 0xEB, 0x0E, 0x90,
		0x42, 0x56, 0x5A, 0xEB, 0x10, 0x90, 0x42, 0x3A, 0x04, 0x23, 0x38, 0x05, 0x00, 0x0D, 0x36, 0xCC,
		0xFE, 0x5F, 0xEB, 0x12, 0x90, 0x40, 0x56, 0x5A, 0xEB, 0x14, 0x90, 0x42, 0x3A, 0x00, 0x24, 0x39,
		0x00, 0x34, 0x38, 0x02, 0x00, 0xFE, 0x58, 0xEB, 0x16, 0x90, 0x40, 0xC8, 0xFE,
	};
	std::memcpy(mem, prog, sizeof(prog));

	// Source data (destinations are left as the default zero-fill, acting
	// as the "untouched" sentinel).
	static const struct { uint16_t addr; uint8_t val; } src[] = {
		{0x2000,0xAA},{0x2001,0xBB},{0x2002,0xCC},{0x2003,0xDD},{0x2004,0xEE}, // SRC1 (LDIR)
		{0x2100,0x11},{0x2101,0x22},{0x2102,0x33},{0x2103,0x44},               // SRC2 (LDDR)
		{0x2200,0x01},{0x2201,0x02},{0x2202,0xCC},{0x2203,0x04},{0x2204,0x05}, // SRC3 (CPIR, match at index 2)
		{0x2300,0x01},{0x2301,0x02},{0x2302,0x03},{0x2303,0x04},{0x2304,0x05}, // SRC4 (CPDR, no match)
		{0x2400,0x77},{0x2401,0x88},                                          // SRC5 (LDI single)
	};
	for (auto &e : src) mem[e.addr] = e.val;

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

	// 1. LDIR
	check16("LDIR final BC", rd16(0x9000), 0x0000);
	check16("LDIR final HL", rd16(0x9002), 0x2005);
	check16("LDIR final DE", rd16(0x9004), 0x3005);
	static const uint8_t ldir_expect[5] = {0xAA,0xBB,0xCC,0xDD,0xEE};
	bool ldir_copy_ok = std::memcmp(&mem[0x3000], ldir_expect, 5) == 0;
	if (ldir_copy_ok) std::printf("OK:   LDIR copied bytes match source exactly\n");
	else { std::fprintf(stderr, "FAIL: LDIR copied bytes do not match source\n"); fails++; }
	check8("LDIR byte past destination end (must be untouched)", mem[0x3005], 0x00);

	// 2. LDDR
	check16("LDDR final BC", rd16(0x9006), 0x0000);
	check16("LDDR final HL", rd16(0x9008), 0x20FF);
	check16("LDDR final DE", rd16(0x900A), 0x30FF);
	static const uint8_t lddr_expect[4] = {0x11,0x22,0x33,0x44};
	bool lddr_copy_ok = std::memcmp(&mem[0x3100], lddr_expect, 4) == 0;
	if (lddr_copy_ok) std::printf("OK:   LDDR copied bytes match source exactly\n");
	else { std::fprintf(stderr, "FAIL: LDDR copied bytes do not match source\n"); fails++; }
	check8("LDDR byte before destination start (must be untouched)", mem[0x30FF], 0x00);

	// 3. CPIR (found at index 2 of 5 -> stops early)
	check16("CPIR final BC (found, stops early)", rd16(0x900C), 0x0002);
	check16("CPIR final HL (one past the match)", rd16(0x900E), 0x2203);
	check8("CPIR final F (Z=1,N=1,PF=1,CF preserved=1)", mem[0x9010], 0x47);

	// 4. CPDR (not found -> exhausts BC to 0)
	check16("CPDR final BC (not found, exhausted)", rd16(0x9012), 0x0000);
	check8("CPDR final F (Z=0,N=1,PF=0,SF=1,CF preserved=1)", mem[0x9014], 0x83);

	// 5. LDI (single-step: must NOT repeat)
	check16("LDI final BC (decremented once, not driven to 0)", rd16(0x9016), 0x0001);
	check8("LDI copied first byte", mem[0x3400], 0x77);
	check8("LDI did not touch second byte (no repeat)", mem[0x3401], 0x00);

	if (fails == 0) std::printf("tb_blocktest: PASS (all checks)\n");
	else            std::printf("tb_blocktest: FAIL (%d checks failed)\n", fails);
	return fails ? 1 : 0;
}
