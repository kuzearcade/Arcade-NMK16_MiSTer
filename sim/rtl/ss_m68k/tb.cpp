#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vtop.h"
#include "verilated.h"
// 64 KB RAM as 32K words
static uint16_t ram[32768], snap[32768];
struct W { uint32_t a; uint16_t d; uint8_t be; };
int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vtop top{&ctx};
	// program (see the harness notes): vectors, then code at 0x1000
	memset(ram, 0, sizeof ram);
	auto W32 = [&](uint32_t a, uint32_t v){ ram[a/2] = v>>16; ram[a/2+1] = v & 0xffff; };
	auto W16 = [&](uint32_t a, uint16_t v){ ram[a/2] = v; };
	W32(0, 0x8000); W32(4, 0x1000); W32(0x7C, 0x00000000);
	uint16_t code[] = {0x2C7C,0x1234,0x5678, 0x4E66, 0x7000, 0x7201, 0x243C,0x0BAD,0xF00D, 0x2E3C,0xAAAA,0x5555, 0x2A7C,0xDEAD,0xBEEF,
	                   0x227C,0x0000,0x2000,
	                   /*1018*/ 0x5280, 0xE399, 0xD482, 0x32C0, 0x33C0,0x0000,0x3000, 0x23C1,0x0000,0x3004, 0x23C2,0x0000,0x3008,
	                   0xB2FC,0x2100, 0x66E0, 0x227C,0x0000,0x2000, 0x60D8};
	// the loop label must be at 0x1018: prologue is 18 words = 36 bytes -> loop at 0x1024. Adjust branch offsets:
	// BNE.S at index 34 (addr 0x1000+34*2=0x1044): target 0x1024, from 0x1046 -> -0x22 = 0xDE ; BRA.S at index 39 (0x104E): from 0x1050 -> -0x2C = 0xD4
	code[34] = 0x66DE; code[39] = 0x60D4;
	for (size_t i = 0; i < sizeof code / 2; i++) W16(0x1000 + 2*i, code[i]);

	top.clk = 0; top.reset = 1; top.park_req = 0; top.resume = 0; top.regs_load = 0; top.mem_rdata = 0; top.eval();
	std::vector<W> writes; std::vector<W> after_save, after_load;
	int phase = 0; long cyc = 0; long park_at = 0; uint32_t snap_ssp = 0, snap_usp = 0;
	int prev_wr = 0, prev_done = 0; long saw_game = 0;
	auto step = [&]() {
		top.clk = 0; top.eval();
		// memory read data (combinational for the model: respond to the current address)
		uint32_t a = top.mem_a * 2;
		top.mem_rdata = (a < 0x10000) ? ram[a/2] : 0;
		top.clk = 1; top.eval(); cyc++;
		if (top.reset && cyc > 40) top.reset = 0;
		// writes: commit at the END of the write cycle (data/strobes valid then)
		static uint32_t la = 0; static uint16_t ld = 0; static uint8_t lbe = 0;
		if (top.mem_wr) { la = top.mem_a * 2; ld = top.mem_wdata; lbe = top.mem_be; }
		if (!top.mem_wr && prev_wr) {
			if (la < 0x10000) {
				uint16_t v = ram[la/2];
				if (lbe & 2) v = (v & 0x00ff) | (ld & 0xff00);
				if (lbe & 1) v = (v & 0xff00) | (ld & 0x00ff);
				ram[la/2] = v;
				writes.push_back({la, ld, lbe});
			}
		}
		prev_wr = top.mem_wr;
	};
	// phase 0: run until 300 writes
	while (writes.size() < 300) step();
	printf("phase 0: %zu writes, last @%06x\n", writes.size(), writes.back().a);
	// SAVE: park
	top.park_req = 1; long t0 = cyc;
	while (!top.park_done && cyc - t0 < 200000) step();
	if (!top.park_done) { printf("FAIL: monitor never signalled DONE\n"); return 1; }
	printf("parked after %ld clk; SSP %08x USP %08x\n", cyc - t0, top.ssp_reg, top.usp_reg);
	memcpy(snap, ram, sizeof ram); snap_ssp = top.ssp_reg; snap_usp = top.usp_reg;
	size_t nw = writes.size();
	top.resume = 1;
	// wait for the monitor to leave (a game-space fetch), then drop the request
	{ long t1 = cyc; while (!top.fetch_game && cyc - t1 < 200000) step(); }
	top.park_req = 0; top.resume = 0;
	// discard the monitor's own register-restore reads; record 400 game writes after the resume
	while (writes.size() < nw + 400) step();
	after_save.assign(writes.begin() + nw, writes.end());
	printf("after save: recorded %zu writes; D0@3000=%04x D1@3004=%04x%04x D2@3008=%04x%04x\n", after_save.size(), ram[0x3000/2], ram[0x3004/2], ram[0x3006/2], ram[0x3008/2], ram[0x300a/2]);
	// keep running a while
	while (writes.size() < nw + 1500) step();
	// LOAD: park, restore RAM + state registers, resume
	top.park_req = 1; t0 = cyc;
	while (!top.park_done && cyc - t0 < 200000) step();
	if (!top.park_done) { printf("FAIL: second park never signalled DONE\n"); return 1; }
	memcpy(ram, snap, sizeof ram);
	top.ssp_load = snap_ssp; top.usp_load = snap_usp; top.regs_load = 1; step(); top.regs_load = 0;
	size_t nw2 = writes.size();
	top.resume = 1;
	{ long t1 = cyc; while (!top.fetch_game && cyc - t1 < 200000) step(); }
	top.park_req = 0; top.resume = 0;
	while (writes.size() < nw2 + 400) step();
	after_load.assign(writes.begin() + nw2, writes.end());
	printf("after load: D0@3000=%04x D1@3004=%04x%04x D2@3008=%04x%04x\n", ram[0x3000/2], ram[0x3004/2], ram[0x3006/2], ram[0x3008/2], ram[0x300a/2]);
	// compare
	size_t bad = 0;
	for (size_t i = 0; i < 400; i++) if (after_save[i].a != after_load[i].a || after_save[i].d != after_load[i].d || after_save[i].be != after_load[i].be) { if (bad < 5) printf("  diff #%zu: save @%06x=%04x/%d  load @%06x=%04x/%d\n", i, after_save[i].a, after_save[i].d, after_save[i].be, after_load[i].a, after_load[i].d, after_load[i].be); bad++; }
	printf("write streams after save vs after load: %zu of 400 differ -> %s\n", bad, bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
