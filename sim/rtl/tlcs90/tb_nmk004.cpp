// Testbench for rtl/tlcs90/nmk004_core.sv — the full NMK004 board wrapper
// (CPU + real on-chip peripherals/timers/interrupts + memory map), as
// opposed to tb_tlcs90.cpp's standalone-CPU-with-generic-RAM smoke test.
//
// Two modes, selected by which boot ROM is linked in (see Makefile):
//   - roms/nmk004_boot.hex (make run-nmk004): the real boot ROM + mustang
//     external program. Logs every instruction boundary's PC for a
//     regression check against the same oracle trace tb_tlcs90.cpp was
//     verified against — real peripherals should not change anything
//     already-verified. This mode never reaches the real ROM's EI
//     instruction (PC=0x1DA), since that's past the host-handshake wait
//     loop and there's no real 68000 in this testbench — so it does not
//     exercise interrupt dispatch.
//   - roms/irqtest_boot.hex (make run-irqtest): a small synthetic program
//     (see that file's generation, docs/tier2-tlcs90.md "Interrupt
//     self-test") that sets SP, configures timer 0 to fire quickly,
//     enables INTT0 + EI, then self-loops. Proves the CPU's
//     interrupt-dispatch mechanism end-to-end (vector jump, PUSH PC then
//     AF, IF clear/restore, RETI return, re-arming for the next fire) by
//     checking that PC visits the INTT0 vector (0x30) repeatedly and that
//     execution returns to the self-loop each time rather than resetting.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vnmk004_core.h"
#include "verilated.h"

static constexpr uint64_t RUN_CYCLES = 100000;
static constexpr uint16_t IRQTEST_VECTOR = 0x0030; // INTT0, see roms/irqtest_boot.hex

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vnmk004_core top{&contextp};
	const char *trace_path = (argc > 1) ? argv[1] : "nmk004_rtl.trace";
	FILE *out = std::fopen(trace_path, "w");
	bool log_p4 = std::getenv("TB_LOG_IRQ") != nullptr;

	top.reset = 1;
	top.nmi = 0;
	top.host_to_mcu = 0xff; // idle: nothing written by a (nonexistent, in this testbench) 68000 host yet
	top.ym_din = 0x00;
	top.ym_irq_n = 1; // idle: no real YM2203 core in this CPU-only testbench
	top.oki0_din = 0x00;
	top.oki1_din = 0x00;

	auto tick = [&]() {
		top.clk = 1;
		top.eval();
		if (top.dbg_valid) std::fprintf(out, "%04X\n", top.dbg_pc);
		top.clk = 0;
		top.eval();
	};

	for (int i = 0; i < 8; i++) tick();
	top.reset = 0;

	uint64_t n_instr = 0;
	uint64_t n_vector_hits = 0;
	uint8_t prev_p4 = 0;
	for (uint64_t i = 0; i < RUN_CYCLES; i++) {
		tick();
		if (top.dbg_valid) {
			n_instr++;
			if (top.dbg_pc == IRQTEST_VECTOR) n_vector_hits++;
		}
		if (log_p4 && top.p4 != prev_p4) {
			std::fprintf(stderr, "cycle=%llu P4=%02X\n", (unsigned long long)i, top.p4);
			prev_p4 = top.p4;
		}
	}

	std::fclose(out);
	std::printf("tb_nmk004: ran %llu clk cycles, %llu instructions, wrote %s\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)n_instr, trace_path);
	std::printf("tb_nmk004: PC visited $%04X (irqtest INTT0 vector) %llu times\n",
	            IRQTEST_VECTOR, (unsigned long long)n_vector_hits);
	return 0;
}
