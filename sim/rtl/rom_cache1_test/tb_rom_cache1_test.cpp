// Standalone verification of rtl/rom_cache1.sv. See docs/hw-bringup.md.
#include "Vrom_cache1_test_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vrom_cache1_test_top *top;

static void tick() {
	top->clk = 0; top->eval();
	top->clk = 1; top->eval();
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
	top = new Vrom_cache1_test_top;

	top->reset = 1;
	top->w_req = 0;
	for (int i = 0; i < 10; i++) tick();
	top->reset = 0;

	int waited = 0;
	while (!top->sdram_ready_o && waited < 200000) { tick(); waited++; }
	if (!top->sdram_ready_o) { printf("FAIL: sdram never ready\n"); return 1; }
	printf("sdram ready after %d cycles\n", waited);

	// Pre-load a known pattern: word at address A = (A*7+3) & 0xFFFF.
	const int NWORDS = 8192;
	for (int a = 0; a < NWORDS; a++) {
		write_word(a, (uint16_t)((a * 7 + 3) & 0xFFFF));
	}
	printf("preload done: %d words\n", NWORDS);

	// Test 1: stable-address reads (mimics a CPU bus cycle holding its
	// address steady) — set c_addr, wait for c_ready, check data, move on.
	srand(42);
	int checks = 0;
	for (int i = 0; i < 5000; i++) {
		uint32_t a = rand() % NWORDS;
		top->c_addr = a;
		top->eval();
		int spin = 0;
		while (!top->c_ready && spin < 200) { tick(); spin++; }
		if (!top->c_ready) { printf("FAIL: stable-address read of 0x%04x never became ready\n", a); return 1; }
		uint16_t expect = (uint16_t)((a * 7 + 3) & 0xFFFF);
		if (top->c_data != expect) {
			printf("FAIL: stable-address addr=0x%04x expected 0x%04x got 0x%04x\n", a, expect, top->c_data);
			return 1;
		}
		checks++;
	}
	printf("PASS: %d stable-address reads, zero mismatches\n", checks);

	// Test 2: address changes every single cycle, faster than the cache
	// can possibly keep up — the point of this test is only that
	// rom_cache1 never returns WRONG data for whatever address it claims
	// ready for; a moving target may simply take a while to converge on
	// a hit at all, so this test drives one target address for a bounded
	// window and requires it to eventually become ready with correct data.
	int moving_checks = 0;
	for (int i = 0; i < 500; i++) {
		uint32_t target = rand() % NWORDS;
		// jitter the address for a few cycles first (never settling),
		// then settle on `target` and require convergence.
		for (int j = 0; j < 5; j++) {
			top->c_addr = rand() % NWORDS;
			top->eval();
			tick();
		}
		top->c_addr = target;
		top->eval();
		int spin = 0;
		while (!(top->c_ready && top->c_addr == target) && spin < 300) { tick(); top->eval(); spin++; }
		if (!top->c_ready) { printf("FAIL: moving-address test never converged on target 0x%04x\n", target); return 1; }
		uint16_t expect = (uint16_t)((target * 7 + 3) & 0xFFFF);
		if (top->c_data != expect) {
			printf("FAIL: moving-address target=0x%04x expected 0x%04x got 0x%04x\n", target, expect, top->c_data);
			return 1;
		}
		moving_checks++;
	}
	printf("PASS: %d moving-address convergence checks, zero mismatches\n", moving_checks);

	return 0;
}
