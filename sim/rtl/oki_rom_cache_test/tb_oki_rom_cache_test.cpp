// Standalone verification of rtl/oki_rom_cache.sv. See docs/hw-bringup.md.
//
// Three checks:
//  1. stable-address byte reads return the pre-loaded pattern;
//  2. a jt6295-shaped access pattern — four channels each reading a
//     sequential ADPCM stream one byte per two "samples", the address
//     alternating with a phrase-table (ctrl) address inside every
//     channel slot exactly as jt6295_rom.v does — must (a) never yield a
//     wrong byte when ready, (b) have the byte resident on first
//     presentation nearly always (prefetch), and (c) spend a tiny
//     fraction of time stalled;
//  3. random moving addresses converge on correct data.
#include "Voki_rom_cache_test_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Voki_rom_cache_test_top *top;
static uint64_t cycles = 0;

static uint32_t z_pc = 0;
static long z_reads = 0, z_wrong = 0;
static uint8_t pattern(uint32_t byte_addr);
static void tick() {
	top->clk = 0; top->eval();
	top->clk = 1; top->eval();
	cycles++;
	// Z80-like reader: hold each address until ready (its wait-state),
	// then a new byte every ~40 cycles, sequential with occasional jumps.
	if (top->z_ready && (cycles % 40) == 0) {
		if (top->z_data != pattern(z_pc)) z_wrong++;
		z_reads++;
		z_pc = (rand() % 16 == 0) ? (rand() % 32768) : ((z_pc + 1) & 0x7FFF);
		top->z_addr = z_pc; top->eval();
	}
}

static uint8_t pattern(uint32_t byte_addr) {
	uint32_t w = byte_addr >> 1;
	uint16_t v = (uint16_t)((w * 7 + 3) & 0xFFFF);
	return (byte_addr & 1) ? (v >> 8) : (v & 0xFF);
}

static void write_word(uint32_t waddr, uint16_t val) {
	top->w_addr = waddr;
	top->w_din = val;
	top->w_req = 1;
	top->eval();
	while (!top->w_valid) tick();
	top->w_req = 0;
	tick();
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	top = new Voki_rom_cache_test_top;

	top->reset = 1;
	top->w_req = 0;
	top->c_addr = 0;
	top->z_addr = 0;
	for (int i = 0; i < 10; i++) tick();
	top->reset = 0;

	int waited = 0;
	while (!top->sdram_ready_o && waited < 200000) { tick(); waited++; }
	if (!top->sdram_ready_o) { printf("FAIL: sdram never ready\n"); return 1; }
	printf("sdram ready after %d cycles\n", waited);

	const int NWORDS = 16384;               // 32KB of sample ROM
	for (int a = 0; a < NWORDS; a++) write_word(a, (uint16_t)((a * 7 + 3) & 0xFFFF));
	printf("preload done: %d words\n", NWORDS);

	// Test 1
	srand(42);
	for (int i = 0; i < 3000; i++) {
		uint32_t a = rand() % (NWORDS * 2);
		top->c_addr = a; top->eval();
		int spin = 0;
		while (!top->c_ready && spin < 300) { tick(); spin++; }
		if (!top->c_ready) { printf("FAIL: stable read of 0x%05x never ready\n", a); return 1; }
		if (top->c_data != pattern(a)) { printf("FAIL: stable addr=0x%05x expected %02x got %02x\n", a, pattern(a), top->c_data); return 1; }
	}
	printf("PASS: 3000 stable-address byte reads, zero mismatches\n");

	// Test 1b: Z80-like channel alone (OKI address static) — isolates the
	// rom_cache1_byte-through-arbiter path.
	{
		long r0 = z_reads, w0 = z_wrong;
		top->c_addr = 0x100; top->eval();
		for (int i = 0; i < 400000; i++) tick();
		printf("Z80-like channel alone: %ld reads, %ld wrong\n", z_reads - r0, z_wrong - w0);
		z_wrong = 0;
	}

	// Test 2: jt6295-shaped pattern. cen = 4MHz on a 40MHz clk -> one
	// cen every 10 clk; cen_sr = cen/165; cen_sr4 every 165/4 cen
	// (~412 clk); cen_sr32 every ~52 clk. Per channel slot (412 clk):
	// slot phase 0..51: rom_addr = adpcm address (latched at ~clk 103),
	// phase 104..411: rom_addr = ctrl address.
	// Channel n reads bytes from base_n upward, one byte per two of its
	// own samples (a sample every 4 slots), i.e. advance every 8 slots.
	const int SLOT = 412, T32 = 52;
	uint32_t base[4] = { 0x0400, 0x2000, 0x4800, 0x7000 };
	uint32_t pos[4] = { 0, 0, 0, 0 };
	uint32_t ctrl_addr = 0x0010;             // phrase table lives at the start
	int slot_count = 4 * 2000;               // 2000 samples per channel
	long presented = 0, resident_at_present = 0, wrong = 0, stalled_cycles = 0, latched_not_ready = 0;
	long fetches = 0; bool prev_req = false;
	for (int s = 0; s < slot_count; s++) {
		int ch = s & 3;
		uint32_t a = base[ch] + pos[ch];
		// phase 0: present the sample address
		top->c_addr = a; top->eval();
		presented++;
		if (top->c_ready) resident_at_present++;
		// run two cen_sr32 slots; jt6295 keeps the byte seen at the end.
		// With cen gating, the chip would freeze while c_stall — model
		// that by extending the window by the stalled cycles.
		int budget = 2 * T32;
		int t = 0;
		while (t < budget) {
			tick();
			if (top->c_req && !prev_req) fetches++;
			prev_req = top->c_req;
			if (top->c_stall || top->c2_stall) { stalled_cycles++; budget++; }   // chip frozen this cycle
			if (budget > 20000) { printf("FAIL: stall never released (deadlock) at slot %d addr 0x%05x\n", s, a); return 1; }
			t++;
		}
		if (!top->c_ready || !top->c2_ready) latched_not_ready++;
		else if (top->c_data != pattern(a) || top->c2_data != pattern(a)) wrong++;
		// rest of the slot: ctrl address (every 40th slot a new phrase lookup)
		if (s % 40 == 0) ctrl_addr = (rand() % 0x100) * 8;
		top->c_addr = ctrl_addr; top->eval();
		for (int k = 0; k < SLOT - 2 * T32; k++) {
			tick();
			if (top->c_req && !prev_req) fetches++;
			prev_req = top->c_req;
			if (top->c_stall) stalled_cycles++;
			if (top->c_ready && top->c_data != pattern(ctrl_addr)) wrong++;
		}
		if ((s / 4) % 2 == 1) pos[ch]++;      // one byte per two samples
	}
	long total_cycles = (long)slot_count * SLOT;
	printf("jt6295 pattern: %ld sample bytes presented, %ld resident on first presentation (%.2f%%), "
	       "%ld wrong bytes, %ld not ready at latch, %ld SDRAM fetches, %ld stalled cycles of %ld (%.3f%%)\n",
	       presented, resident_at_present, 100.0 * resident_at_present / presented, wrong, latched_not_ready,
	       fetches, stalled_cycles, total_cycles, 100.0 * stalled_cycles / total_cycles);
	if (wrong) { printf("FAIL: wrong data while ready\n"); return 1; }
	if (latched_not_ready) { printf("FAIL: byte not resident at latch even with stall\n"); return 1; }
	if (resident_at_present < presented * 95 / 100) { printf("FAIL: prefetch hit rate too low\n"); return 1; }
	printf("PASS: jt6295 pattern (Z80-like channel: %ld reads, %ld wrong)\n", z_reads, z_wrong);
	if (z_wrong) { printf("FAIL: Z80-like channel wrong data\n"); return 1; }

	// Test 3
	for (int i = 0; i < 300; i++) {
		uint32_t target = rand() % (NWORDS * 2);
		for (int j = 0; j < 5; j++) { top->c_addr = rand() % (NWORDS * 2); top->eval(); tick(); }
		top->c_addr = target; top->eval();
		int spin = 0;
		while (!top->c_ready && spin < 400) { tick(); spin++; }
		if (!top->c_ready) { printf("FAIL: moving-address never converged on 0x%05x\n", target); return 1; }
		if (top->c_data != pattern(target)) { printf("FAIL: moving target=0x%05x expected %02x got %02x\n", target, pattern(target), top->c_data); return 1; }
	}
	printf("PASS: 300 moving-address convergence checks, zero mismatches\n");
	return 0;
}
