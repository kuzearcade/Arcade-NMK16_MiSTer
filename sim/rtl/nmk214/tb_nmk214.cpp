// Standalone verification for rtl/nmk214/nmk214.sv: a from-scratch C++
// reference model (re-derived from mame/src/mame/nmk/nmk214.cpp's own
// published tables/algorithm, not copy-pasted from the SV translation)
// fuzzed against the Verilated RTL for many (config, address, data)
// combinations, across both MODE=0 and MODE=1 instances. Both test
// instances use the SV module's own default identity ADDR_BITSWAP, so
// this focuses on the hand-transcribed config/selector/output-bitswap
// tables and the MODE-gated config-latch behavior — the address-bitswap
// reordering itself is a simple per-bit reindex, reasoned about directly
// in the module's own header rather than re-verified here.
#include "Vnmk214_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static const uint8_t init_configs[8][3] = {
	{0xaa, 0xcc, 0xf0}, {0x55, 0x39, 0x1e}, {0xc5, 0x69, 0x5c}, {0x35, 0x5c, 0xc5},
	{0x78, 0x1d, 0x2e}, {0x55, 0x33, 0x0f}, {0xa5, 0xb8, 0x36}, {0x8b, 0x69, 0x2e},
};
static const uint8_t selection_address_bits[8][3] = {
	{0x8, 0x9, 0xa}, {0x6, 0x8, 0xb}, {0x3, 0x9, 0xc}, {0x3, 0x7, 0xa},
	{0x2, 0x5, 0xb}, {0x1, 0x4, 0xa}, {0x2, 0x4, 0xa}, {0x0, 0x4, 0xc},
};
static const uint8_t output_word_bitswaps[8][16] = {
	{0x2,0x3,0x7,0x8,0xc,0x4,0xb,0x9,0x1,0xf,0xa,0x5,0xe,0x6,0xd,0x0},
	{0x0,0x3,0x8,0x7,0xa,0xc,0x4,0x1,0xf,0x9,0x6,0xd,0xe,0xb,0x5,0x2},
	{0x9,0x8,0x2,0x3,0x6,0x5,0xd,0xf,0x7,0x0,0xc,0xb,0xa,0x4,0xe,0x1},
	{0x0,0x3,0x9,0xf,0xd,0xc,0xb,0x1,0x2,0x7,0xe,0x6,0x4,0xa,0x5,0x8},
	{0x1,0x3,0xf,0x7,0xd,0xa,0xe,0x9,0x0,0x8,0xc,0x4,0x6,0x5,0xb,0x2},
	{0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8,0x9,0xa,0xb,0xc,0xd,0xe,0xf},
	{0x0,0xf,0x3,0x2,0xe,0x4,0x6,0x7,0x8,0x9,0x5,0xd,0xc,0xb,0xa,0x1},
	{0xf,0x2,0x3,0x1,0xb,0xe,0xd,0x8,0x7,0x0,0x4,0xc,0x6,0xa,0x5,0x9},
};
static const uint8_t output_byte_bitswaps[8][8] = {
	{0x4,0x1,0x3,0x5,0x6,0x0,0x7,0x2},
	{0x6,0x4,0x1,0x5,0x2,0x7,0x0,0x3},
	{0x2,0x3,0x4,0x1,0x0,0x5,0x6,0x7},
	{0x1,0x5,0x0,0x2,0x6,0x7,0x4,0x3},
	{0x7,0x3,0x0,0x4,0x5,0x6,0x2,0x1},
	{0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7},
	{0x6,0x7,0x5,0x3,0x4,0x1,0x0,0x2},
	{0x1,0x2,0x6,0x4,0x0,0x7,0x3,0x5},
};

static uint8_t bitswap_select(uint8_t cfg, uint32_t addr /*identity, 13 bits used*/) {
	uint8_t sel = 0;
	for (int i = 0; i < 3; i++) {
		uint8_t bitpos = selection_address_bits[cfg][i];
		sel |= (uint8_t)(((addr >> bitpos) & 1u) << i);
	}
	uint8_t out = 0;
	for (int i = 0; i < 3; i++)
		out |= (uint8_t)((((init_configs[cfg][i] >> sel) & 1u)) << i);
	return out;
}

static uint16_t ref_decode_word(uint8_t cfg, uint32_t addr, uint16_t data) {
	uint8_t sel = bitswap_select(cfg, addr);
	uint16_t out = 0;
	for (int i = 0; i < 16; i++)
		out |= (uint16_t)(((data >> output_word_bitswaps[sel][i]) & 1u) << i);
	return out;
}
static uint8_t ref_decode_byte(uint8_t cfg, uint32_t addr, uint8_t data) {
	uint8_t sel = bitswap_select(cfg, addr);
	uint8_t out = 0;
	for (int i = 0; i < 8; i++)
		out |= (uint8_t)(((data >> output_byte_bitswaps[sel][i]) & 1u) << i);
	return out;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Vnmk214_tb_top *top = new Vnmk214_tb_top;

	top->clk = 0; top->reset0 = 1; top->reset1 = 1;
	top->cfg_we0 = 0; top->cfg_we1 = 0;
	for (int i = 0; i < 4; i++) { top->clk = !top->clk; top->eval(); }
	top->reset0 = 0; top->reset1 = 0;
	top->eval();

	int failures = 0, checks = 0;
	unsigned seed = 12345;
	auto rnd = [&](uint32_t bound) -> uint32_t {
		seed = seed * 1103515245u + 12345u;
		return (seed >> 16) % bound;
	};

	// Load a random config into each instance (respecting the MODE gate:
	// instance0=MODE0 needs bit3==0, instance1=MODE1 needs bit3==1) and
	// verify `initialized` only goes high on a matching write, never on
	// a mismatched one.
	uint8_t cfg0 = 0, cfg1 = 0;
	for (int trial = 0; trial < 50; trial++) {
		uint8_t cfg = (uint8_t)rnd(8);
		bool mode0_match = ((trial & 1) == 0); // alternate matching/mismatching bit3
		uint8_t data0 = (uint8_t)(cfg | (mode0_match ? 0x00 : 0x08));
		top->cfg_we0 = 1; top->cfg_data0 = data0;
		top->clk = 1; top->eval(); top->clk = 0; top->eval();
		top->cfg_we0 = 0;
		checks++;
		if (mode0_match) {
			cfg0 = cfg;
			if (!top->initialized0) { printf("FAIL: instance0 not initialized after matching cfg write (data=%02x)\n", data0); failures++; }
		} else {
			if (top->initialized0 && trial == 1) { /* fine if already initialized from a prior matching write */ }
		}

		bool mode1_match = ((trial & 1) == 1);
		uint8_t data1 = (uint8_t)(cfg | (mode1_match ? 0x08 : 0x00));
		top->cfg_we1 = 1; top->cfg_data1 = data1;
		top->clk = 1; top->eval(); top->clk = 0; top->eval();
		top->cfg_we1 = 0;
		checks++;
		if (mode1_match) {
			cfg1 = cfg;
			if (!top->initialized1) { printf("FAIL: instance1 not initialized after matching cfg write (data=%02x)\n", data1); failures++; }
		}
	}

	// Explicit MODE-mismatch-is-rejected check: reset instance0 only
	// (instance1/cfg1 stays untouched), write only a mismatched byte,
	// confirm initialized stays low and a subsequent matching write is
	// the one that actually takes effect.
	{
		top->reset0 = 1; top->clk = 1; top->eval(); top->clk = 0; top->eval(); top->reset0 = 0;
		top->cfg_we0 = 1; top->cfg_data0 = 0x0B; // bit3=1, mismatches instance0's MODE=0
		top->clk = 1; top->eval(); top->clk = 0; top->eval();
		top->cfg_we0 = 0;
		checks++;
		if (top->initialized0) { printf("FAIL: instance0 falsely initialized by a MODE-mismatched write\n"); failures++; }
		top->cfg_we0 = 1; top->cfg_data0 = 0x03; // bit3=0, matches
		top->clk = 1; top->eval(); top->clk = 0; top->eval();
		top->cfg_we0 = 0;
		checks++;
		if (!top->initialized0) { printf("FAIL: instance0 not initialized after a subsequent matching write\n"); failures++; }
		cfg0 = 0x03 & 0x7;
	}

	// Fuzz decode_word/decode_byte against the reference model across
	// all 8 configs (loaded explicitly here, not left to whatever the
	// randomized loading loop above happened to settle on) and many
	// random addresses/data words per config, for full table coverage.
	for (uint8_t sweep_cfg = 0; sweep_cfg < 8; sweep_cfg++) {
	top->cfg_we0 = 1; top->cfg_data0 = sweep_cfg; // bit3=0 matches instance0's MODE=0
	top->clk = 1; top->eval(); top->clk = 0; top->eval();
	top->cfg_we0 = 0;
	top->cfg_we1 = 1; top->cfg_data1 = (uint8_t)(sweep_cfg | 0x08); // bit3=1 matches instance1's MODE=1
	top->clk = 1; top->eval(); top->clk = 0; top->eval();
	top->cfg_we1 = 0;
	cfg0 = sweep_cfg;
	cfg1 = sweep_cfg;
	for (int trial = 0; trial < 2500; trial++) {
		uint32_t addr = rnd(1u << 13); // identity bitswap only reorders the low 13 bits meaningfully
		uint16_t dataw = (uint16_t)rnd(1u << 16);
		uint8_t datab = (uint8_t)rnd(256);

		top->addr0 = addr; top->din0 = dataw; top->din80 = datab;
		top->addr1 = addr; top->din1 = dataw; top->din81 = datab;
		top->eval();

		uint16_t exp_w0 = ref_decode_word(cfg0, addr, dataw);
		uint8_t  exp_b0 = ref_decode_byte(cfg0, addr, datab);
		uint16_t exp_w1 = ref_decode_word(cfg1, addr, dataw);
		uint8_t  exp_b1 = ref_decode_byte(cfg1, addr, datab);

		checks += 4;
		if (top->dout_word0 != exp_w0) {
			printf("FAIL word0: cfg=%u addr=%04x data=%04x got=%04x want=%04x\n", cfg0, addr, dataw, (unsigned)top->dout_word0, exp_w0);
			failures++;
		}
		if (top->dout_byte0 != exp_b0) {
			printf("FAIL byte0: cfg=%u addr=%04x data=%02x got=%02x want=%02x\n", cfg0, addr, datab, (unsigned)top->dout_byte0, exp_b0);
			failures++;
		}
		if (top->dout_word1 != exp_w1) {
			printf("FAIL word1: cfg=%u addr=%04x data=%04x got=%04x want=%04x\n", cfg1, addr, dataw, (unsigned)top->dout_word1, exp_w1);
			failures++;
		}
		if (top->dout_byte1 != exp_b1) {
			printf("FAIL byte1: cfg=%u addr=%04x data=%02x got=%02x want=%02x\n", cfg1, addr, datab, (unsigned)top->dout_byte1, exp_b1);
			failures++;
		}
		if (failures > 20) { printf("...too many failures, stopping early\n"); break; }
	}
	if (failures > 20) break;
	}

	printf("tb_nmk214: %d checks, %d failures (cfg0=%u cfg1=%u)\n", checks, failures, cfg0, cfg1);
	delete top;
	return failures ? 1 : 0;
}
