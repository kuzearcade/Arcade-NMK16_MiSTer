# Simulation + MAME-oracle verification harness

Implements the verification methodology from `docs/PLAN.md`: every custom RTL block gets diffed in simulation against a trace extracted from real MAME execution before it's trusted, and before hardware bring-up.

## Architecture

```
MAME (+ nmktrace.lua)  --oracle.trace-->  oracle_diff.py  <--candidate.trace--  Verilator DUT testbench (+ NmkTraceWriter)
```

Both sides — MAME's Lua tracer and the RTL testbench's C++ trace writer — emit the *same* plain-text grammar (below), so one comparison tool works for both directions and there's exactly one format to get right.

## Trace format (nmktrace v1)

Plain text, one event per line. Deliberately not JSON/XML — MAME's embedded Lua has no guaranteed JSON library available to an `-autoboot_script` (the `json` plugin lives in MAME's separate plugin-loading path), and a hand-rolled line format has zero external dependency on either side.

```
# nmktrace v1 game=<name> clock_hz=<int> cpu=<tag> space=<name> addr=<lo_hex>-<hi_hex> screen=<tag>
B <cycle> <r|w> <addr_hex> <data_hex> <mask_hex>
F <cycle> <frame_num> <crc32_hex>
R <cycle> <reg_name> <value_hex>
```

- `#` header line is metadata only (informational; the comparison tool doesn't require it).
- `B` — one bus transaction (read or write) on the traced CPU's address space, in the traced address range.
- `F` — one video frame boundary: an IEEE 802.3/zlib-compatible CRC32 over the full frame's RGB pixel stream (row-major, 3 bytes/pixel). Cheap enough to log every frame of a full playthrough; catches any video divergence without needing to store raw pixel dumps.
- `R` — an optional named CPU register snapshot, taken at the same instant as each `F` line, for validating a CPU core's architectural state (not just its bus behavior) — this is how the TLCS-90 core gets checked once it exists, per `docs/PLAN.md`'s "TLCS-90 core validated first in isolation" requirement.
- `<cycle>` is a master-clock cycle count (`attotime * clock_hz`, floored), not wall-clock time, so both sides are comparable regardless of host simulation speed.

CRC32 is implemented from scratch identically on both sides (`sim/oracle/trace.lua`'s Lua version, `sim/rtl/common/crc32.h`'s C++ version) rather than relying on a library, specifically so there's no ambiguity about which CRC32 variant is in use. Both were checked against the standard test vector `CRC32("123456789") = 0xCBF43926` (Python's `zlib.crc32` agrees).

## Components

### `sim/oracle/trace.lua` — MAME-side tracer

Loaded via `mame <game> -autoboot_script sim/oracle/trace.lua`. Uses MAME's non-intrusive bus-tap API (`address_space:install_read_tap` / `install_write_tap`, confirmed present in the local MAME source at `src/frontend/mame/luaengine_mem.cpp:673-681`) to log every transaction in a configured range without altering emulated behavior, plus `emu.register_frame_done` + `screen_device:pixel(x,y)` for the per-frame checksum, plus `device.state[name].value` for register snapshots.

Configured entirely through environment variables (autoboot scripts get no CLI args) — see the file's header comment for the full list (`NMKTRACE_OUT`, `NMKTRACE_CPU`, `NMKTRACE_SPACE`, `NMKTRACE_ADDR_START/END`, `NMKTRACE_SCREEN`, `NMKTRACE_CLOCK_HZ`, `NMKTRACE_MAX_FRAMES`, `NMKTRACE_REGS`).

**Validated live** against this machine's installed MAME 0.285 (`/usr/games/mame`), using MAME's ROM-less `pong` driver (discrete-logic hardware, so no CPU/bus-tap path to exercise, but it fully exercises the file-I/O, frame-hook, pixel-readback, and CRC32 machinery):

```
$ NMKTRACE_OUT=pong.trace NMKTRACE_MAX_FRAMES=5 mame pong -video none -sound none -nothrottle -autoboot_script sim/oracle/trace.lua
[nmktrace] tracing to pong.trace (clock_hz=8000000)
[nmktrace] reached NMKTRACE_MAX_FRAMES=5, exiting
$ cat pong.trace
# nmktrace v1 game=pong clock_hz=8000000 cpu=- space=program addr=0-ffffff screen=:screen
F 34337 0 17908bb6
F 67571 1 52ffd0e9
...
```

**Bus-tap path validated live** too, once ROM dumps became available at `mame_roms/` (split MAME convention): ran against the real `cactus` romset (`mame cactus -rompath mame_roms -autoboot_script sim/oracle/trace.lua` with `NMKTRACE_CPU=":maincpu"`, a narrow work-RAM address window, and `NMKTRACE_REGS=PC`). Captured 512 real bus events in one frame — visibly a boot-time RAM POST test (each work-RAM word written `0xffff` then `0x0000` and read back) — plus a real `PC` register snapshot via `device.state`. Self-diffed clean through `oracle_diff.py`. Every piece of this harness is now live-verified against real hardware emulation, not just designed.

### `sim/rtl/common/{nmktrace.h,crc32.h}` — RTL-side trace writer

C++ header-only helpers any Verilator testbench includes to emit the identical grammar. `crc32.h` compiled and run for real (see below) as part of `sim/rtl/example`'s trace, and its `F` line was diffed byte-for-byte via `oracle_diff.py` — confirmed working, not just manually traced.

### `sim/rtl/example/` — Verilator harness smoke test

A trivial synthetic DUT (`example_counter.sv`, not part of the real core) plus a testbench (`tb_example.cpp`) and `Makefile`, whose only purpose is to prove the Verilator build → C++ testbench → `NmkTraceWriter` → `oracle_diff.py` chain works end to end before any real DUT (fx68k wrapper, TLCS-90 core, `nmk16spr`, ...) gets built against it.

**Build-tested and passing** (Verilator 5.032, g++ 15.2.0): `make -C sim/rtl/example check` builds the DUT, runs 64 cycles exercising both the `B ... r ...` and `B ... w ...` trace paths (61 reads, 7 writes, confirmed by inspecting the trace) plus one `F` frame-checksum line, then diffs the trace against itself — `MATCH: all 69 events identical`.

One real bug was caught and fixed in this pass: the first build failed on Verilator's `UNUSEDSIGNAL` lint (fatal by default) because `example_counter.sv`'s `write_data` input was a dead signal in the original trivial design. Fixed by actually latching `write_data` into a register that gates `read_data`, rather than suppressing the lint — the point of this smoke test is to prove the harness catches real issues, so a real fix was the right response, not a `lint_off` pragma.

### `sim/compare/oracle_diff.py` — comparison tool

Ordered walk of two nmktrace files (oracle vs. candidate), reporting the first divergence with full context (event index, source line numbers, decoded fields from both sides), a running mismatch count, and a `--cycle-tolerance` knob for early bring-up before a DUT's timing is proven cycle-exact. **Validated live**: self-match (identical files → exit 0, "MATCH"), single-field mutation (→ exit 1, correct mismatch reported at the right event index), and truncated-candidate length mismatch (→ exit 1, correct "lengths differ" report) all confirmed against real trace files generated by the `pong` run above.

## Toolchain status

Verilator 5.032, g++ 15.2.0, and Quartus Prime Lite 17.0 (`/home/vboxuser/intelFPGA_lite/17.0/`, `quartus_sh`/`quartus_map`/`quartus_pgm` confirmed present) are all installed on this machine. The full simulation chain above (Lua tracer → RTL testbench → comparison tool) is now live-verified end to end, not just designed. Quartus itself hasn't been exercised yet — that's a Tier 1 item once there's a real top-level to synthesize.

ROM dumps for all 101 romsets (split MAME convention) are available locally at `mame_roms/` — confirmed present for all three Tier 1 targets (`cactus.zip`, `bjtwinp.zip`/`bjtwinpa.zip`/`bjtwin.zip`/`bjtwina.zip`, `nouryoku.zip`/`nouryokup.zip`) and more broadly (102 zips total). Note: tracing was done against this machine's distro-packaged MAME 0.285, not a build of the pinned `mame/` source tree in this repo (that tree is reference-only, per `docs/PLAN.md`) — fine for proving the harness mechanics, but the *real* Tier 1 oracle traces should be re-captured against a MAME build matching `mame/`'s checked-out version once one exists, so ROM CRCs/driver behavior are guaranteed to match the exact reference being ported.

## What Tier 1 needs to add here

1. A real testbench for the first Tier 1 DUT (`fx68k` wrapper — see `deps.lock`) replacing the `example_counter` smoke test's role as "the thing being proven out."
2. A full, real oracle trace captured from `cactus`/`bjtwinp`/`nouryokup` covering their complete memory map (not just the narrow work-RAM window used for the validation pass above) — this is the first real oracle trace this project will diff RTL against.
3. Once fx68k's own bus behavior is diffed clean against that oracle, extend the same harness to `nmk16spr` (sprite engine) and the tilemap engine using the `F` frame-checksum path, per the plan's "frame-level oracle diffing" step.
