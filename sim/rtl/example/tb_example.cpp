// Smoke-test testbench for the Verilator harness plumbing. Drives
// example_counter.sv for a fixed number of cycles, logs every bus-like
// transaction through NmkTraceWriter, and exits. Purpose: prove the
// Verilator build + C++ testbench + trace-writer + oracle_diff.py chain
// works end to end, using a self-consistency check (compare the run's own
// trace against itself) rather than a MAME oracle, since this DUT has no
// real-hardware counterpart.
//
// NOT YET BUILD-TESTED in the environment this was authored in (no
// Verilator or C++ toolchain available there — see docs/sim-harness.md for
// exact status). Written to standard Verilator 5.x conventions; run
// `make -C sim/rtl/example` to build and self-check once Verilator is
// installed, and treat any compile error as a real bug report, not
// something to silently "fix around."

#include <cstdint>
#include <cstdio>

#include "Vexample_counter.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t NUM_CYCLES = 64;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vexample_counter top{&contextp};
	NmkTraceWriter trace("example.trace", "example_counter", 1, "tb", "mem", 0x00, 0xff, "-");
	Crc32 crc;

	top.reset = 1;
	top.write_en = 0;
	top.write_data = 0;

	uint64_t cycle = 0;
	uint8_t last_addr = 0xff;

	for (uint64_t i = 0; i < NUM_CYCLES; i++) {
		if (i == 4) top.reset = 0;
		// exercise the write path partway through, just to hit both trace kinds
		top.write_en = (i > 20 && i < 28) ? 1 : 0;
		top.write_data = static_cast<uint8_t>(i);

		top.clk = 0;
		top.eval();
		top.clk = 1;
		top.eval();
		cycle++;

		if (top.addr != last_addr) {
			trace.bus(cycle, 'r', top.addr, top.read_data, 0xff);
			last_addr = top.addr;
		}
		if (top.write_ack) {
			trace.bus(cycle, 'w', top.addr, top.write_data, 0xff);
		}
	}

	// One synthetic "frame" checksum over the final read_data byte, purely
	// to exercise the F-line path through the same writer real DUTs use.
	uint8_t final_byte = top.read_data;
	uint32_t frame_crc = crc.compute(&final_byte, 1);
	trace.frame(cycle, 0, frame_crc);

	trace.flush();
	std::printf("tb_example: ran %llu cycles, wrote example.trace\n", (unsigned long long)NUM_CYCLES);
	return 0;
}
