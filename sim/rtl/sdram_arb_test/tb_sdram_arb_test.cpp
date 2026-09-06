// Standalone verification of rtl/sdram_arb.sv — N=3 logical channels
// sharing one physical rtl/sdram.sv port. See docs/hw-bringup.md.
#include "Vsdram_arb_test_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <map>

static Vsdram_arb_test_top *top;

static void tick() {
	top->clk = 0;
	top->eval();
	top->clk = 1;
	top->eval();
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	top = new Vsdram_arb_test_top;

	top->reset = 1;
	for (int i = 0; i < 3; i++) { top->c_req[i] = 0; top->c_we[i] = 0; }
	for (int i = 0; i < 10; i++) tick();
	top->reset = 0;

	int waited = 0;
	while (!top->sdram_ready_o && waited < 200000) { tick(); waited++; }
	if (!top->sdram_ready_o) { printf("FAIL: sdram never ready\n"); return 1; }
	printf("sdram ready after %d cycles\n", waited);

	std::map<uint32_t, uint16_t> ref;
	srand(999);
	const int N = 20000;
	int checks = 0;

	for (int iter = 0; iter < N; iter++) {
		struct { uint32_t addr; bool we; uint16_t din, got; bool active; } r[3];

		for (int p = 0; p < 3; p++) {
			r[p].active = (rand() % 4) != 0; // occasionally leave a channel idle this round, to check fairness doesn't wedge
			if (!r[p].active) { top->c_req[p] = 0; continue; }
			uint32_t addr = (p * 4096) + (rand() % 4096); // disjoint per-channel ranges, same reasoning as sdram_test
			bool is_write = (rand() % 2) == 0;
			r[p].addr = addr; r[p].we = is_write; r[p].din = is_write ? (uint16_t)(rand() & 0xFFFF) : 0;
			top->c_addr[p] = addr; top->c_we[p] = is_write; top->c_wrl[p] = 1; top->c_wrh[p] = 1;
			top->c_din[p] = r[p].din; top->c_req[p] = 1;
		}
		// sdram_arb requires req to be HELD until that channel's own valid
		// pulse arrives (unlike a standalone sdram_req, a channel may wait
		// several cycles for its turn) — so don't clear c_req here.
		top->eval();

		bool got[3] = {false, false, false};
		int spin = 0;
		while (spin < 400) {
			top->eval();
			for (int p = 0; p < 3; p++) {
				if (r[p].active && !got[p] && top->c_valid[p]) {
					got[p] = true;
					r[p].got = top->c_dout[p];
					top->c_req[p] = 0; // drop as soon as this channel is serviced
				}
			}
			bool done = true;
			for (int p = 0; p < 3; p++) if (r[p].active && !got[p]) done = false;
			tick();
			spin++;
			// One extra tick after the last channel's valid pulse (which is
			// exactly 1 cycle wide) so it falls low again before the next
			// iteration's very first check — otherwise that check could
			// read this round's still-visible pulse/dout and misattribute
			// it to a different (not-yet-granted) request.
			if (done) break;
		}
		for (int p = 0; p < 3; p++) top->c_req[p] = 0;
		for (int p = 0; p < 3; p++) {
			if (r[p].active && !got[p]) { printf("FAIL: channel %d never got valid (iter %d) -- possible arbiter starvation\n", p, iter); return 1; }
		}

		for (int p = 0; p < 3; p++) {
			if (!r[p].active) continue;
			checks++;
			if (r[p].we) {
				ref[r[p].addr] = r[p].din;
			} else {
				auto it = ref.find(r[p].addr);
				if (it != ref.end() && it->second != r[p].got) {
					printf("FAIL: channel %d addr 0x%06x expected 0x%04x got 0x%04x (iter %d)\n", p, r[p].addr, it->second, r[p].got, iter);
					return 1;
				}
				if (it == ref.end()) ref[r[p].addr] = r[p].got;
			}
		}
	}

	printf("PASS: %d read/write checks across 3 arbitrated channels on one shared port, zero mismatches\n", checks);
	return 0;
}
