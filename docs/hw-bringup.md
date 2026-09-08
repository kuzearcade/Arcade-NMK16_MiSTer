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
byte space) with a toggle-style req/ack handshake (caller flips `req`,
waits for `ack` to mirror it), and **every read returns the aligned
word pair containing the requested address**: `doutN` is the requested
word, `doutN_pair` is `{word(addr|1), word(addr&~1)}`. Internally that
is two READ commands in one activation (the second with auto-precharge)
for one extra cycle on the data bus — the column/row split is
column = `a[9:1]`, row = `a[22:10]` so a pair shares a row. Writes stay
single-word. The wrappers (`sdram_req.sv`, `sdram_arb.sv`) pass the pair
through; `rom_cache1.sv` is a 2-word line, `tile_prefetch_byte.sv` caches
4-byte / 8-pixel groups. Four physical ports, more than four logical
consumers, so consumers that don't need simultaneous access share a
port through a tiny round-robin arbiter:

- **Port 0** — `ioctl_download` writes (only active before/between
  play, core held in reset) **and** 68000 program-ROM reads (mutually
  exclusive in time with download, so no arbiter needed, just a mux on
  `ioctl_download`).
- **Port 1** — Z80 `audiocpu` program-ROM reads + OKI0 + OKI1 sample
  reads, 3-way round-robin arbitrated (all low-bandwidth; the OKIs are
  ~1MHz-ish access rate with ample slack).
- **Port 2** — BG tile reads, alone (`video_macross2.sv`'s port A).
- **Port 3** — TX tile reads + sprite tile reads, fixed priority TX
  first (`video_macross2.sv`'s port B).

This is the second layout. The first put BG + TX + sprites on port 2
behind one 3-way arbiter and the OKIs on port 3, and `rtl/sdram.sv`'s
mode 0 served port 3 only when the others were idle. That failed on real
hardware for a throughput reason the simulation could not show (see
"SDRAM clock" below for the numbers): the two real-time tile layers each
need a word per 4 pixels, and every single-word transaction costs a
full handshake round trip — consumer to `sdram_req`, toggle, two clock
crossings, arbitration behind up to three other ports, the transaction,
the copy, the ack back — of which the SDRAM itself is only ~4 of ~12
`clk_sys` cycles. Serialised on one port the two layers could not both
be fed; on two ports their round trips overlap. Mode 0 is now a plain
4-port round-robin so port 3 gets a fair share.

## BG/TX tile fetch: prefetching word cache, not a line buffer

`video_macross2.sv` computes the wanted ROM byte combinationally from
the pixel being drawn (its address math is per-pixel: `bg_byte_addr`
from `{bg_code, bg_py, bg_px}`, the TX equivalent from
`{code, tx_py, tx_px}`). The first hardware version put a 1-word
on-demand cache (`rom_cache1_byte`) behind that, non-blocking: a miss
served the previous word rather than stalling the raster. That is only
as good as the fetch round trip is short — the request can only start
when the first pixel that needs the word is already on screen — and
even at 96MHz it left a garbage column at x=0..6 (cold cache at line
start) and dashes wherever the sprite pass was busy.

The real-time layers now go through `rtl/tile_prefetch_byte.sv`, which
separates the request stream from the use stream. A **lookahead**
pixel, 16 ahead of the one being drawn (`x_look`; the 9-bit wrap
mirrors `rd_x = hcount - 28`, so the line's first words are fetched
during the preceding horizontal blank, after `vcount` has stepped),
owns the VRAM read port and issues fetches four words ahead; the **use**
pixel looks its word up in a small fully-associative cache by
tile-space tag (`{line_y, line_x>>2}` — a position, not a ROM address,
because the use pixel has no VRAM read of its own; the entry carries the
VRAM word so the palette bits come from the right tile too). Steady
state holds word(x)..word(x+16), ~80 `clk_sys` of slack per fetch
instead of zero. `HW_ROMS=0` is untouched and stays bit-identical to the
oracle-verified sims (checked by hash after every change here).

Sprites keep the 1-word cache with a real blocking wait: their fetch is
an FSM-paced compositing pass, not tied to `ce_pix`.

## SDRAM clock: 96MHz `clk_ram`, toggle-handshake CDC into `clk_sys`

The first version of this design ran `rtl/sdram.sv` (and the real
`SDRAM_CLK` pin) directly at the 40MHz `clk_sys`, on the reasoning that
SDR SDRAM timing is specified in clock cycles (so `CAS_LATENCY=3` and
`RASCAS_DELAY=2` stay legal at 40MHz) and that a single clock domain
means zero clock-domain-crossing logic. That reasoning was correct as
far as it went, and it was what got the games booting on real hardware.
It was wrong about bandwidth. Both games showed **horizontal smearing
of every tilemap row on real hardware**, reproduced exactly in the
`HW_ROMS=1` Verilator frames (`sim/rtl/tdragon2_hw/`), and the arithmetic
is unforgiving:

- BG and TX tiles are 4bpp, so each layer needs a fresh 16-bit word
  every 4 pixels. At the 6.4MHz-equivalent pixel rate (`ce_pix` every
  ~5 `clk_sys` cycles) that is one word per ~20 `clk_sys` cycles **per
  layer**, plus sprites on the same port.
- `rtl/sdram.sv` performs single-word transactions of ~9 cycles each
  (ACTIVATE, `RASCAS_DELAY`, READ, `CAS_LATENCY`, auto-precharge), one
  at a time across all four ports, plus refresh.
- That is ~192 tilemap transactions per ~2560-cycle scanline, ~67% of
  the whole bus by itself, before the 68000/Z80/OKI ports get a turn.
  The per-tile caches in `video_macross2.sv` are deliberately
  non-blocking (a miss serves the previous byte rather than stalling
  the raster), so every miss is a horizontal streak.

The fix is the standard MiSTer arrangement, and the one
Arcade-TMNT_MiSTer runs this identical controller with: a second
output of `rtl/pll.v` at **96MHz** (`clk_ram`, 50MHz × 48/25, same VCO
as the 40MHz `clk_sys`) clocks `rtl/sdram.sv`, so a transaction takes
~94ns instead of ~225ns and the tilemap layers use roughly a quarter of
the bus. Every consumer stays on `clk_sys`; nothing in the already
oracle-verified clock-enable arithmetic changes. The crossing lives in
exactly two places:

- `rtl/sdram.sv` brings each port's toggle-style `reqN` in through a
  2-flop synchronizer before arbitration, and read data goes into a
  **per-port** `doutN_r` register (the original single shared `dout`
  was only safe when the consumer sampled it the cycle after `ack`).
- `rtl/sdram_req.sv` — which every consumer already goes through,
  including `sdram_arb.sv`'s internal instance — brings `ack` back
  through a 2-flop synchronizer. The payload direction needs nothing:
  `addr/we/din` are held stable from the `req` toggle until `ack`, and
  the controller only samples them after its own synchronizer has seen
  the toggle. Both synchronizers are unconditional; in a single-clock
  configuration they just add two cycles of latency (the standalone
  `sdram_test`/`rom_cache1_test`/`sdram_arb_test` sims still pass).

Two lessons from getting this onto hardware, both worth more than the
design itself:

1. **`SDRAM_DQ` must be captured by exactly one register.** The first
   96MHz build latched `SDRAM_DQ` straight into the four per-port
   registers. Timing closed, synthesis and the fitter were silent, and
   both games booted — with fine vertical noise in every tile and
   broken sample playback. The QSF's `FAST_INPUT_REGISTER ON -to
   SDRAM_DQ[*]` can only pack one register into the pad's I/O cell; the
   other three sampled the pins through unconstrained routing, which at
   a 10.4ns period is a coin toss. The controller now captures into the
   single `dout` (I/O-cell packable) and copies it into the completing
   port's register one cycle later, toggling that port's `ack` in the
   same cycle; the arbiter masks a port out while that copy is in
   flight (`done_port`), because otherwise it looks pending for one
   extra cycle and gets re-granted as a duplicate transaction whose
   completion toggles `ack` a second time (the standalone sims caught
   that one immediately: reads of 0x0000).
2. **Each PLL output needs its own exclusive clock group in the SDC.**
   Both clocks come from one VCO, so a single group containing both
   would make TimeQuest time every `clk_sys`↔`clk_ram` path
   synchronously against the worst-case edge relationship of a
   25ns/10.4ns pair (~2ns, every 125ns) and fail on the payload paths
   the handshake makes irrelevant. `Macross2.sdc`/`SdramTest.sdc` build
   the groups with a `foreach_in_collection` over
   `emu|pll|altpll_component|*PLL_OUTPUT_COUNTER|divclk`, so it stays
   correct whatever Quartus names the counters (`generic_pll1`/
   `generic_pll2` today).

`REFRESH_CYCLES` moved from 240 (7.8µs at 40MHz) to 740 (7.7µs at
96MHz). `SdramTest` rebuilt at 96MHz shows the full-512KB Phase 1 clean
apart from its documented shared-address-0 artifact, and the Macross2
build closes timing on both domains with margin (96MHz domain: ~1.2-1.6ns
setup / 0.45ns hold slack, Fmax ~108MHz; 40MHz domain: ~3.2-5.4ns setup).
The Verilator harnesses (`sim/rtl/*_hw/`) drive `clk_ram` at three
edges per `clk_sys` cycle by default — a 120MHz-equivalent, more
generous than real hardware since 96/40 is not an integer ratio;
`TB_RAM_PER2=5` gives a 100MHz-equivalent — and the smearing is gone
from their frames.

Three more things the hardware taught after the clock change, none of
which the 3:1 simulation reproduced:

1. **Throughput, not latency, is the limit for single-word fetches.**
   With the prefetch cache on a single shared video port the BG layer
   still missed on two thirds of the screen — measured directly with
   `DBG_MISS_PAINT` (a `video_macross2.sv`/`tdragon2_core.sv` parameter
   that paints BG-cache misses magenta and TX misses cyan; the miss
   counts in a capture are then a pixel count — but subtract the game's
   own pure-magenta/cyan pixels, see item 3). Each fetch's round trip
   is ~12 `clk_sys` uncontended and more behind other ports, against the
   20 `clk_sys` the two layers have per word between them. Hence the
   port split above.
2. **`sdram_arb.sv` re-granted a just-served channel as a duplicate
   transaction.** Every hold-req-until-valid caller drops `req` one
   cycle after `valid`, and the arbiter re-scanned in that same cycle;
   the duplicate's completion was then delivered as the caller's NEXT
   request's data. It had been silently doubling every arbitrated video
   fetch, and became a hard failure — a silent, spinning Z80 executing
   corrupted program bytes — the moment the Z80 ROM fetch moved from a
   direct `sdram_req` (rising-edge triggered, immune) onto port 1's
   arbiter. The arbiter now holds a served channel off until its `req`
   has been seen low. The `*_hw` testbenches' Z80 write counters
   (YM2203/OKI writes) caught it in simulation once the port move was
   simulated: 41 YM2203 writes instead of ~21,000.
3. **Two words per transaction.** With the split ports, the 16-pixel
   lookahead and the arbiter fix, the painted-miss captures still
   showed a few hundred to ~2000 "miss" pixels in two scenes. Those
   turned out to be a measurement error: the paint detector (pure
   magenta / pure cyan in a capture) was counting genuine game colours
   — the pink separator lines of the Macross II HUD bar and the teal
   border of tdragon2's score panel — which is why the counts were
   byte-identical across three otherwise different builds. Real misses
   were already indistinguishable from zero. The pair read was built
   before that was understood and is kept as a margin improvement (the
   68000 executes ~8-10% more instructions per sim run, i.e. fewer wait
   states; every consumer's transaction count halves), verified the same
   way as everything else here. Every read now returns the aligned
   word pair (see the port-assignment section): a second
   READ to the odd column in the same activation, auto-precharge on the
   second, the free-running single `SDRAM_DQ` capture register copied
   twice (even word at READY+1, odd at READY+2, ack after the second),
   `doutN_pair` on every port, 8-pixel tags and 32-bit entries in
   `tile_prefetch_byte`, a 2-word line in `rom_cache1` (so the 68000,
   Z80, OKI and sprite fetches halve too). One extra bus cycle per
   transaction buys half the transactions everywhere, because the
   handshake round trip, not the SDRAM, is the cost. The per-word
   ROM-fetch checksum reference tables under `rtl/tdragon2/*fetch_*.hex`
   (a disconnected diagnostic) were generated for single-word fetches
   and no longer match the fetch sequence; `rom_csum` (DTACK-gated) is
   unaffected.

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

## Real-hardware bring-up: the black-screen root cause

Both tdragon2 and macross2 first booted to a solid black screen with
silent audio on a real DE10-Nano (deployed over SSH/rsync to
`/media/fat/_Arcade/`, observed via a direct-video capture box), despite
the `HW_ROMS=1` Verilator testbenches passing. The investigation is
worth recording because the eventual root cause was small, and several
plausible-looking leads along the way were not it.

**Root cause: `ioctl_download` SDRAM writes were not gated on
`ioctl_index`.** `Macross2.sv` never connected `hps_io`'s `ioctl_index`
output, and `tdragon2_core.sv`'s `sd0_inst` wrote SDRAM on *any* ioctl
session. The MiSTer `.mra` loader sends **two** sessions per game load:
the single `<rom index="0">` block (every ROM region, at the byte
offsets in the table above), and then the `<switches>` DIP block as a
separate session on **index 254** — up to 8 raw bytes, and
`sys/hps_io.sv`'s `FIO_FILE_TX` resets `ioctl_addr` to 0 at the start
of every session. So the DIP bytes (`F7,FF,00` for tdragon2) were
written to SDRAM word 0 onward — the 68000's own reset vector — *after*
the ROM had been correctly loaded there. The CPU then booted from a
garbage SP/PC every time. The official MiSTer MRA docs specify exactly
this (index 254, raw bytes, "instead of the status bits"), and every
working arcade core checked (Arcade-TMNT, Arcade-Darius, jotego's
jtframe `IDX_ROM`/`IDX_DIPSW=254`) qualifies ROM writes on
`ioctl_index == 0`.

**Fix:** `tdragon2_core.sv` takes `ioctl_index`, and `sd0_inst`'s
`we`/`wrl`/`wrh`/`req` are gated by
`ioctl_rom_wr = ioctl_download && ioctl_index == 16'd0`. `Macross2.sv`
also now captures the index-254 block into `dip_sw[0:7]` and drives
`dsw1_i`/`dsw2_i` and the hidden game-select bit (`dip_sw[2][0]`) from
it — the previous `status[15:0]`/`status[16]` wiring never received DIP
data at all, for the same reason. Sim testbenches tie `ioctl_index` to
`16'd0` (they only ever streamed the ROM, which is precisely why they
never reproduced this).

**Verification on hardware** (all read back from on-screen diagnostic
barcodes decoded from direct-video captures): `ioctl_session_count=2`,
`ioctl_last_index=254`, the index-254 session's word at address 0 =
`0xFFF7` (= the `.mra`'s own `F7,FF`); after the gate, all four reset-
vector words correct and the CPU-bus ROM checksum `rom_csum = 0x44D8`,
matching the Verilator reference exactly — it had been `0xC465` on every
earlier run.

**What it was not** (each ruled out by a targeted real-hardware test,
kept here so nobody re-chases them): raw `rtl/sdram.sv` read/write
correctness (a standalone `SdramTest.sv` core passed a full 512KB
write/read-back sweep — though that *did* surface and fix a real,
separate bug: the file's default `REFRESH_CYCLES=850` was tuned for
~96MHz and violated the 64ms refresh spec at this project's 40MHz
`clk_sys`, now overridden to 240); the `ioctl_download` write path
(byte-exact across all 128 4KB buckets — but note the check froze after
the first 524288 bytes, so it was blind to the *later* small session);
`rom_cache1`/`sdram_req` request handshake (the corrupted reads were
genuine reads of the correct address); tRCD/tRP command spacing and the
`SDRAM_CLK` PLL phase (now parameterizable as `RASCAS_DELAY`,
`PRECHARGE_DELAY`, `SEPARATE_SDRAM_CLK`/`CLK1_PHASE_SHIFT`, all
defaulting to the original behavior — none changed the symptom); and
concurrent multi-port SDRAM contention — a `SdramTest.sv` "background
load" appeared to reproduce corruption, but only because every phase in
that test shared SDRAM address 0 onward and the background load
overwrote words 0–4095 with a different pattern. Lesson: give each
concurrent SDRAM test its own disjoint address region before drawing
conclusions.

The diagnostic instrumentation (`rom_csum`, per-bucket/per-word
checksums with `$readmemh`-loaded sim references under
`rtl/tdragon2/*_ref.hex`, the `dbg_*` ports on `rtl/sdram_req.sv`) is
left in `tdragon2_core.sv`; `Macross2.sv` no longer draws the overlays
(reconnect the `final_rgb` ternary chain, preserved in git history, to
bring them back). The self-contained methodology — a passive checksum
tap at a fixed *transaction count*, compared between a fixed-input
Verilator run and real hardware, read out as a 16px/bit barcode — was
reliable end to end and is the recommended first tool for any future
real-hardware divergence.

## Real-hardware picture vs MAME: why it looked offset and cropped

Compared real-hardware captures of both games against snapshots from the
local MAME build (`mame -norotate -str N`, i.e. the raw 384x224
framebuffer at N seconds). MAME's display parameters for these boards —
384x224 visible, htotal 512 with the active area at 28..411, vtotal 278
with the active area at 16..239, 8MHz pixel clock — are exactly the
core's `video_timing.sv` constants and `rd_x = hcount - 28`, and the
captured picture is centred in the output, so neither the raster timing
nor the placeholder HSync/VSync placement moves the image. Four
separate things did, the first two of which are core bugs:

0. **The whole picture sat 28 pixels right and 16 lines down of MAME's.**
   Measured by cross-correlating a settled reference-sim title frame
   against the MAME snapshot: a shift of (-28, -16) matches on 83,015 of
   86,016 pixels for tdragon2 and 79,850 for Macross II — i.e. the entire
   scene, tilemaps and sprites alike, was displaced by exactly the
   blanking widths, pushing the rightmost 28 columns and bottom 16 rows
   off-screen and wrapping other-side content into the left/top margin
   (the "junk strip" on the left of every capture). Cause: MAME
   positions tilemaps and sprites in BITMAP coordinates, whose visible
   area starts at (28,16); `scrolldx(92)` and the sprite `videoshift(92)`
   are bitmap offsets, so tilemap x = screen_x + 28 - 92 + scrollx (which
   is what MAME's own "leftmost 64 pixels have to be retrieved from the
   other side" comment describes), tilemap y = screen_y + 16 + scrolly,
   and a sprite at X lands at screen X + 64. The core applied 92 to the
   screen-relative `rd_x` and nothing to `rd_y`. Fixed in
   `video_macross2.sv` by converting `rd_x`/`rd_y` (and the lookahead x)
   to bitmap coordinates (`BITMAP_X0`/`BITMAP_Y0`) before that math, and
   giving sprite pixel positions a proper mod-512 wrap so a sprite
   straddling the top or left edge shows its visible part. With both
   fixes the HW_ROMS=0 reference sim's settled title frame is
   pixel-identical to MAME's snapshot (86,016 of 86,016). This had
   survived the oracle work because frame-level pixel rendering was the
   one thing never compared against MAME (see the Tier 1 notes); the
   sibling sim-only 384-wide modules (`video_gunnail.sv`,
   `video_gunnailb.sv`, `video_powerins.sv`, `video_raphero.sv`) almost
   certainly carry the same offset and have not been touched for it.
1. **The TX (text) layer's right third was a copy of its left third.**
   The TX tilemap is 64 tiles = 512 logical pixels wide with
   `scrolldx(92)`, so screen x maps to logical `(x+420) mod 512` across
   all 384 columns. `video_macross2.sv` (inherited from
   `video_gunnail.sv`) computed that from `rd_x[7:0]`, so columns
   256..383 repeated logical 420..511 — the content of screen x 0..127.
   Symptoms, all confirmed side by side with MAME (on top of the global
   offset above): tdragon2's title
   showed the NMK logo and copyright twice and lost the "THUNDER DRAGON
   2" lettering on the right; tdragon2's right-edge HUD column
   ("PLAYER-1", "HIGH", "PLAYER-2", at x≈365..380 in the unrotated
   framebuffer) was missing; Macross II showed its logo twice, "INSERT
   COIN" as "INSERT C" and "SPECIAL THANKS" as "SPECIAL THAN". The same
   duplication was present in the HW_ROMS=0 reference sim frames, i.e.
   the earlier oracle comparison never covered the text layer's right
   third. Fixed by using the full 9-bit `rd_x` (and `x_look`) in the TX
   column math, here and in the four sibling 384-wide modules
   (`video_gunnail.sv`, `video_gunnailb.sv`, `video_powerins.sv`,
   `video_raphero.sv`); the 256-wide modules have the same expression
   but never see `rd_x >= 256`, so they are unaffected.
2. **tdragon2 is a vertical game and the core does not rotate it.** MAME
   rotates its framebuffer 270° (the `rotate="270"` in `-listxml`); the
   core outputs the raw landscape framebuffer, so on hardware the game
   appears sideways with its HUD text running vertically. The .mra's
   `<rotation>` tag does not rotate video by itself on MiSTer — the core
   has to do it, and the framework ships the standard way in
   `sys/arcade_video.v` (`screen_rotate`: a DDR3-backed rotating
   framebuffer driven from `VGA_*`, exposing `FB_*`/`DDRAM_*` which
   `Macross2.sv` currently ties off). Wiring that in, with the usual
   "Orientation" OSD option, is the remaining follow-up.
3. **The black borders are the MiSTer's own scaler setting.** The box's
   `MiSTer.ini` has `vscale_mode=1` (integer vertical scale only): 224
   lines fit 1080 at 4x = 896 lines (83% of the height), and the 4:3
   aspect then gives 1195 of 1920 columns (62%) — exactly the 480x448
   region measured in the 576x720 captures. That is a user preference,
   not core behaviour; `vscale_mode=0` fills the height.

## Sprites missing or garbled in the attract demos

Symptom (both games, hardware): during the attract demos only the
static HUD/life icons appeared; the player, enemies, bullets and
Macross II's mech — everything that changes from frame to frame — were
missing or garbled, while the title screens were pixel-identical to
MAME. Two things were wrong, found in this order:

1. **The sprite-table snapshot was a state of the draw FSM**, reachable
   only once a draw pass had finished. In the zero-latency sim a pass
   always finishes well inside a frame, so the copy happened at the DMA
   trigger as in MAME; on real hardware a sprite-heavy pass (every pixel
   waits on an SDRAM fetch) can outlast the frame, and the copy then
   landed at an arbitrary point in the 68000's own frame, mid-update of
   the table. That is a real hardware-only hazard and is fixed — the
   snapshot is now its own engine, copying at the trigger into whichever
   buffer the draw pass is not reading (`snap_active`/`snap_ready`/
   `snap_consume` in `video_macross2.sv`), and the plot/advance states
   are folded into one cycle — but it was NOT the cause of the missing
   sprites: the fixed build looked the same.
2. **The sprite header fetch read every word one offset late.**
   `S_SPR_HEAD_RD` fetches a slot's six words through `snap_rd_data`, a
   REGISTERED read of the snapshot buffer (commit 23a0cac made it one to
   kill a 1024:1 mux), but latched each word in the very cycle after
   presenting its address — one cycle before the registered word could
   arrive. So the visible flag came from the previous slot's colour
   word, the size from the flag word, the code from the size word, the X
   from the code word, and so on: sprites drawn (if at all) with wrong
   size, tile, position and colour. It survived every comparison because
   the frames compared to MAME (both title screens) contain no sprites
   — the "life icons" that did render are text-layer tiles. Fixed with a
   settle cycle per word (`head_rd_settle`); twelve cycles per slot
   header instead of six, irrelevant against a 256-pixel tile. With it,
   both demos render their sprites on hardware (tdragon2's player,
   enemies and bullets; Macross II's fighter, mechs and power-ups), and
   the sprite-free title frame is still pixel-identical to MAME.

Lesson for future sprite work here: a title screen is not a sprite
test. Compare a demo frame (MAME `-str 20` for tdragon2, `-str 45` for
Macross II) against a reference-sim run long enough to reach it
(`./obj_dir/Vtdragon2_core 1000000000` — both testbenches take the cycle
budget as argv[1]).

## Audio "muddled" on hardware

Compared 40 s hardware recordings of each game (capture box, `arecord`)
with MAME renders of the same games (`-wavwrite`, 50 s), by band energy
relative to the 1-2 kHz band: hardware sat 4-6 dB below MAME at 2-4 kHz
and 2-4 dB above it below 250 Hz on both games — the signature of
sample playback pitched far too low. Two causes in
`tdragon2_core.sv`, both against MAME's `macross2` machine config:

1. **OKI clock.** MAME clocks both OKIM6295s at 16MHz/4 = 4MHz with pin 7
   low (24.24 kHz sample rate); `oki_cen` was 40MHz/40 = 1MHz, and
   jt6295's `cen` is the chip clock, so every sample played four times
   too slow and two octaves too low. Now 40MHz/10.
2. **Mix balance.** MAME routes the FM at 1.20 and each OKI at 0.10;
   with the OKI stream being a 16-bit full-scale signal (jt6295's 14-bit
   `sound` x4) that is an OKI-to-FM ratio of 1/3 of the 14-bit value.
   The mix had each OKI at x4 — full 16-bit scale next to the FM, ~12x
   louder than MAME. Now 3/8.

The YM2203 (12MHz/8 = 1.5MHz) and Z80 (4MHz) enables were already right.
`rtl/macross/macross_core.sv` (sim-only) clocks its OKI at 1MHz the same
way and has not been checked against its own MAME config.

## Lines through moving sprites, and flicker

The draw FSM swapped the displayed sprite plane (`disp_buf`) the moment
a pass finished — at whatever scanline the raster had reached. The top
of that frame was therefore scanned from the previous plane and the
bottom from the new one, cutting every sprite that had moved between
the two passes at a swap line that wandered from frame to frame: a
line through the sprite, and, frame after frame, an apparent flicker of
the same sprites. Real hardware swaps its sprite buffer at vblank. The
finished plane now waits (`pass_done`) and is swapped in at the
sprite-DMA trigger (scanline 242, inside vblank); the next pass does not
start until that swap, so it cannot overwrite the waiting plane, and a
pass that outlasts a frame delays its swap by a frame instead of
tearing.

The actual cause of the lines on hardware turned out to be a third
flaw, found only because the sim kept losing sprites on alternate
frames after the swap fix: **the sprite plane was mis-indexed.** The
array has 2 x 86016 entries but was indexed as `{plane, y*384+x}`, i.e.
plane 1 at +131072, so plane 1's rows from 107 down (indices
172032..217087) lay beyond the array. Verilator dropped those writes —
the lower half of every other plane stayed empty, which is what the
per-frame surveys showed (explosions near the top still drawn, the
player near the bottom gone, alternating with the plane in use).
Quartus built a 172032-deep RAM (210 M10K, "Address Too Wide") whose
out-of-range addresses alias onto indices 0..45055 — the top 117 rows
of plane 0 — so drawing plane 1 scribbled the new pass's sprites into
the plane being displayed and its next clear wiped them mid-frame: the
lines through moving sprites and the flicker. Fixed by indexing with a
real offset (`plane * PLANE_PX + addr`) at all six sites; no extra RAM.
The oracle work never saw it: the title screens have no sprites.

A further, independent flaw showed up in the sim while verifying this:
sprites vanishing on random frames. The vblank IRQ fires at scanline
240 and the sprite-DMA trigger at 242, so the 68000's vblank handler is
already running when the table is copied. MAME copies the whole table
in an instant at 242 and the real board's DMA holds the CPU off the bus
(BR/BGACK) for the ~200 µs it takes; this core's copy takes ~2.5
scanlines while the CPU keeps running, and a fast enough CPU (the
zero-latency sim; on hardware the slower CPU usually lost the race,
which is why captures looked fine) gets to clearing or rebuilding the
table before the copy is through, so that pass draws a mostly empty
plane. Fixed the way the board does it: `sprite_dma_busy`
(`snap_active`) holds DTACKn for the CPU's main-RAM accesses and gates
the main-RAM write enables for the duration of the copy.

With all of the above in place the sim still showed each demo frame
twice while MAME advanced every frame. The 68000 was not the reason:
its cycle-stamped PC trace shows the game's frame loop running exactly
once per video frame at a steady ~31.8k instructions. The sprite pass
was: at three cycles per pixel plus a ROM fetch per eight, walking every
pixel of every tile in the table — including the many objects the game
keeps entirely off-screen — it outlasted a frame in this scene even
with zero-latency ROM, so the vblank-synchronous swap landed every
second frame and the sim displayed only MAME's odd frames. Two changes
in `S_SPR_CHECK`: the ROM byte address is now combinational from the
pixel counters, so a cached byte (7 of every 8 pixels) is plotted and
advanced in the same cycle; and a tile lying wholly outside the screen
is skipped on its first pixel, as MAME's clipping does.

Cost, stated plainly: sprites now display one frame after MAME and the
real board. Both render sprites per scanline from the table copied at
scanline 242 of the previous frame, so that table is on screen during
the very next frame; this core draws a whole plane, which takes most of
a frame, so the same table reaches the screen one frame later. In the
sim the sprite-heavy demo frame therefore matches MAME's snapshot on
94.7% of pixels at the same frame index (moving sprites one motion step
behind; tilemaps, HUD and text identical) — the 96.7% of the tearing
version was sprites reaching the screen sooner but cut in two. Removing
the frame of latency would need a scanline (line-buffer) sprite
renderer. Hardware: the same demo instant that showed the cut through a
large explosion before renders it continuous now.

## Status

`HW_ROMS=1` implemented for both games (`rtl/tdragon2/tdragon2_core.sv`
serving both at runtime, `rtl/macross2/video_macross2.sv`, `rtl/sdram_req.sv`,
`Macross2.sv`/`.qsf`/`.sdc`, `releases/tdragon2.mra`/`macross2.mra`),
Verilator-verified under real SDRAM wait-state latency, and — with the
`ioctl_index` fix above — booting on a real DE10-Nano with the ROM
checksum matching simulation, with sprites rendering in the attract
demos (see the sprite section above). With `rtl/sdram.sv` on the 96MHz
`clk_ram`, the prefetching tile cache, BG and TX on separate SDRAM
ports and the arbiter duplicate-grant fix (see the SDRAM sections
above) both games render without the horizontal smearing the
single-clock design showed, with audio, on hardware and in the
`HW_ROMS=1` sim frames; reads return two words per transaction as a
throughput margin (see item 3 above — the "residual" it was built for
was a paint-detector false positive on genuine game colours). Remaining known limitations: HSync/VSync
placement is still the documented placeholder (the scaler locks and
reports 384x224 @ 56.2Hz, but it has not been tuned against a reference),
and player-input mapping has been cross-checked against
`INPUT_PORTS_START` but not yet exercised in play on hardware.
