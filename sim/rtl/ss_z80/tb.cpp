#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vtop.h"
#include "verilated.h"
static uint8_t ram[65536], snap[65536], mon[128];
struct W { uint16_t a; uint8_t d; };
int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vtop top{&ctx};
	FILE *f = fopen("z80prog.bin","rb"); if (!f || fread(ram,1,65536,f) != 65536) { printf("no program\n"); return 2; } fclose(f);
	f = fopen("monz80_d0.bin","rb"); size_t monlen = fread(mon,1,128,f); fclose(f);
	// state
	bool park = false, done = false, resume = false; uint16_t sp_reg = 0; int im_mode = 0, snap_im = 0; uint16_t snap_sp = 0;
	int nmi_hold = 0; bool int_active = false; int wcount = 0, snap_wcount = 0;
	std::vector<W> writes, after_save, after_load;
	long cyc = 0; bool prev_w = false; uint16_t la = 0; uint8_t ld = 0; bool prev_m1fetch = false; uint8_t prev_op = 0;
	top.clk = 0; top.reset_n = 0; top.cen = 0; top.int_n = 1; top.nmi_n = 1; top.din = 0; top.eval();
	auto rd = [&](uint16_t ad) -> uint8_t {
		if (park && ad >= 0x66 && ad < 0x66 + monlen) return mon[ad - 0x66];
		if (park) switch (ad) { case 0xD0: return sp_reg & 0xff; case 0xD1: return sp_reg >> 8; case 0xD2: return done; case 0xD3: return resume; case 0xD4: return im_mode; }
		return ram[ad];
	};
	auto step = [&]() {
		top.clk = 0; top.eval();
		top.cen = ((cyc & 3) == 0);
		top.din = rd(top.a);
		top.nmi_n = nmi_hold ? 0 : 1; if (nmi_hold) nmi_hold--;
		top.int_n = int_active ? 0 : 1;
		top.clk = 1; top.eval(); cyc++;
		if (!top.reset_n && cyc > 64) top.reset_n = 1;
		bool m1fetch = !top.m1_n && !top.mreq_n && !top.rd_n;
		if (m1fetch && !prev_m1fetch) {                    // one opcode byte per M1 cycle
			uint8_t op = rd(top.a);
			if (prev_op == 0xED) { if (op==0x46||op==0x4E||op==0x66||op==0x6E) im_mode = 0; else if (op==0x56||op==0x76) im_mode = 1; else if (op==0x5E||op==0x7E) im_mode = 2; }
			prev_op = op;
		}
		prev_m1fetch = m1fetch;
		if (!top.m1_n && !top.iorq_n) int_active = false;  // interrupt acknowledged
		bool w = !top.mreq_n && !top.wr_n;
		if (w) { la = top.a; ld = top.dout; }
		if (!w && prev_w) {
			if (park && la >= 0xD0 && la <= 0xD4) { if (la == 0xD0) sp_reg = (sp_reg & 0xff00) | ld; if (la == 0xD1) sp_reg = (sp_reg & 0x00ff) | (ld << 8); if (la == 0xD2) done = ld & 1; }
			else { ram[la] = ld; writes.push_back({la, ld}); if (la == 0x8012) { if (++wcount == 16) { wcount = 0; int_active = true; } } }
		}
		prev_w = w;
	};
	auto do_park = [&]() { park = true; done = false; resume = false; nmi_hold = 40; long t0 = cyc; while (!done && cyc - t0 < 400000) step(); return done; };
	auto do_resume = [&]() { resume = true; long t1 = cyc; // leave when the CPU fetches game code again (below the overlay or above it)
		while (cyc - t1 < 400000) { step(); bool m1 = !top.m1_n && !top.mreq_n && !top.rd_n; if (m1 && (top.a < 0x66 || top.a >= 0x66 + monlen)) break; }
		park = false; resume = false; done = false; };
	while (writes.size() < 300) step();
	printf("phase 0: %zu writes, ISR count %d, IM %d\n", writes.size(), ram[0x9000], im_mode);
	for (int i = 0; i < 12; i++) printf("  w%d: %04x=%02x\n", i, writes[i].a, writes[i].d);
	if (!do_park()) { printf("FAIL: no DONE\n"); return 1; }
	printf("parked: SP reg %04x IM %d\n", sp_reg, im_mode);
	memcpy(snap, ram, 65536); snap_sp = sp_reg; snap_im = im_mode; snap_wcount = wcount; bool snap_int = int_active;
	size_t nw = writes.size(); do_resume();
	while (writes.size() < nw + 400) step(); after_save.assign(writes.begin()+nw, writes.end());
	printf("after save: A@8000=%02x BC@8002=%02x%02x IX@8008=%02x%02x ISR=%d\n", ram[0x8000], ram[0x8003], ram[0x8002], ram[0x8009], ram[0x8008], ram[0x9000]);
	while (writes.size() < nw + 1500) step();
	if (!do_park()) { printf("FAIL: second park\n"); return 1; }
	memcpy(ram, snap, 65536); sp_reg = snap_sp; im_mode = snap_im; wcount = snap_wcount; int_active = snap_int;
	size_t nw2 = writes.size(); do_resume();
	while (writes.size() < nw2 + 400) step(); after_load.assign(writes.begin()+nw2, writes.end());
	printf("after load: A@8000=%02x BC@8002=%02x%02x IX@8008=%02x%02x ISR=%d\n", ram[0x8000], ram[0x8003], ram[0x8002], ram[0x8009], ram[0x8008], ram[0x9000]);
	size_t bad = 0; for (size_t i = 0; i < 400; i++) if (after_save[i].a != after_load[i].a || after_save[i].d != after_load[i].d) { if (bad < 5) printf("  diff #%zu: save %04x=%02x load %04x=%02x\n", i, after_save[i].a, after_save[i].d, after_load[i].a, after_load[i].d); bad++; }
	printf("write streams after save vs after load: %zu of 400 differ -> %s\n", bad, bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
