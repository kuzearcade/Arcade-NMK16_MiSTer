# Hardware bring-up architecture

Pilot family: **tdragon2** (Tier 3, Family C — shares an identical
`MACHINE_CONFIG` with `macross2`, so this same `.rbf` serves both; the
`.mra` is the only per-game file). Chosen as the pilot per explicit
direction (originally proposed `cactus`/Tier 1, redirected to
`tdragon2`).

## Why this isn't just a wrapper around the existing cores

Every one of the 18 sim-verified cores loads all ROMs via `$readmemh`
into zero-latency arrays, and every CPU wrapper ties its wait-state
input to an always-ready constant (`fx68k`'s `DTACKn = ASn | iack_cycle`,
`T80s`'s `WAIT_n(1'b1)`, `jt6295`'s `rom_ok(1'b1)`). None of that is
real for hardware: the DE10-Nano's Cyclone V (`5CSEBA6`) has on the
order of ~690KB of on-chip embedded memory (M10K blocks) total, and a
single game's ROM set is typically several MB — everything has to live
in the board's own SDRAM chip, accessed through `rtl/sdram.sv`'s
4-port, ~8-`clk`-cycle-latency, toggle-style req/ack interface, not a
0-latency array.

## Decision: (almost) everything through SDRAM, real wait-states everywhere

Considered putting small/latency-critical ROMs (CPU program ROMs,
`fgtile`) in on-chip BRAM and only the bulk graphics/sample ROMs in
SDRAM. Rejected: `audiocpu`+`fgtile` alone would already use ~256KB,
and this project's own existing work RAM (mainram/bgvram/txvram/
palette/z80ram/snap_buf + the double-buffered full-frame sprite
composite plane, `sprite_plane[0:1][0:SCREEN_W*SCREEN_H-1]` — ~215KB by
itself) already uses on the order of 365KB. That leaves an
uncomfortably thin margin, and — more importantly — it doesn't
generalize: bigger ROMs in later families (`raphero`'s sprite ROM alone
is 6MB) would blow the on-chip budget even with this split.

Instead: **every ROM region goes through SDRAM**, with real per-consumer
wait-state handling, and BRAM is reserved for what's genuinely small and
either random-access work RAM or a tiny fixed table:

- `mainram`/`bgvram`/`txvram`/`palette`/`z80_ram`/`snap_buf`/
  `sprite_plane` double buffer — unchanged, stay on-chip (this is
  writable working state, not ROM, and was never a candidate to move).
- `nmk_irq`'s V/H-timing PROMs (256 bytes each) — tiny, loaded via
  `ioctl_download` into a small on-chip table instead of `$readmemh`,
  same as today just download-driven.
- Every actual ROM region (`maincpu`, `audiocpu`, `fgtile`, `bgtile`,
  `sprites`, `oki1`, `oki2`) — SDRAM, real req/ack.

This is a genuine, precedented trade-off already established elsewhere
in this project: adding real wait-state latency to CPU-visible memory
access changes exact cycle timing relative to the already
oracle-verified 0-wait simulation baseline, in the same class as the
already-accepted TLCS-90 protection-MCU timing drift and the jt03
busy-poll timing sensitivity documented throughout Tier 2-5. The CPU
*decode*/*flag* correctness already verified against the MAME oracle is
untouched by this — only wall-clock cycle relationships change, and
this project has repeatedly shown these games tolerate that (they
already ran/rendered correctly under multiple different documented
cycle-timing imperfections before this).

`fx68k` (`DTACKn`), `T80s` (`WAIT_n`), and jotego's `jt6295`
(`rom_addr`/`rom_data`/`rom_ok`) already have real wait-state support
built into their interfaces — this was jotego's/the fx68k author's own
design intent, unused until now because every existing top-level tied
these to constants. No CPU/sound-chip core changes are needed, only
driving these pins for real.

## Additive-parameter pattern (protects the 17 other already-committed sims)

`video_macross2.sv` is shared, unmodified, between `macross2` and
`tdragon2`'s own already-committed, oracle-verified simulations. To
avoid any risk of regressing those: every core/video module gets a new
`HW_ROMS` parameter, default `0`. At `HW_ROMS=0` (the default, used by
every existing sim testbench, unchanged), the module behaves exactly as
it does today — same `$readmemh` arrays, same 0-latency reads, same
ports. At `HW_ROMS=1` (used only by the new hardware top-level), the
`$readmemh` arrays are replaced by real req/ack ports to external SDRAM.
This means the 17 non-pilot cores need zero changes and carry zero
regression risk from this work; only `tdragon2_core.sv` and
`video_macross2.sv` (and, by extension, `macross2` whenever it becomes
the second hardware target) gain the new parameter/ports, with the
default path byte-for-byte unchanged.

## SDRAM port assignment (`rtl/sdram.sv`'s 4 req/ack ports)

`sdram.sv` is word-addressed (`addr[24:1]`, 24-bit word address → 32MB
byte space) with an ~8-`clk`-cycle req→ack latency (toggle-style: caller
flips `req`, waits for `ack` to mirror it) at whatever clock `clk_sys`
feeds it. Four physical ports, more than four logical consumers, so
consumers that don't need simultaneous access share a port through a
tiny round-robin arbiter:

- **Port 0** — `ioctl_download` writes (only active before/between
  play, core held in reset) **and** 68000 program-ROM reads (mutually
  exclusive in time with download, so no arbiter needed, just a mux on
  `ioctl_download`).
- **Port 1** — Z80 `audiocpu` program-ROM reads.
- **Port 2** — BG tile / TX tile / sprite tile reads, round-robin
  arbitrated. All three already tolerate added latency structurally:
  BG/TX only need a new byte at tile-column boundaries (every 8-16
  pixels, not every pixel — see below), and sprite fetch is already a
  multi-state FSM (`S_SPR_CHECK`/`S_SPR_CHECK2`), not tied to `ce_pix`.
- **Port 3** — OKI0 + OKI1 sample reads, round-robin arbitrated (very
  low bandwidth, ~1MHz-ish access rate, ample slack).

## BG/TX tile fetch: per-tile cache, not a full line buffer

`video_macross2.sv` currently computes `bg_byte_addr`/`bgtile_byte`
(and the fg/TX equivalent) combinationally every `ce_pix`, assuming
instant array lookup. Real hardware needs a new byte only when the
raster beam crosses into a new 16x16 (BG) or 8x8 (TX) tile — a 128-byte
(BG) or 32-byte (TX) chunk is fetched once per tile-column and cached
in a small register, served combinationally for the remaining
15/7 pixels. This is a much smaller, simpler change than a full
line-ahead prefetch buffer, and the existing per-tile granularity of
`video_macross2.sv`'s own address computation (`bg_byte_addr` already
depends on `bg_code`/`bg_py`, not `bg_px` for the byte- vs
nibble-select split) makes the boundary detection straightforward
(compare this pixel's `{bg_code,bg_py}` against the cached tag).

## Single clock domain — `rtl/sdram.sv` runs at `clk_sys` itself, no CDC

`rtl/sdram.sv`'s own comments describe it as usable "at up to 128MHz,"
which suggested a separate fast PLL clock plus cross-domain
synchronization for the req/ack toggle handshake into/out of the
existing 40MHz `clk_sys` domain used by every already-verified
clock-enable derivation in these cores (`cpu_div`, `z80_div`, `ym_cen`,
`oki_cen`, etc.). Rejected in favor of a much lower-risk option: CAS
latency and RAS-to-CAS delay on real SDR SDRAM parts are specified in
*clock cycles*, not absolute time, and remain valid across a wide
frequency range for a given speed grade — running `rtl/sdram.sv` (and
the real `SDRAM_CLK` pin) directly at the existing `clk_sys` (40MHz) is
well within a real MT48LC16M16A2-7's rated range for `CAS_LATENCY=3`,
and 40MHz gives `RASCAS_DELAY=2` cycles = 50ns, comfortably over the
chip's 20ns tRCD minimum. This means **zero clock-domain-crossing
logic anywhere in this design** — every consumer (`sdram_req.sv`
instance) lives in the same `clk_sys` domain as `rtl/sdram.sv` itself,
and none of the already oracle-verified clock-enable arithmetic changes
at all. The cost is some peak SDRAM bandwidth headroom (~8 `clk_sys`
cycles = 200ns per transaction, up to ~32 cycles = 800ns worst case
under full 4-port contention) — comfortably inside the slack every
consumer here already has (BG/TX only need a new fetch every 8-16
pixels = 1-2us; sprite fetch is FSM-paced, not tied to `ce_pix`; Z80/
68000/OKI are all low-bandwidth and already tolerate documented cycle
timing drift elsewhere in this project).

## ROM-loading / `.mra` scheme

One HPS_IO `ioctl_index` (`0`), one `.mra` `<rom index="0" zip="..."
md5="none">` block whose `<part>` entries are listed in the *same order*
as `ROM_START`'s own regions — this concatenates into one download
stream at fixed byte offsets, which the core's own SDRAM-write demux
splits by address range into the right destination (mirrors
`docs/mra-workflow.md`'s already-decided approach and this project's
existing `tools/mkrom.py`/`mkgfxrom.py` sim-ROM-concatenation logic,
just re-expressed as MRA XML instead of a raw hex dump). Byte-swap
handling (`ROM_LOAD16_WORD_SWAP` etc.) that the sim tools apply at
build time has no equivalent in the on-the-fly ioctl stream — the core
itself must un-swap at read time instead (or the address decode must
account for it), since the `.mra` can't re-order bytes within a `<part>`.

tdragon2's own `ROM_START` (`nmk16.cpp`) byte layout, base offsets
chosen to leave headroom for bigger games later:

| Region | Bytes | Offset |
|---|---|---|
| maincpu | 0x080000 | 0x000000 |
| audiocpu | 0x020000 | 0x080000 |
| fgtile | 0x020000 | 0x0A0000 |
| bgtile | 0x200000 | 0x0C0000 |
| sprites | 0x400000 | 0x2C0000 |
| oki1 | 0x200000 | 0x6C0000 |
| oki2 | 0x200000 | 0x8C0000 |

Total 0xAC0000 (~10.75MB) of the 32MB SDRAM address space this scheme
addresses.

## Foundational primitives built and standalone-verified

Three new reusable modules, each verified in isolation against a real
`rtl/sdram.sv` + a new behavioral chip model (`sim/models/sdram_model.sv`,
a minimal JEDEC-command-level SDR SDRAM simulation, not timing-accurate
but functionally faithful — real ACTIVE/READ/WRITE/auto-precharge
semantics) before ever being wired into a core:

- **`rtl/sdram_req.sv`** — single-port req/ack wrapper hiding
  `sdram.sv`'s own toggle-style handshake behind a plain
  addr/we/din/req→busy/valid/dout interface. Verified
  (`sim/rtl/sdram_test/`): 80,000 read/write checks across all 4 real
  `sdram.sv` ports contending simultaneously, zero mismatches.
- **`rtl/sdram_arb.sv`** — N-way round-robin arbiter multiplexing
  several logical consumers onto one physical `sdram_req.sv`/port (e.g.
  BG+TX+sprite tile fetch sharing one port). Verified
  (`sim/rtl/sdram_arb_test/`): 45,000+ checks across 3 arbitrated
  channels, zero mismatches, no starvation.
- **`rtl/rom_cache1.sv`** — the primitive every ROM consumer in this
  project's hardware work is actually built on: a 1-entry cache over
  one `sdram_req`/`sdram_arb` channel, presenting "data for whatever
  address you want right now, or not ready yet," refetching
  automatically on any address change and correctly tracking a request
  still in flight even if the consumer's own address moves on again
  before it completes. Verified (`sim/rtl/rom_cache1_test/`): 5,000
  stable-address reads (the CPU-bus-cycle shape) + 500 moving-target
  convergence checks, zero mismatches.

**A real bug was found and fixed in `sdram_req.sv` during `rom_cache1`
verification**: its original accept condition (`req && !pending`)
checked `req` by *level*. `rom_cache1` (correctly, per its own
documented contract) holds `sd_req` high continuously from issue until
`sd_valid` arrives. Since `sdram_req.sv`'s own internal `pending`
clears exactly one cycle *before* the caller has a chance to react and
drop its own request line, there is exactly one cycle where
`sdram_req.sv` sees `req==1` (the stale tail of the just-completed
request) and its own `pending==0` simultaneously — misreading this as
a brand-new request and silently re-issuing a duplicate fetch of the
*old* address, then handing that stale data to whatever *new* request
the caller made next. Root-caused via a real per-cycle signal trace
(temporary debug ports, since removed) after the bug reliably
reproduced on the second read of a two-read test. Fixed with proper
rising-edge detection (`req && !req_prev && !pending`) — confirmed
backward-compatible with `sdram_arb.sv`'s own internal one-cycle-pulse
usage (a pulse's rising edge is unaffected by edge- vs level-triggering)
via a full regression re-run of both earlier standalone tests after the
fix: `sdram_req` 80,000/80,000 unchanged, `sdram_arb` 45,109/45,109
unchanged.

## Status

Design only as of this writing — implementation follows in
`rtl/tdragon2/tdragon2_core.sv` (`HW_ROMS=1` path),
`rtl/macross2/video_macross2.sv` (`HW_ROMS=1` path), a new generic
`rtl/sdram_req.sv` helper, the family's top-level `emu.sv`/`.qsf`/`.sdc`,
and `releases/tdragon2.mra`/`releases/macross2.mra`. Verification plan:
a new hardware-mode Verilator testbench (behavioral SDRAM-latency model
+ a fake `ioctl_download` byte-stream replay of the real ROM images)
confirming the CPU still boots/executes the same program correctly
under real wait-state latency, before ever spending a Quartus compile
cycle — Quartus compile + fitter/timing-closure is the furthest this
session can verify, since no JTAG/SD-card access to a real DE10-Nano
exists in this environment (see conversation record) — actual hardware
boot confirmation needs the project owner's own test.
