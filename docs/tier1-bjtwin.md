# Tier 1 — bjtwin family (cactus / bjtwinp / nouryokup)

Status: **CPU + memory-map + interrupt subsystem verified exactly against a real MAME oracle trace. Video pipeline's internal state — palette RAM, tilemap VRAM, and the sprite DMA draw buffer (`m_spriteram_old`), all with complete address coverage — is verified bit-exact against MAME via direct state comparison. The render architecture is now real-time/scanline-synchronized (a pure per-pixel tile-decode function plus a double-buffered, budget-walked sprite plane) rather than an unbounded procedural per-frame sweep — see "Real-time scanline-synchronized render architecture" below.** An apparent CPU-side control-flow bug was found earlier, investigated at length, and then **retracted** as a false positive of a Lua bus-tap blind spot — see "Sprite rendering verification" below for the full story. Frame-level pixel rendering is still not compared against MAME pixel-for-pixel (only the boot-time single-color case has been checked by hand). Audio (`nmk112` + 2x OKIM6295) is not implemented yet.

## Hardware spec

Full register-level spec (address map, screen timing, tilemap/sprite/IRQ/nmk112 config, clock tree, ROM regions) extracted directly from `mame/src/mame/nmk/nmk16.cpp`/`nmk16_v.cpp` for this specific board/game trio — see the file header comment in `rtl/bjtwin/bjtwin_core.sv`, which documents the memory map inline, and the design notes below for anything not obvious from the RTL itself.

Key facts:
- 68000 @ 10.000000 MHz (undivided), pixel/sprite clock @ 8.000000 MHz, both OKIM6295 @ 4.000000 MHz. No shared XTAL between CPU and video/audio.
- Screen: 512x278 total, 384x224 visible, hblank 28-412, vblank 16-240 (≈56.22 Hz).
- Single COL-scan 8x8 tilemap, 64x32 tiles, no X-scroll register (Y-scroll only).
- Sprite RAM is not separately mapped — it's a 4KB sub-region of main work RAM (`0x0F8000-0x0F8FFF`), DMA'd into the sprite engine's draw buffer. bjtwin/cactus is **single-buffered** (unlike most other games in this driver family, which double-buffer).
- `cactus` specifically: undumped timing PROMs → MAME substitutes a fixed 5-entry scanline table (IRQ2@16, IRQ1@68+196, IRQ4@240, sprite-DMA-trigger@242) instead of the real dual-PROM `nmk_irq` state machine. `bjtwinp`/`nouryokup` have real PROM dumps and need the real state machine — **not yet implemented**, `rtl/bjtwin/nmk_irq_hacky.sv` only covers cactus's fixed-table variant.
- `cactus`'s graphics ROMs are scrambled with a fixed, address-selected bitswap (a bootleg's static equivalent of the real board's NMK214 chip) — this is a one-time ROM-load-time transform, not live protection hardware, so it belongs in the eventual `.mra` (pre-descrambled ROM data), not in RTL. Not yet implemented (video isn't built yet either).

## What's built

- `rtl/bjtwin/bjtwin_core.sv` — fx68k instantiation, full address decode per the map above, ROM (`$readmemh`-loaded, parameterized path), main work RAM (32K x 16), palette RAM (1024 x 16), BG tilemap VRAM (2048 x 16, mirrored), and I/O register capture (flipscreen, tilebank, Y-scroll, nmk112 bank registers — captured, not yet functionally connected since audio doesn't exist yet). Owns a shared `video_timing` instance and instantiates `video_bjtwin`, with second read-tap ports added onto the palette/bgvram/mainram arrays so the video pipeline can read the same storage the CPU writes without a second copy.
- `rtl/bjtwin/nmk_irq_hacky.sv` — cactus's fixed-scanline IRQ generator, including HOLD_LINE-style level-held-until-acknowledged semantics matching MAME's M68K interrupt model. Refactored to consume the shared `video_timing` raster counter rather than keeping its own.
- `rtl/bjtwin/video_timing.sv` — shared 512x278 raster counter (hcount/vcount/line_start/hblank/vblank), one source of truth for both the IRQ generator and the video pipeline.
- `rtl/bjtwin/video_bjtwin.sv` — the video pipeline: tile pixel decode (`gfx_8x8x4_packed_msb`) as a pure per-pixel combinational function, sprite pixel decode (`gfx_8x8x4_col_2x2_group_packed_msb`) via a budget-walked draw FSM into a double-buffered sprite plane, palette RGB decode (`RRRRGGGGBBBBRGBx`, one tap for the tile plane and a second dedicated to the sprite plane's read-time decode), and a 256-slot sprite-RAM snapshot per the DMA trigger — see "Real-time scanline-synchronized render architecture" below. Exposes a `pixel(x,y)` readback port mirroring MAME's `screen:pixel()`.
- `tools/mkrom.py` — reconstructs a `$readmemh` ROM image from a split MAME romset zip's `ROM_LOAD16_BYTE` pair, reusable for every other 68000 program ROM in this driver.
- `tools/mkgfxrom.py` — the graphics-ROM equivalent: byte-addressed `$readmemh` images from either a straight concatenation (`fgtile`/`bgtile`) or a `ROM_LOAD16_BYTE` interleave (`sprites`), with multi-zip search support for split-romset parent merging (needed for `cactus`'s `fgtile`, which lives only in `sabotenb.zip`).
- `sim/rtl/bjtwin/tb_bjtwin.cpp` + `Makefile` — Verilator testbench: runs the real `cactus` ROM, logs every completed bus write cycle ('B' lines) and a CRC32 checksum per rendered frame ('F' lines, computed identically to `sim/oracle/trace.lua`'s pixel loop), plus a PPM dump per frame for visual debugging.
- `sim/oracle/debug_capture.py` — an alternative MAME oracle-capture tool using debugger watchpoints (`wpset` + an auto-continuing `printf`-and-`g` action, run via `-debug -debuglog`) instead of the Lua bus tap, for whenever the tap's reliability is in doubt (see "Sprite rendering verification" below for why that's a real concern, not hypothetical) — emits the same nmktrace `'B'` line grammar, so it's a drop-in alternative source for `sim/compare/state_diff.py`. Also dramatically faster than the Lua tap for heavily-written regions (the entire 64KB mainram range captures in under 3 seconds, versus the Lua tap failing to get through 30,000 cycles of a comparable range in 280 seconds).

## Documented simplifications (see `bjtwin_core.sv` header for the authoritative list)

- `DTACKn` is 0-wait-state for normal bus cycles (`ASn` directly) but **not** during interrupt-acknowledge cycles, where only `VPAn` may assert (see "Sprite rendering verification" below for why this distinction turned out to matter) — fine for `$readmemh` ROM/BRAM in simulation; real SDRAM-backed hardware will need genuine wait-state generation later.
- OKI chip read/write ports are stubs (`8'hFF` on read, writes accepted but discarded) — flagged as the first thing to suspect if a future full-boot trace comparison diverges partway through (a busy-wait on an OKI status bit would show up as a hang or wrong branch).
- IN0/IN1/DSW1/DSW2 tied to fixed idle values (`16'hFFFF`) rather than real HPS_IO input — matches MAME's default "nothing pressed" boot-time state, not yet wired to real controller input.

## Verification result

**All 1617 real bus-write events in the captured oracle trace matched exactly** (address, data, byte-mask), in order, against RTL simulation of the actual `cactus` ROM — with a **perfectly constant +57 cycle offset** across the entire trace (every single event, no exceptions; `oracle_diff.py`'s new constant-offset diagnostic confirmed this automatically). That constant offset is consistent with a fixed reset/vector-fetch latency difference between fx68k's exact reset sequence and MAME's own 68000 core's reset sequence — not a functional divergence, since the *relative* timing between every subsequent access is cycle-for-cycle identical.

```
$ make -C sim/rtl/bjtwin check   # (after `make rom` with mame_roms/cactus.zip present)
...
MATCH: all 1617 events identical (cycle_tolerance=57)
```

This is real evidence that: the ROM extraction/byte-ordering (`tools/mkrom.py`) is correct, the address decode in `bjtwin_core.sv` is correct, fx68k executes this real 68000 program identically to MAME's reference core, and the reset/boot sequence is functionally correct — for the boot-time palette-clear and tilemap-VRAM-init code this trace window covers.

### Why the oracle trace only covers ~1618 events (a known tooling limitation, not a game-boot failure)

Installing a Lua bus tap over a wide address range (`0x80000-0xFFFFF`, covering I/O+palette+VRAM+all of work RAM) makes MAME's memory dispatcher fall back to a much slower path for the *entire* tapped range, not just the specific bytes actually being tapped — confirmed by testing: a 256-byte window traces near-instantly, but the full 0x80000-byte window failed to complete even a single frame within a 280-second budget. Plain (untapped) `cactus` boots and runs at 2800%+ realtime speed, so this is purely a Lua-tap-overhead artifact, not an emulation hang. The 1617-event trace used above is the real (if truncated) capture from that wide-range attempt — genuine data, just cut off by the timeout rather than reaching a natural stopping point. Recapturing a longer/full-boot oracle trace, if needed later, will need either a narrower per-region tracing strategy or patience with a much longer capture budget.

## Video pipeline

### Former architecture gap: not real-time synchronized (resolved, see below)

`video_bjtwin.sv`'s render FSM used to compute an entire frame procedurally (walk every tile, then every sprite, into a 384x224 framebuffer) triggered by the sprite-DMA trigger, rather than rendering in real time synchronized to `video_timing`'s raster position. That was a deliberate initial choice — prove the decode/compositing algorithms correct first — but it had a real consequence for oracle comparison: the render took on the order of one real frame period's worth of `clk_sys` cycles to complete (confirmed: successive `frame_done` pulses landed ~177,920 CPU cycles apart, matching one real 56Hz frame's CPU-cycle budget almost exactly), but wasn't *phase-aligned* to MAME's actual frame boundaries — the first rendered frame completed about 1.8 frame-periods after reset, not 1.0. So "our frame N" and "MAME's frame N" weren't guaranteed to represent the same game instant, even once every algorithm was correct. Comparing frame-indexed CRC32s across that architecture gap wasn't a valid apples-to-apples test at the time — closed out via a *state* comparison (palette/VRAM/sprite-RAM contents) instead of rendered pixels for that milestone, and later replaced entirely by the real-time architecture described in "Real-time scanline-synchronized render architecture" below, which eliminates the phase-alignment problem at its source (`frame_done` is now tied directly to real raster position, landing exactly on frame boundaries).

### What's independently verified correct

Every formula in `video_bjtwin.sv` was checked against the actual MAME source, not assumed — including one place a wrong assumption would have silently produced backwards pixels:

- **Palette decode** (`RRRRGGGGBBBBRGBx`): bit extraction confirmed against `emupal.cpp`'s `RRRRGGGGBBBBRGBx_decoder`; the 5-to-8-bit channel expansion confirmed against `palette.h`'s `palexpand<5>` (`(bits<<3)|(bits>>2)`, i.e. `{v, v[4:2]}` — exactly what's implemented).
- **Tile pixel bit-ordering**: initially assumed pixel value = nibble read directly (`hi_nibble` = first pixel). Rechecked against `drawgfx.cpp`'s `gfx_element::decode()` — plane index 0 maps to the pixel value's **MSB**, not LSB (`planebit = 1 << (planes-1)`, decrementing), combined with `readbit()`'s MSB-first byte convention — and worked through by hand for both pixels of a byte. The two effects cancel out for this specific layout (`gfx_8x8x4_packed_msb`'s `planeoffset={0,1,2,3}`), landing back on "pixel0 = hi nibble, pixel1 = lo nibble" — confirming the original implementation was right, but only after checking, not assuming.
- **COL-scan tilemap addressing**: `index = col*32+row` confirmed against `tilemap.cpp`'s `tilemap_t::scan_cols()` (`col * num_rows + row`).
- **Graphics ROM extraction**: `cactus_fgtile.hex`'s CRC32 checked against the driver's own expected CRC (`eb7bc99d`) — exact match.

### End-to-end sanity check

With every formula individually verified, the natural next check was whether they combine correctly. `cactus`'s first ~2048 tilemap writes and ~1024 palette writes turn out to be a uniform one-time boot-time clear (every tilemap word = `0x0020`, i.e. tile 32, color 0 — confirmed by grepping the RTL's own bus-write trace) — and tile 32 in the actual ROM data is genuinely all `0xFF` bytes (checked directly), meaning every pixel should decode to color index 15. Palette entry 15 (`0x0080`) decodes by hand to RGB `(0, 0, 132)`. The RTL's own rendered PPM output is a uniform `(0, 0, 132)` navy-blue field, pixel-exact — and independently, `(B,G,R)*384*224` fed through Python's `zlib.crc32` for that exact color reproduces the RTL's own logged frame CRC (`0x24cb4dc9`) exactly. Every stage — ROM data → tile decode → palette decode → framebuffer → CRC32 — is demonstrated internally consistent and traceable to source-verified formulas.

### State comparison: closing the gap (`sim/compare/state_diff.py`)

The rendered frame CRC32 doesn't match any of 40 captured MAME oracle frame checksums, and the "known architecture gap" above meant frame-indexed CRC comparison couldn't settle whether that's a phase-alignment artifact or a real content bug. Rather than fixing the render architecture first, the direct question was answered instead: **is the actual data our renderer reads (palette RAM, tilemap VRAM) identical to what real MAME's CPU wrote?** This sidesteps rendering-timing entirely — a CPU write to RAM is a discrete bus event independent of any frame boundary, so replaying a bus-write trace into a memory image and diffing it is valid regardless of phase alignment.

`sim/compare/state_diff.py` replays the `'B ... w ...'` events from two nmktrace files into word-addressed memory images (respecting byte masks, like real hardware write-enables) and diffs the final state. Run against a fully-captured MAME oracle trace of the palette region (a *narrow* address-range capture, since — as with the CPU trace — tapping wide ranges is too slow; narrow single-region captures complete in ~2 seconds) and the RTL's own trace over the same content:

```
$ python3 sim/compare/state_diff.py sim/oracle/traces/cactus_palette.trace sim/rtl/bjtwin/cactus_rtl.trace --addr-lo 0x88000 --addr-hi 0x887ff
oracle:    ... (1024 writes, 1024 unique addresses)
candidate: ... (1024 writes, 1024 unique addresses)
MATCH: all 1024 addresses identical final state
```

**Palette: 1024/1024 addresses match exactly — complete coverage, zero mismatches.** A matching `bgvram` capture (`0x9C000-0x9DFFF`) hit the same Lua-tap-overhead wall as the CPU trace before completing (1706/2048 addresses captured before timeout, even at a 280-second budget) — but of the 1706 addresses MAME's oracle did capture, **all 1706 match the RTL exactly, zero value mismatches**; the remaining 342 are absent from the oracle capture, not divergent.

Combined with the independently-verified decode formulas above, this closes the gap: the palette and tilemap VRAM content feeding the renderer is proven bit-exact against real MAME, and the formulas turning that data into pixels are proven bit-exact against MAME's source — so the rendered output for this screen state (the boot-time solid navy-blue clear) is correct. The earlier frame-CRC mismatch is now confidently attributable to the render FSM's phase-alignment gap, not a data or decode bug.

### A detour that ruled out three plausible causes, and one important architectural finding

Before landing on the state-comparison approach above, a more direct question was chased first: does MAME's CPU ever reach the sprite-RAM-clear code the RTL was seen executing around CPU cycle ~1.2M? Narrow oracle captures of the sprite-RAM region (`0xF8000-0xF8FFF`) showed **zero** CPU bus writes there even after 60 real frames (~10.68M cycles) of MAME execution — initially read as a real control-flow divergence, which prompted checking (and ruling out) three candidate causes directly against source: the stubbed OKI ports (MAME's own oracle shows **zero** OKI-port accesses at all in this window, so the stub isn't being exercised yet), the fixed `0xFFFF` DSW/input default (`sabotenb`'s actual `PORT_DIPNAME` defaults sum to exactly `0xFF` for both DSW1 and DSW2 — the stub is correct), and the `mainram_strange_w` byte-mirroring quirk flagged in earlier Tier 0 research (`bjtwin_map` uses plain `.ram()` for mainram — that quirk doesn't apply to this hardware family at all).

The actual explanation turned out to be a wrong premise, not a bug: `nmk16_hacky_scanline()`'s sprite-DMA trigger (`nmk16.cpp:4496-4497`) calls `sprite_dma()` directly as a **C++ function call from a scanline timer**, copying `mainram` into an internal `m_spriteram_old` buffer — real hardware DMA behavior modeled as a host-memory copy, not a 68000 bus transaction. It would never appear in a `:maincpu` bus trace regardless of whether or when it runs. So "zero spriteram writes in the oracle" doesn't indicate anything wrong — it's the expected non-signature of an operation that was never going to be bus-visible. Important for future sprite-engine verification: sprite buffering can't be checked via CPU-bus state comparison the way palette/VRAM can; it needs either a dedicated Lua hook exposing that internal buffer, or waiting until the render FSM is real-time-synchronized and comparing pixels/frame CRCs directly.

## Sprite rendering verification

Per the plan above, the `sprite_dma()` finding meant sprite verification needed a different tool: PC-tracing, to check the CPU's own control flow (not just its RAM writes) against MAME over a much longer window than the 1618-event bus trace could cover.

### New tooling: PC tracing without bus-tap overhead

`bjtwin_core.sv` now exposes `dbg_fc0/fc1/fc2` (the 68000 function-code lines) instead of the placeholder `dbg_pc`/`dbg_pc_valid_pulse` outputs it had before. fx68k has no direct PC pin, but during an instruction-fetch bus cycle (`FC2:0 = 010` or `110`, i.e. `FC1=1, FC0=0` regardless of `FC2`) the address bus **is** the fetch address — `tb_bjtwin.cpp` tracks this and samples it once per fixed 177,920-cycle period (one real frame, independent of the video FSM's own timing) into `'R ... PCSAMPLE ...'` trace lines.

On the MAME oracle side, PC snapshots piggyback on the existing frame-checksum path (`NMKTRACE_REGS=PC`), which is cheap since it doesn't need bus tapping — but getting a *clean* run needed two real fixes to the capture recipe, both worth recording since they'll recur:
- `install_read_tap(0, 0, ...)` throws — MAME requires a tap range with the low bit of the end address set (e.g. `0-1`, not `0-0`); the exception aborts the whole script run, silently leaving a stale/wrong trace file behind if not checked for.
- Env-var overrides must be passed via `env VAR=val VAR2=val2 command`, not interpolated across a `cd X && VAR=val command` compound line — the latter silently dropped the override in one case during this investigation (a capture that was supposed to use a 1-byte tap range instead used MAME's full default range and only was caught because the resulting trace's header didn't match what was requested). Any oracle capture whose header doesn't show the exact range/flags requested should be treated as suspect and re-run explicitly with `env`.

### Finding, then retraction: the "loop-termination bug" was a false positive

PC samples showed the CPU sitting in a tight wait loop (`0xA85A-0xA86A`) for many frames on both sides, then — decisively — **both MAME and the RTL leave that loop at exactly frame 13** (cycle 2,490,880), landing on nearly identical subsequent addresses. Strong, direct evidence main-line CPU control flow is correct through at least frame 15.

Separately, the RTL was seen writing a `0xFFFF`-then-`0x0000` test pattern into the sprite-RAM sub-region (`0xF8000+`) starting at cycle 1,213,735, as the tail end of a general mainram POST-test sweep starting at `0xF0000`. A real MAME bus-tap capture of that exact region showed **zero** writes there through 60 real frames — and bisecting with several more narrow bus-tap captures (each confirming the same 72-cycles/word rate right up to the boundary) appeared to show MAME's sweep stopping cleanly between `0xF0F80` and `0xF0FC0`, a small fraction of the full 32,768-word sweep. This was written up as **a real, confirmed CPU-side control-flow divergence** and a fix was even attempted (see below).

**That conclusion was wrong.** Using MAME's actual debugger (`-debug -debuglog`, not the Lua `-autoboot_script` bus-tap mechanism) to instruction-trace the loop directly showed it running its full, exact intended course — **32,760 iterations**, precisely `(0xFFFF0-0xF0000)/2` — and exiting normally, never touching the error-handler path. A `wpset 0xf8000,0x1000,w` debugger watchpoint over the whole sprite-RAM sub-region, hit repeatedly (each `go` after a stop resumes to the next hit), then produced a clean, enumerated, unambiguous sequence:

```
Stopped at watchpoint 1 writing FFFF to 0F8000 (PC=0000A856)
Stopped at watchpoint 1 writing 0000 to 0F8000 (PC=0000A85E)
Stopped at watchpoint 1 writing FFFF to 0F8002 (PC=0000A856)
Stopped at watchpoint 1 writing 0000 to 0F8002 (PC=0000A85E)
Stopped at watchpoint 1 writing FFFF to 0F8004 (PC=0000A856)
```

This matches the RTL's own write pattern address-for-address, value-for-value, and even PC-for-PC (`A856` for the `FFFF` write, `A85E` for the `0000` write, exactly the loop body disassembled above) — about as direct a confirmation as this project's tooling can produce that real MAME's CPU **does** write to the sprite-RAM region during this sweep, contradicting every one of the earlier bus-tap-based "zero writes" results. Cross-validated the debugger method itself against a case the Lua tap *did* correctly capture (`0xF0C00`) to rule out the debugger being the unreliable one — it agreed exactly.

**Conclusion: the Lua `install_write_tap` bus-tap mechanism has a real, reproducible blind spot for at least part of the plain `.ram()`-declared mainram region** (writes past some point silently never reach the tap callback, even though they genuinely happen) — this is a MAME/Lua tooling limitation, not a CPU or RTL bug. The RTL's behavior (sweeping the full mainram range, including sprite RAM) is very likely **correct**, matching real hardware. The exact mechanism of the Lua tap's blind spot wasn't root-caused (plain `.ram()` vs. `.ram().w(handler)` regions was one hypothesis, but doesn't fully fit — `0xF0C00` and `0xF0F80`, both still plain mainram, tapped correctly) — flagged as a real limitation to keep in mind for any future oracle capture that relies on bus-tapping large or heavily-written RAM regions. **When a Lua-tap-based "zero events" result seems surprising, cross-check it with a MAME debugger watchpoint (`wpset <addr>,<len>,w`, run with `-debug -debuglog`, read the hit message from `debug.log`) before trusting it** — that's now the more reliable ground truth.

### A related, real bug found and fixed along the way (kept — it's a genuine improvement, independent of the retracted finding above)

While investigating, a second, independently-real issue was found and fixed: `DTACKn` was tied straight to `ASn`, meaning it also asserted during interrupt-acknowledge cycles — alongside `VPAn`, which should be the *only* signal driving autovectoring for this design (no real vectored-interrupt device exists on this bus). With both asserted, fx68k could read the unmapped-address default (`16'hFFFF`) off the data bus as if it were a supplied vector number instead of using autovectoring, occasionally landing on a slightly wrong exception-handler address. Fixed: `DTACKn = ASn | iack_cycle`, so only `VPAn` is asserted during an IACK cycle. Confirmed via the PC trace that this measurably changed fine-grained execution, and confirmed via a full CPU-trace regression run that it didn't break the already-proven 1617-event exact match. Kept as a real correctness fix, independent of the now-retracted "loop-termination bug" it was originally chasing.

### What this means for sprite verification, and next steps

Good news: sprite verification is **not** blocked by a CPU bug after all. The RTL's mainram sweep (including its pass through sprite RAM) matches what real MAME actually does.

### Automated: `sim/oracle/debug_capture.py`, and a clean sprite-RAM state-comparison result

Built the debugger-watchpoint method from the manual investigation above into a real, reusable tool: `sim/oracle/debug_capture.py` generates a `.debugscript` (`wpset <lo>,<len>,w,1,{printf "W %04X=%04X\n",wpaddr,wpdata ; g}` — the auto-continuing action form, found to work cleanly after the manual `; g` experiment above), runs MAME with `-debug -debuglog` until a caller-specified stop `bp`, and parses `debug.log` into the same nmktrace `'B'` line grammar the rest of the harness uses — a drop-in alternative oracle source for `sim/compare/state_diff.py` wherever the Lua bus tap's reliability is in doubt. It's also *dramatically* faster than the Lua tap for hot regions: the full mainram range (0x10000 bytes) captured in under 3 real seconds, versus the Lua tap's inability to get through even 30,000 cycles of a comparable range in 280 seconds.

Result, run against the RTL's own trace via `sim/compare/state_diff.py`:

```
$ python3 sim/oracle/debug_capture.py --game cactus --rompath mame_roms \
    --addr-lo 0xf8000 --addr-hi 0xf8fff --stop-pc 0xaa66 \
    --out sim/oracle/traces/cactus_spriteram_debug.trace
[debug_capture] wrote 4342 write events to ...

$ python3 sim/compare/state_diff.py sim/oracle/traces/cactus_spriteram_debug.trace \
    sim/rtl/bjtwin/cactus_rtl.trace --addr-lo 0xf8000 --addr-hi 0xf8fff
oracle:    ... (4342 writes, 2048 unique addresses)
candidate: ... (4342 writes, 2048 unique addresses)
MATCH: all 2048 addresses identical final state
```

**Sprite-RAM: complete, exact match — same write count, same address count, identical final state, for the whole 4KB sub-region.** This closes out the task properly (not just the 5 manually-inspected events from the retraction above).

For extra confidence, also ran the same comparison over the *entire* mainram region (0xF0000-0xFFFFF, 32,768 words): 32,729/32,763 addresses matched exactly (99.9%). The 34 mismatches are all clustered in `0xF9000` and `0xFF000-0xFFFFE` — the latter is right where the stack lives (initial SP is `$000FFFF0`, per the boot ROM's first vector-table word) — and every mismatched address had been written **2 to 19 times** within the capture window (confirmed by checking the oracle trace directly), unlike the sprite region's clean once-each pattern. This is a capture-length artifact, not a divergence: the RTL testbench runs a fixed clk_sys cycle budget, while the oracle capture stops exactly at a PC breakpoint, so the two runs end at slightly different instants — for a frequently-rewritten scratch/stack location, "final value at the moment I stopped looking" can legitimately differ between two otherwise-identical executions.

Also redid the earlier (Lua-tap, incomplete-coverage) VRAM comparison with `debug_capture.py`: now a **complete match, all 2048/2048 addresses**, closing the gap the Lua tap's overhead had left at 1706/2048.

Re-running the palette comparison the same way surfaced a clean, well-understood example of exactly that capture-length artifact: the oracle (1024 writes, no repeats at all) shows **zero** evidence of any second pass over palette, while the RTL (1536 writes — 1024 unique addresses plus a partial second pass over roughly the first 512) had already started overwriting the earliest entries with `0x0000` by the time it stopped. Checked directly: the RTL's last palette write lands at cycle 2,831,381, right before its fixed 3M-cycle budget ends — and PC-sample data from the "Finding" section above shows MAME's own PC is still transiting `ae3c`→`aa68` (i.e., approaching but not yet at `aa66`) around cycle 2.67M-2.85M, meaning the oracle capture's `aa66` breakpoint fires *before* this second palette pass ever starts in that run, while the RTL — not PC-bounded, just cycle-bounded — keeps going long enough to begin it. Same code, same behavior, different stop instant. The sprite-RAM region, tilemap VRAM, and (up to this well-explained residual) the general mainram data path are all independently confirmed correct.

### Correction: the "cactus is missing ROMs" caveat below was a false alarm

The earlier note in this doc (and in `docs/sim-harness.md`) worrying that `mame_roms/cactus.zip` was missing `i03.bin`/`s-01.bin`/`s-02.bin` was wrong — it didn't account for MAME's **split romset** convention. `cactus`'s parent is `sabotenb` (`mame -verifyroms` reports `romset cactus [sabotenb] is good`), and MAME transparently merges files from the parent zip by CRC when the clone's own zip doesn't contain them — confirmed directly with `-verbose`: loading `cactus` opens both `cactus.zip` and `sabotenb.zip`, and `sabotenb.zip` contains same-sized, presumably CRC-matching files (`ic35.sb3` = 0x10000 bytes matching `i03.bin`'s fgtile region; `ic27.sb7`/`ic30.sb6` = 0x100000 bytes each matching `s-01.bin`/`s-02.bin`'s OKI regions) under different filenames. **The romset is genuinely complete** — see the full completeness audit below, done properly this time against all 101 romsets.

## sprite_dma() buffer verification

`sprite_dma()`'s output (`m_spriteram_old`) is a host-memory C++ array copy from a scanline timer callback, so — as flagged above — it's invisible to both the Lua bus tap and `debug_capture.py`'s debugger watchpoints; neither ever sees it as a `:maincpu` bus transaction. Closing this gap needed direct save-state item access instead:

- **MAME side**: `sim/oracle/trace.lua` extended with `NMKTRACE_ITEM_INDEX`/`NMKTRACE_ITEM_LABEL` env vars, using `emu.item(index):read(i)` — a mechanism that bypasses bus transactions entirely by reading the save-state system's own view of driver-private memory. Found the index with a throwaway `for name,idx in pairs(manager.machine.devices[":"].items) do print(name,idx) end` scan: `0/m_spriteram_old -> 6` (`size=2 count=2048`, i.e. 2048 u16 words = 4KB, matching the sprite RAM's own size). Emits one `'I <cycle> <frame> <hex...>'` line per frame.
- **RTL side**: `rtl/bjtwin/video_bjtwin.sv` already had an internal `sprite_snap [0:2047]` array (the RTL's own DMA'd draw buffer, populated on `sprite_dma_trigger` the same way MAME's `sprite_dma()` populates `m_spriteram_old`) but no way to read it from outside the module. Added a `dbg_snap_addr`/`dbg_snap_data` combinational readback port, threaded through `bjtwin_core.sv`'s top-level port list the same way `rd_x`/`rd_y`/`rd_rgb` already were. `sim/rtl/bjtwin/tb_bjtwin.cpp` scans all 2048 words through that port right after each `frame_done` pulse and writes an `'I'` line via a new `NmkTraceWriter::item()` method (added to `sim/rtl/common/nmktrace.h`) — the identical line grammar the Lua side emits, so the two traces diff directly.

Result — captured 15 rendered RTL frames (`cactus_rtl.trace`) and 16 MAME frames (`cactus_spriteram_old.trace`, `NMKTRACE_ITEM_INDEX=6 NMKTRACE_MAX_FRAMES=16`), then compared every RTL frame's full 2048-word dump against the corresponding MAME frame:

```
RTL frame N  <->  MAME frame N+1   (fixed one-frame offset — the RTL's
                                     procedural render FSM needs one extra
                                     frame at boot before its first
                                     frame_done pulse, vs. MAME's real-time
                                     first frame; a bookkeeping offset, not
                                     a content divergence)

matches=15 mismatches=0   (every one of the 15 RTL frames, all 2048 words each)
```

**Complete, exact match — the RTL's `sprite_snap` buffer is bit-for-bit identical to MAME's `m_spriteram_old` for the entire captured run**, including the first frame with real content (word[240]/[241]=`0101`/`007f`, word[248]/[249]=`0101`/`007f` — sprite entries 30 & 31, visible flag set, W=15/H=7 large sprites — identical hex in both traces). This closes the last of the three internal-state verification gaps (CPU/mainram, tilemap VRAM, sprite DMA buffer); only frame-level video *rendering* (pixel output, gated on the real-time-synchronization work below) remains unverified end-to-end.

## Real-time scanline-synchronized render architecture

`video_bjtwin.sv`'s procedural per-frame FSM (walk every tile then every sprite into a shared framebuffer, unbounded number of cycles, triggered once by `sprite_dma_trigger`) is gone, replaced with an architecture actually driven by real timing rather than by "however long the sweep happens to take":

- **Tilemap: a pure per-pixel combinational function**, not a sweep. Checking `nmk16_v.cpp` confirmed MAME never models a tile-fetch bandwidth limit for this family (unlike sprites, there's no clock-budget/drop-out logic for tiles at all) — so there's nothing to synchronize to a raster clock, and the old FSM's exhaustive walk over all 64x32 tile positions every frame (most of them off-screen) was pure waste. Tile decode is now `bgvram_addr`/`palette_addr` driven directly, combinationally, by `rd_x`/`rd_y` — the same chain a real hardware raster fetcher would run off a live `hcount`/`vcount` at one pixel per pixel-clock.

  This rewrite also fixed a real bug the old sweep had: `nmk16_v.cpp` confirms the tilemap is a genuinely toroidal 64x32-tile (512x256px) surface (`tilemap_create(..., 8, 8, 64, 32)`, and `bjtwin_scroll_w`'s `set_scrolly(0, -data)` — MAME's tilemap system always wraps scroll). The old code walked *source* tile position → screen position and only kept results landing in the visible window, without ever wrapping the source row — for `scroll_y_reg` past roughly 32, most of the screen got zero tile coverage that frame (stale/undefined pixels) instead of wrapped tile content. Inverting the direction (screen position → source tile position via mod-256 Y / mod-512 X, confirmed algebraically equivalent to the old formula for the range it *did* cover correctly) gives full coverage for any scroll value. The captured verification trace stayed near `scroll_y_reg==0` throughout, so this never invalidates anything already verified — it closes a gap verification never reached.

- **Sprites: a double-buffered plane**, since sprites are the part MAME *does* model with real per-frame bandwidth limits (`MAX_SPRITE_CLOCK`/`m_max_sprite_clock`, silently dropping late sprites). The budget-walked draw FSM (unchanged cost accounting from the already-oracle-verified version) now writes into whichever of two `SCREEN_W*SCREEN_H`-entry planes isn't currently being displayed, triggered by `sprite_dma_trigger` same as before, and the display-side pointer only swaps atomically once a full pass completes — so a redraw in progress can never tear the frame currently being read. Each plane stores an 11-bit `{valid, palette_index}` entry per pixel rather than pre-decoded RGB, and decodes from a live third palette tap (`spr_palette_addr`/`spr_palette_data`, added to `bjtwin_core.sv`'s palette array alongside the existing CPU/tile-plane taps) at *read* time — matching MAME's own model, where `draw_sprites()` reads whatever palette content exists at `screen_update()` time, decoupled from when the sprite position/tile data was DMA'd. This also means the draw FSM no longer touches the palette at all during drawing (the pen==15 transparency test only needs the sprite ROM's own pixel value — confirmed via `nmk16spr.cpp`'s `drawgfx(...,15)` transpen call), removing what would otherwise have been a port-contention hazard against the tile plane's own palette reads.

- **`frame_done` moved to `bjtwin_core.sv`** and is now generated directly off the shared `video_timing` raster counter (`vt_line_start && vt_vcount==0`) instead of waiting on FSM completion. Rebuilding and rerunning immediately validated this end to end: successive `frame_done` pulses land exactly 177,920 CPU cycles apart — bit-for-bit the same period `tb_bjtwin.cpp`'s independent PC-sampling code has used all along (`FRAME_PERIOD_CPU_CYCLES`), confirming `frame_done` now tracks the true 56.22Hz raster period rather than an FSM-dependent approximation. One real (if minor) bug found and fixed while validating this: `bjtwin_core.sv`'s `pix_div` pixel-clock-enable counter was free-running through reset while `video_timing`'s `hcount` was reset-pinned at 0, so the first `ce_pix` pulse after reset lifted could catch a stale `hcount==0` and fire a spurious extra `frame_done` right at boot (a duplicate frame 0/1, both identical CRCs — cosmetic, but real). Fixed by reset-gating `pix_div` too.

**Re-verification after the rework**: rebuilt and reran the full sprite_dma() buffer comparison above — **still 16/16 exact match, and the fixed one-frame counting offset from before is now gone entirely** (RTL frame N now lines up 1:1 with MAME frame N, no `+1` needed), a direct consequence of `frame_done` now tracking real raster time. Also spot-checked the render output itself: the boot-time uniform navy-blue backdrop documented in "End-to-end sanity check" above (frame CRC `0x24cb4dc9`) reappears identically across frames 1-15 of the rebuilt trace — the new combinational tile-decode path reproduces the exact previously-verified pixel content for the one case already checked by hand, while now doing so through a synthesizable, bandwidth-respecting formula instead of an unbounded procedural sweep.

Still open: this closes the *architecture* gap (real-time timing model, tear-free double buffering, the wraparound bug), not the *pixel-content* gap — frame-CRC comparison against MAME's actual rendered output still needs real gameplay content to be reachable (see next steps) and hasn't been attempted yet, since the boot-time content captured so far is a single uniform color MAME's own oracle trace was never compared against pixel-for-pixel either.

## Next steps

1. Exercise the untested decode paths once real gameplay content is reachable: tile bank-select (bit 11, addressing `bgtile` not `fgtile`), non-zero tile colors, non-zero scroll (now that the wraparound fix makes this safe to exercise), and multiple concurrent sprites.
2. Direct frame-CRC comparison against a MAME oracle trace, now that the render architecture is real-time/synchronized and the underlying state (palette/VRAM/sprite-DMA) is independently trusted — the remaining risk is purely in the pixel-decode/compositing formulas, already source-verified but never checked against a real MAME rendered frame pixel-for-pixel.
3. `nmk112` + 2x jt6295 functional audio integration (currently stubbed).
4. Real `nmk_irq` dual-PROM state machine for `bjtwinp`/`nouryokup` (cactus-only `nmk_irq_hacky` doesn't cover them).
5. `cactus`'s scrambled graphics ROMs (see "Hardware spec" above) need the fixed bitswap applied — either in `tools/mkgfxrom.py` or at `.mra` build time — before `bjtwinp`/`nouryokup` (which use unscrambled ROMs) and `cactus` can share one `.rbf`. Not yet needed for the current milestone since `cactus`'s ROMs were used as-is (scrambled) and the game still booted and rendered something coherent — worth understanding why before assuming it doesn't matter.
6. Extend the CPU-correctness oracle trace further into the boot sequence using `debug_capture.py` (proven far faster than the Lua-tap-overhead-limited approach) to validate beyond the first ~1618 events, and add read-cycle coverage (this window happened to be write-only). Given `debug_capture.py`'s speed, revisiting the *palette*/*VRAM* comparisons with it too (the Lua tap left VRAM's coverage incomplete at 1706/2048) is now cheap and would close that last small gap.
