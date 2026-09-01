// NMK16 MiSTerFPGA project — RTL-side trace writer.
//
// Emits the exact same nmktrace v1 text grammar as sim/oracle/trace.lua
// (see docs/sim-harness.md), so sim/compare/oracle_diff.py works unmodified
// against either side. Every DUT testbench under sim/rtl/ should use this
// rather than hand-rolling its own trace output.
#pragma once

#include <cstdio>
#include <cstdint>
#include <string>

class NmkTraceWriter {
public:
	NmkTraceWriter(const std::string &path, const std::string &game, uint64_t clock_hz,
	               const std::string &cpu, const std::string &space,
	               uint32_t addr_lo, uint32_t addr_hi, const std::string &screen) {
		f = std::fopen(path.c_str(), "w");
		if (!f) {
			std::fprintf(stderr, "NmkTraceWriter: could not open %s for writing\n", path.c_str());
			return;
		}
		std::fprintf(f, "# nmktrace v1 game=%s clock_hz=%llu cpu=%s space=%s addr=%x-%x screen=%s\n",
		             game.c_str(), (unsigned long long)clock_hz, cpu.c_str(), space.c_str(),
		             addr_lo, addr_hi, screen.c_str());
	}

	~NmkTraceWriter() {
		if (f) std::fclose(f);
	}

	// op is 'r' or 'w', matching sim/oracle/trace.lua's bus tap output exactly.
	void bus(uint64_t cycle, char op, uint32_t addr, uint32_t data, uint32_t mask) {
		if (!f) return;
		std::fprintf(f, "B %llu %c %x %x %x\n", (unsigned long long)cycle, op, addr, data, mask);
	}

	void frame(uint64_t cycle, uint32_t frame_num, uint32_t crc32) {
		if (!f) return;
		std::fprintf(f, "F %llu %u %08x\n", (unsigned long long)cycle, frame_num, crc32);
	}

	void reg(uint64_t cycle, const std::string &name, uint32_t value) {
		if (!f) return;
		std::fprintf(f, "R %llu %s %x\n", (unsigned long long)cycle, name.c_str(), value);
	}

	// Mirrors sim/oracle/trace.lua's NMKTRACE_ITEM_INDEX 'I' line: a
	// per-frame dump of u16 words as a concatenated lowercase hex string,
	// same field order (cycle, frame_num) so the two sides line up for a
	// direct diff. words[i] should already be masked to 16 bits.
	void item(uint64_t cycle, uint32_t frame_num, const uint16_t *words, size_t count) {
		if (!f) return;
		std::fprintf(f, "I %llu %u ", (unsigned long long)cycle, frame_num);
		for (size_t i = 0; i < count; i++) {
			std::fprintf(f, "%04x", words[i]);
		}
		std::fprintf(f, "\n");
	}

	void flush() {
		if (f) std::fflush(f);
	}

private:
	std::FILE *f = nullptr;
};
