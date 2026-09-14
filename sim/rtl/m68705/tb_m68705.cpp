// Standalone M68705R3 testbench: rtl/m68705/m68705_core.sv (jotego's jt6805
// plus this project's peripheral wrapper) running tharrierb's own dumped MCU
// image, diffed instruction-by-instruction against a MAME m6805 trace.
//
// The MCU's only non-deterministic inputs are Port B (the 68000's data latch),
// Port D (the cabinet inputs) and the external IRQ pin. In the traced window
// Port D reads 0x00 on every select, so it is tied low; Port B's 43 reads are
// replayed from the MAME log in order; and the IRQ is asserted at the exact
// instruction indices where MAME took it (roms/irq_at.txt), which keeps the
// whole run deterministic.
//
//   TB_ROM       MCU image hex          (default roms/tharrierb_mcu.hex)
//   TB_PC        MAME PC list           (default roms/mame_pc.txt)
//   TB_PORTB     Port B replay values   (default roms/portb_in.txt)
//   TB_IRQ       IRQ instruction indices, one per line (default roms/irq_at.txt)
//   TB_MAX       stop after N instructions (default: the whole PC list)
//   TB_TRACE     write every instruction as "idx pc a x s cc" to this file
#include <verilated.h>
#include "Vm68705_core.h"
#include "Vm68705_core___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::vector<unsigned> load_list(const char *path, int base) {
	std::vector<unsigned> v;
	FILE *f = std::fopen(path, "r");
	if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(2); }
	char line[64];
	while (std::fgets(line, sizeof(line), f))
		if (line[0] && line[0] != '\n') v.push_back(std::strtoul(line, nullptr, base));
	std::fclose(f);
	return v;
}

static const char *env(const char *n, const char *d) {
	const char *v = std::getenv(n);
	return (v && *v) ? v : d;
}

int main(int argc, char **argv) {
	VerilatedContext ctx;
	ctx.commandArgs(argc, argv);
	Vm68705_core top{&ctx};
	auto *r = top.rootp;

	const std::vector<unsigned> ref   = load_list(env("TB_PC",    "roms/mame_pc.txt"),   16);
	const std::vector<unsigned> portb = load_list(env("TB_PORTB", "roms/portb_in.txt"),  16);
	std::vector<unsigned> irq_at;
	{	// optional
		FILE *f = std::fopen(env("TB_IRQ", "roms/irq_at.txt"), "r");
		if (f) { std::fclose(f); irq_at = load_list(env("TB_IRQ", "roms/irq_at.txt"), 10); }
	}
	size_t max_i = ref.size();
	if (std::getenv("TB_MAX")) max_i = std::strtoul(std::getenv("TB_MAX"), nullptr, 0);

	FILE *trace = nullptr;
	if (std::getenv("TB_TRACE")) trace = std::fopen(std::getenv("TB_TRACE"), "w");
	FILE *iotrace = nullptr;
	if (std::getenv("TB_IOTRACE")) iotrace = std::fopen(std::getenv("TB_IOTRACE"), "w");

	top.reset = 1; top.cen = 0; top.irq_n = 1;
	top.portb_in = 0xFF; top.portd_in = 0x00;
	top.rom_we = 0; top.rom_waddr = 0; top.rom_wdata = 0;
	for (int i = 0; i < 8; i++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
	top.reset = 0;

	size_t pb_i = 0, irq_i = 0, n = 0, mismatches = 0;
	unsigned first_bad = 0;
	uint64_t cycle = 0;

	// The interrupt is level-sensitive here: hold irq_n low from the
	// instruction boundary before MAME took it until the RTL has entered the
	// vector, then release. irq_pending tracks that window.
	bool irq_hold = false;
	bool retire_pb = false;
	bool pend_valid = false; int pend_wait = 0;
	size_t pend_n = 0; unsigned pend_pc = 0, pend_a = 0, pend_x = 0, pend_s = 0, pend_cc = 0;
	unsigned pend_ua = 0; int pend_irq = 0;

	while (n < max_i && cycle < 4000000000ULL) {
		// cen every 4th clk: on the board it is the MCU's 2.4576 MHz crystal
		// against 40 MHz clk_sys (1 in 16). Anything >= 2 gives the registered
		// ROM/RAM reads a settled cycle before the CPU latches them.
		top.cen = ((cycle & 3) == 3);
		top.clk = 0; top.eval();

		// Port B replay: the next unconsumed value is presented continuously and
		// retired only when the CPU actually latches it — jt6805 samples `din`
		// on `fetch`, so a write to Port B (same address, no fetch) does not eat
		// one, which an address-only edge detector would get wrong.
		top.portb_in = (pb_i < portb.size()) ? portb[pb_i] : 0xFF;

		top.irq_n = irq_hold ? 0 : 1;

		top.clk = 1; top.eval();
		cycle++;
		if (pend_wait && top.cen) {
			pend_wait = 0;
			pend_a = r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__a;
			pend_x = r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__x;
			pend_s = r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__s;
			pend_cc = (r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__h << 4) |
			          (r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__i << 3) |
			          (r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__n << 2) |
			          (r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__z << 1) |
			          (r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__c);
		}
		// `fetch` read after the edge is the NEXT microinstruction's control bit,
		// so the byte on din is latched by the edge after that: retire the
		// replay value one cycle later than it is detected, or the CPU sees the
		// following value instead of the one it asked for.
		if (top.cen) {
			if (retire_pb) { if (pb_i < portb.size()) pb_i++; retire_pb = false; }
			else if (r->m68705_core__DOT__u_cpu__DOT__fetch && r->m68705_core__DOT__a == 1)
				retire_pb = true;
		}
		if (iotrace && r->m68705_core__DOT__wr && r->m68705_core__DOT__a < 0x80)
			std::fprintf(iotrace, "%llu a=%02X fetch=%d wr=%d din=%02X dout=%02X pc=%03X n=%zu\n",
			             (unsigned long long)cycle, r->m68705_core__DOT__a,
			             r->m68705_core__DOT__u_cpu__DOT__fetch, r->m68705_core__DOT__wr,
			             r->m68705_core__DOT__din, r->m68705_core__DOT__dout,
			             r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__pc & 0xFFF, n);

		// `ni` starts an instruction: its opcode is already in md (fetched
		// without advancing PC), so PC is that instruction's own address and
		// A/X/S are its entry state — exactly what MAME's trace line shows.
		if (top.cen && r->m68705_core__DOT__u_cpu__DOT__u_ctrl__DOT__ni) {
			unsigned got = r->m68705_core__DOT__u_cpu__DOT__u_regs__DOT__pc & 0xFFF;
			// `ni` is read after the edge, so this record is captured one cycle
			// before the boundary it names actually happens: pulling IRQ low while
			// handling record R makes the CPU vector on record R's own boundary.
			// MAME's trace prints no line for that boundary (just an
			// "(interrupted at ...)" note), so the vectoring record is traced but
			// neither compared nor counted, keeping the indices aligned.
			bool vectoring = (irq_i < irq_at.size() && n == irq_at[irq_i]);
			if (vectoring) { irq_hold = true; irq_i++; }
			else if (irq_hold) irq_hold = false;

			pend_valid = true; pend_n = vectoring ? (size_t)-1 : n; pend_pc = got; pend_wait = 1;
			pend_ua = r->m68705_core__DOT__u_cpu__DOT__u_ctrl__DOT__uaddr;
			pend_irq = irq_hold;
			if (vectoring) continue;

			if (got != ref[n]) {
				if (mismatches == 0) {
					first_bad = n;
					std::printf("FIRST MISMATCH at instruction %zu: rtl %03X, mame %03X\n", n, got, ref[n]);
					std::printf("  mame context:");
					for (size_t k = (n > 6 ? n - 6 : 0); k <= n + 2 && k < ref.size(); k++)
						std::printf(" %s%03X", k == n ? ">" : "", ref[k]);
					std::printf("\n");
				}
				if (++mismatches > 20) break;
			}
			n++;
		}
	}

	std::printf("instructions executed: %zu / %zu, mismatches: %zu%s\n",
	            n, max_i, mismatches,
	            mismatches ? "" : "  ALL MATCH");
	if (mismatches) std::printf("first divergence at instruction %u\n", first_bad);
	if (trace) std::fclose(trace);
	return mismatches ? 1 : 0;
}
