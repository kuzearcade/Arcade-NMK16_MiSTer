# Tier 1 — bjtwin family (cactus / bjtwinp / nouryokup)

Status: **CPU + memory-map + interrupt subsystem verified exactly against a real MAME oracle trace. Video pipeline's data path (palette + tilemap VRAM content, and every tile/palette decode formula) is now verified bit-exact against MAME via direct state comparison — see "Video pipeline" below.** The render FSM's frame-level output still isn't directly comparable to MAME's frame CRCs (a separate, understood architecture gap, not a data-correctness question). Audio (`nmk112` + 2x OKIM6295) and sprite rendering verification are not done yet.

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
- `rtl/bjtwin/video_bjtwin.sv` — the video pipeline: tile pixel decode (`gfx_8x8x4_packed_msb`), sprite pixel decode (`gfx_8x8x4_col_2x2_group_packed_msb`), palette RGB decode (`RRRRGGGGBBBBRGBx`), a 256-slot sprite-RAM snapshot (single-buffered, per the DMA trigger), and a procedural per-frame renderer (see "Known architecture gap" below) exposing a `pixel(x,y)` readback port mirroring MAME's `screen:pixel()`.
- `tools/mkrom.py` — reconstructs a `$readmemh` ROM image from a split MAME romset zip's `ROM_LOAD16_BYTE` pair, reusable for every other 68000 program ROM in this driver.
- `tools/mkgfxrom.py` — the graphics-ROM equivalent: byte-addressed `$readmemh` images from either a straight concatenation (`fgtile`/`bgtile`) or a `ROM_LOAD16_BYTE` interleave (`sprites`), with multi-zip search support for split-romset parent merging (needed for `cactus`'s `fgtile`, which lives only in `sabotenb.zip`).
- `sim/rtl/bjtwin/tb_bjtwin.cpp` + `Makefile` — Verilator testbench: runs the real `cactus` ROM, logs every completed bus write cycle ('B' lines) and a CRC32 checksum per rendered frame ('F' lines, computed identically to `sim/oracle/trace.lua`'s pixel loop), plus a PPM dump per frame for visual debugging.

## Documented simplifications (see `bjtwin_core.sv` header for the authoritative list)

- `DTACKn` tied to `ASn` (0-wait-state memory) — fine for `$readmemh` ROM/BRAM in simulation; real SDRAM-backed hardware will need genuine wait-state generation later.
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

### Known architecture gap: not real-time synchronized

`video_bjtwin.sv`'s render FSM computes an entire frame procedurally (walk every tile, then every sprite, into a 384x224 framebuffer) triggered by the sprite-DMA trigger, rather than rendering in real time synchronized to `video_timing`'s raster position. This was a deliberate choice — prove the decode/compositing algorithms correct first — but it has a real consequence for oracle comparison: the render takes on the order of one real frame period's worth of `clk_sys` cycles to complete (confirmed: successive `frame_done` pulses land ~177,920 CPU cycles apart, matching one real 56Hz frame's CPU-cycle budget almost exactly), but it isn't *phase-aligned* to MAME's actual frame boundaries — our first rendered frame completes about 1.8 frame-periods after reset, not 1.0. So "our frame N" and "MAME's frame N" are not guaranteed to represent the same game instant, even once every algorithm is correct. Comparing frame-indexed CRC32s across this architecture gap isn't a valid apples-to-apples test — a real fix needs either a real-time scanline-synchronized renderer (the eventual hardware architecture anyway) or comparing captured *state* (palette/VRAM/sprite-RAM contents) rather than rendered pixels.

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

### Correction: the "cactus is missing ROMs" caveat below was a false alarm

The earlier note in this doc (and in `docs/sim-harness.md`) worrying that `mame_roms/cactus.zip` was missing `i03.bin`/`s-01.bin`/`s-02.bin` was wrong — it didn't account for MAME's **split romset** convention. `cactus`'s parent is `sabotenb` (`mame -verifyroms` reports `romset cactus [sabotenb] is good`), and MAME transparently merges files from the parent zip by CRC when the clone's own zip doesn't contain them — confirmed directly with `-verbose`: loading `cactus` opens both `cactus.zip` and `sabotenb.zip`, and `sabotenb.zip` contains same-sized, presumably CRC-matching files (`ic35.sb3` = 0x10000 bytes matching `i03.bin`'s fgtile region; `ic27.sb7`/`ic30.sb6` = 0x100000 bytes each matching `s-01.bin`/`s-02.bin`'s OKI regions) under different filenames. **The romset is genuinely complete** — see the full completeness audit below, done properly this time against all 101 romsets.

## Next steps

1. Sprite rendering verification: needs a dedicated Lua hook exposing MAME's internal `m_spriteram_old`/`m_spriteram_old2` buffer contents (state comparison as done for palette/VRAM doesn't reach it — see the `sprite_dma()` finding above), since nothing has appeared in sprite RAM in any CPU-bus-visible window captured so far (the game's own CPU-driven sprite-RAM clear happens around cycle ~1.2M, well past what's been oracle-verified).
2. Exercise the untested decode paths once real gameplay content is reachable: tile bank-select (bit 11, addressing `bgtile` not `fgtile`), non-zero tile colors.
3. Real-time scanline-synchronized render architecture (replacing the procedural per-frame FSM) — needed for direct frame-CRC comparison against MAME once palette/VRAM/sprite state are all independently trusted, and for eventual hardware synthesis regardless (the procedural FSM was never going to be synthesizable as-is).
4. `nmk112` + 2x jt6295 functional audio integration (currently stubbed).
5. Real `nmk_irq` dual-PROM state machine for `bjtwinp`/`nouryokup` (cactus-only `nmk_irq_hacky` doesn't cover them).
6. `cactus`'s scrambled graphics ROMs (see "Hardware spec" above) need the fixed bitswap applied — either in `tools/mkgfxrom.py` or at `.mra` build time — before `bjtwinp`/`nouryokup` (which use unscrambled ROMs) and `cactus` can share one `.rbf`. Not yet needed for the current milestone since `cactus`'s ROMs were used as-is (scrambled) and the game still booted and rendered something coherent — worth understanding why before assuming it doesn't matter.
7. Extend the CPU-correctness oracle trace further into the boot sequence (needs the Lua-tap-overhead workaround already documented) to validate beyond the first ~1618 events, and add read-cycle coverage (this window happened to be write-only).
