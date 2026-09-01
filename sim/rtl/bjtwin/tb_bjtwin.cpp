// Testbench for rtl/bjtwin/bjtwin_core.sv — runs the real cactus 68000 ROM
// (converted by tools/mkrom.py) and logs:
//   - every completed bus write cycle ('B' lines), for CPU/memory
//     correctness verification (see docs/tier1-bjtwin.md)
//   - a CRC32 checksum per rendered video frame ('F' lines), for video
//     pipeline verification, computed identically to sim/oracle/trace.lua's
//     screen:pixel() loop (row-major, byte order low-to-high = B,G,R,
//     matching a 0xRRGGBB-packed pixel read out low-byte-first) so
//     sim/compare/oracle_diff.py can diff either trace type unmodified.
//
// A bus write "completes" when ASn rises after having been asserted with
// eRWn low — the module exposes dbg_* signals sampled combinationally
// from the live bus, so this testbench does the edge detection rather
// than the RTL, keeping bjtwin_core's debug port simple.
//
// Timestamps are logged in CPU-clock cycles (matching the oracle's
// clock_hz=10000000, since bjtwin_core's CPU clock enable is undivided
// 10MHz from the 40MHz clk_sys via the /4 fx68k phase pattern) — a plain
// clk_sys tick counter divided by 4 approximates this closely enough for
// a first ordered-sequence comparison; exact cycle alignment against
// MAME's own bus-cycle timing model is a follow-up refinement once the
// value sequence itself is confirmed to match.
//
// video_bjtwin.sv's render FSM is a simulation-only per-frame procedural
// renderer (not real-time scanline-synchronized — see that file's header),
// so RUN_CYCLES here budgets for however long that FSM actually takes to
// reach the first sprite_dma_trigger (~scanline 242, which itself needs
// real raster time to arrive) plus a full tilemap+sprite render pass —
// substantially more clk_sys cycles than the CPU-only milestone needed.

#include <cstdint>
#include <cstdio>

#include "Vbjtwin_core.h"
#include "verilated.h"

#include "../common/crc32.h"
#include "../common/nmktrace.h"

static constexpr uint64_t RESET_CYCLES = 200;
static constexpr uint64_t RUN_CYCLES   = 12000000; // clk_sys cycles; see header comment for budget rationale
static constexpr int SCREEN_W = 384;
static constexpr int SCREEN_H = 224;

int main(int argc, char **argv) {
	VerilatedContext contextp;
	contextp.commandArgs(argc, argv);

	Vbjtwin_core top{&contextp};
	NmkTraceWriter trace("cactus_rtl.trace", "cactus", 10000000, ":maincpu", "program", 0x80000, 0xfffff, ":screen");
	Crc32 crc;

	top.reset = 1;

	uint64_t clk_sys_ticks = 0;
	bool prev_as_n = true;
	bool prev_write = false;
	bool prev_is_fetch = false;
	uint32_t last_addr = 0, last_data = 0, last_mask = 0;
	uint32_t last_fetch_pc = 0;
	uint32_t frame_count = 0;
	bool prev_frame_done = false;

	// Periodic PC sampling, decoupled from frame_done (which is tied to
	// the video render FSM's own completion time, not real raster
	// timing — see video_bjtwin.sv's header). Sampling on a fixed
	// CPU-cycle period matching one real frame (177920 cycles, from the
	// already-verified 10MHz CPU / 56.22Hz frame rate) gives a
	// raster-independent PC trace directly comparable to MAME oracle
	// PC snapshots taken once per real frame via register_frame_done.
	static constexpr uint64_t FRAME_PERIOD_CPU_CYCLES = 177920;
	uint64_t next_pc_sample_cycle = FRAME_PERIOD_CPU_CYCLES;
	uint32_t pc_sample_index = 0;

	auto tick = [&]() {
		top.clk_sys = 0;
		top.eval();
		top.clk_sys = 1;
		top.eval();
		clk_sys_ticks++;
	};

	for (uint64_t i = 0; i < RESET_CYCLES; i++) {
		tick();
	}
	top.reset = 0;

	for (uint64_t i = 0; i < RUN_CYCLES; i++) {
		// Sample bus state while ASn is asserted, so we have the
		// last-valid values in hand when it rises.
		if (!top.dbg_as_n) {
			last_addr = (uint32_t)top.dbg_eab << 1;
			last_data = top.dbg_data;
			uint32_t mask = 0;
			if (!top.dbg_uds_n) mask |= 0xff00;
			if (!top.dbg_lds_n) mask |= 0x00ff;
			last_mask = mask;
			prev_write = top.dbg_write;
			// 68000 function code: program access (instruction fetch) is
			// FC2:0 = 010 or 110, i.e. FC1=1, FC0=0 regardless of FC2 —
			// during such a cycle the address bus IS the fetch address.
			prev_is_fetch = top.dbg_fc1 && !top.dbg_fc0;
		}

		bool as_n_now = top.dbg_as_n;
		if (prev_as_n == false && as_n_now == true) {
			// bus cycle just completed
			if (prev_write) {
				uint64_t cpu_cycle = clk_sys_ticks / 4;
				trace.bus(cpu_cycle, 'w', last_addr, last_data, last_mask);
			}
			if (!prev_write && prev_is_fetch) {
				last_fetch_pc = last_addr;
			}
		}
		prev_as_n = as_n_now;

		uint64_t cpu_cycle_now = clk_sys_ticks / 4;
		if (cpu_cycle_now >= next_pc_sample_cycle) {
			trace.reg(cpu_cycle_now, "PCSAMPLE", last_fetch_pc);
			pc_sample_index++;
			next_pc_sample_cycle = FRAME_PERIOD_CPU_CYCLES * (pc_sample_index + 1);
		}

		bool frame_done_now = top.frame_done;
		if (!prev_frame_done && frame_done_now) {
			// scan the whole frame and checksum it exactly like
			// sim/oracle/trace.lua's screen:pixel() loop
			uint32_t frame_crc = 0xFFFFFFFFu;
			// use Crc32's table-driven compute() one byte at a time via
			// a small local buffer to match the running-CRC semantics
			uint8_t bytes[SCREEN_W * SCREEN_H * 3];
			size_t bi = 0;
			for (int y = 0; y < SCREEN_H; y++) {
				for (int x = 0; x < SCREEN_W; x++) {
					top.rd_x = x;
					top.rd_y = y;
					top.eval();
					uint32_t rgb = top.rd_rgb; // {R8,G8,B8}
					bytes[bi++] = (uint8_t)(rgb & 0xFF);         // B (low byte first, matches trace.lua)
					bytes[bi++] = (uint8_t)((rgb >> 8) & 0xFF);  // G
					bytes[bi++] = (uint8_t)((rgb >> 16) & 0xFF); // R
				}
			}
			frame_crc = crc.compute(bytes, bi);
			uint64_t cpu_cycle = clk_sys_ticks / 4;
			trace.frame(cpu_cycle, frame_count, frame_crc);
			trace.reg(cpu_cycle, "PC", last_fetch_pc);

			// dump every frame as a PPM for visual debugging (cheap: these
			// are tiny 384x224 images) — bytes[] is already B,G,R order,
			// PPM wants R,G,B, so re-derive from rgb per pixel instead of
			// reusing the CRC byte buffer directly.
			{
				char fname[64];
				std::snprintf(fname, sizeof(fname), "frame_%02u.ppm", frame_count);
				FILE *ppm = std::fopen(fname, "wb");
				std::fprintf(ppm, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
				for (int y = 0; y < SCREEN_H; y++) {
					for (int x = 0; x < SCREEN_W; x++) {
						top.rd_x = x;
						top.rd_y = y;
						top.eval();
						uint32_t rgb = top.rd_rgb;
						uint8_t rgb_bytes[3] = {
							(uint8_t)((rgb >> 16) & 0xFF),
							(uint8_t)((rgb >> 8) & 0xFF),
							(uint8_t)(rgb & 0xFF)
						};
						std::fwrite(rgb_bytes, 1, 3, ppm);
					}
				}
				std::fclose(ppm);
			}

			// dump sprite_snap (video_bjtwin's DMA'd sprite draw buffer)
			// via the dbg_snap_addr/dbg_snap_data readback port, for direct
			// comparison against MAME's m_spriteram_old (captured via
			// trace.lua's NMKTRACE_ITEM_INDEX=6) — see docs/tier1-bjtwin.md's
			// "sprite_dma() buffer verification" section.
			{
				static uint16_t snap[2048];
				for (uint32_t a = 0; a < 2048; a++) {
					top.dbg_snap_addr = a;
					top.eval();
					snap[a] = top.dbg_snap_data;
				}
				trace.item(cpu_cycle, frame_count, snap, 2048);
			}

			frame_count++;
		}
		prev_frame_done = frame_done_now;

		tick();
	}

	trace.flush();
	std::printf("tb_bjtwin: ran %llu clk_sys cycles (~%llu CPU cycles), %u frame(s) rendered, wrote cactus_rtl.trace\n",
	            (unsigned long long)RUN_CYCLES, (unsigned long long)(RUN_CYCLES / 4), frame_count);
	return 0;
}
