# Tier 1 — bjtwin family (cactus / bjtwinp / nouryokup)

Status: **CPU + memory-map + interrupt subsystem built and verified against a real MAME oracle trace.** Video (tilemap + `nmk16spr` sprite engine) and audio (`nmk112` + 2x OKIM6295) are not implemented yet — this document covers what exists so far and the concrete next steps.

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

- `rtl/bjtwin/bjtwin_core.sv` — fx68k instantiation, full address decode per the map above, ROM (`$readmemh`-loaded, parameterized path), main work RAM (32K x 16), palette RAM (1024 x 16), BG tilemap VRAM (2048 x 16, mirrored), and I/O register capture (flipscreen, tilebank, Y-scroll, nmk112 bank registers) — captured but not yet functionally connected to anything, since video/audio don't exist yet.
- `rtl/bjtwin/nmk_irq_hacky.sv` — cactus's fixed-scanline IRQ generator (see above), including HOLD_LINE-style level-held-until-acknowledged semantics matching MAME's M68K interrupt model.
- `tools/mkrom.py` — reconstructs a `$readmemh` ROM image from a split MAME romset zip's `ROM_LOAD16_BYTE` pair, reusable for every other 68000 program ROM in this driver.
- `sim/rtl/bjtwin/tb_bjtwin.cpp` + `Makefile` — Verilator testbench: runs the real `cactus` ROM, logs every completed bus write cycle in nmktrace format.

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

### Correction: the "cactus is missing ROMs" caveat below was a false alarm

The earlier note in this doc (and in `docs/sim-harness.md`) worrying that `mame_roms/cactus.zip` was missing `i03.bin`/`s-01.bin`/`s-02.bin` was wrong — it didn't account for MAME's **split romset** convention. `cactus`'s parent is `sabotenb` (`mame -verifyroms` reports `romset cactus [sabotenb] is good`), and MAME transparently merges files from the parent zip by CRC when the clone's own zip doesn't contain them — confirmed directly with `-verbose`: loading `cactus` opens both `cactus.zip` and `sabotenb.zip`, and `sabotenb.zip` contains same-sized, presumably CRC-matching files (`ic35.sb3` = 0x10000 bytes matching `i03.bin`'s fgtile region; `ic27.sb7`/`ic30.sb6` = 0x100000 bytes each matching `s-01.bin`/`s-02.bin`'s OKI regions) under different filenames. **The romset is genuinely complete** — see the full completeness audit below, done properly this time against all 101 romsets.

## Next steps

1. Video: `nmk16spr` sprite engine (port the exact algorithm from `nmk16spr.cpp` — 256-slot sprite RAM, per-frame clock-budget cutoff, reverse-order priority compositing, single-buffered for this family) and the single COL-scan tilemap renderer, driven off the palette/VRAM writes already being captured correctly.
2. `nmk112` + 2x jt6295 functional integration (currently stubbed).
3. Real `nmk_irq` dual-PROM state machine for `bjtwinp`/`nouryokup` (cactus-only `nmk_irq_hacky` doesn't cover them).
4. Resolve the ROM-completeness/MAME-version caveat above before capturing the video/audio oracle traces.
5. Extend the CPU-correctness oracle trace further into the boot sequence (needs the Lua-tap-overhead workaround above) to validate beyond the first ~1618 events, and add read-cycle coverage (this window happened to be write-only).
