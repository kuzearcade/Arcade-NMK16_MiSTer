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
- **Port 1** — sprite tile reads, alone (`video_macross2.sv`'s port B
  with `TX_EXTERNAL=1`; see "Slowdown" below for why the sprite fetch
  needs a port to itself).
- **Port 2** — BG tile reads, alone (`video_macross2.sv`'s port A).
- **Port 3** — TX tile reads (the video module's `txc_*` channel, top
  priority) + the sound consumers (Z80 or TLCS-90 program ROM, OKI0,
  OKI1; NMK004 and protection MCU on gunnail), fixed-priority arbiter.

This is the third layout. The second (2026-09-08) had port 1 = sound
consumers and port 3 = TX + sprites; the sprite fetch then lost about a
quarter of its frame budget waiting behind TX transactions.

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
   `Macross2.sv` tied off at the time). That was wired in next — see
   "Orientation option" below, since extended to both quarter-turn
   directions plus a Flip screen option on all three cores.
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

## OKI still ~8-13 dB too quiet in the mix (2026-09-09)

The "3/8" mix balance above (item 2 in the previous section) was itself
wrong, by a wide margin — reported as "all released games sound vastly
different from MAME, Rapid Hero worst." The earlier fix used a
bit-width argument (MAME's OKI:FM route ratio 0.10:1.20, scaled for a
16-bit-vs-14-bit representation) rather than a direct measurement, and
the argument had a scale error.

**How it was actually measured this time**: per-source audio taps
(`dbg_fm_snd`, `dbg_psg_snd`, `dbg_oki0_snd`, `dbg_oki1_snd`, all
tapped pre-mix) added to the `tdragon2`/`raphero`/`gunnail` reference
testbenches (`TB_DUMP_SRC=<prefix>`), and MAME rendered with each
source isolated by zeroing the others' gain in a `<mixer>` config file
(`device_volume`/`device_channel_volume` in `<mameconfig>`, `ymsnd`
channels 0-2 = SSG, 3 = FM). Comparing isolated FM against isolated FM,
and the actual combined mix during OKI-only passages (silent FM/SSG)
against MAME's own combined mix for the same passages, avoids the
raw/scaled-tap confusion that produced the original wrong ratio:

| Game | FM alone vs MAME | OKI's contribution to the real mix vs MAME |
|---|---|---|
| Rapid Hero | within 1.7 dB | 12.5 dB too quiet |
| Thunder Dragon 2 | within 1.7 dB | 11.6 dB too quiet |
| GunNail | close | 7.6 dB too quiet |

FM was always correct; only OKI was wrong, badly enough that with FM
silent (the common case at Rapid Hero's boot, since it has no music cue
yet) the whole mix was 12.5 dB down — that game had nothing else to
mask the gap, which is why it showed the problem most.

**Fix**: `oki0_g = oki0_ext + (oki0_ext >>> 1)` (x 3/2), replacing
`((oki0_ext <<< 1) + oki0_ext) >>> 3` (x 3/8) in `tdragon2_core.sv`,
`raphero_core.sv` and `gunnail_core.sv` — same single 18-bit adder, no
extra resource cost. Re-verified against MAME's real (non-isolated)
mix, full-length renders:

| Game | mean level diff (MAME-core) | mean band corr | where |
|---|---|---|---|
| Thunder Dragon 2 | -1.4 dB | 0.974 | sim, 10 s |
| Thunder Dragon 2 | -0.6 dB | 0.987 | real hardware, 90 s |
| Rapid Hero | -1.3 dB | 0.988 | sim, 100 s |
| GunNail | +1.4 dB | 0.864 | sim, 90 s |
| GunNail | +2.4 dB | 0.849 | real hardware, 90 s |

GunNail's lower correlation is the sequencer divergence below, not a
level problem — its level is corrected exactly as well as the other
two. `releases/Macross2.rbf`, `Raphero.rbf` and `Gunnail.rbf` rebuilt.
Raphero needed two Quartus seed retries (`SEED 7` succeeded) after the
first attempt failed to route — a pre-existing near-100%-utilization
congestion issue (Raphero was already at 82% ALM / 94% M10K with 0.27 ns
of setup slack before this change), not caused by the new expression,
which costs the same one adder as the old one.

## GunNail: the NMK004 sound sequencer diverges from MAME at 14.7-14.85s
into a track (root mechanism identified, underlying cause open)

Found while investigating the mix-balance issue above: GunNail's music
sounds static/looped fairly early into a track on both the RTL sim and
hardware, distinct from the level bug. Traced with two Lua taps
(`:nmk004:mcu`'s program-space write tap on `0xf800-0xf801`, the
YM2203 register/data ports) and the RTL's own equivalent debug ports
(`dbg_ym_we`, already wired to `dbg_ym_wdata`/`dbg_ym_waddr` added this
session) plus the existing `dbg_host_cmd_we`/`dbg_mcu_reply_we` 68000-
to-sound-CPU latch taps, and later a full PC/cycle-level instruction
trace comparison (below).

### First pass: the host-command path and gross CPU activity are fine

- The 68000-to-NMK004 command handshake (`0x08001E` write / `0x08000E`
  read, a periodic `CC`/`F7` ping plus the occasional real command)
  matches MAME's **exactly**, frame for frame, including the point
  where it goes quiet (frame ~819-822, ~14.6 s, in the first 25 s of
  the attract demo) — this is not a divergence, it's normal: the 68000
  sends a command once (`10`, "play track") and the sound CPU's own
  firmware plays the whole track without further host pokes, in both
  MAME and the RTL.
- The RTL's NMK004 (TLCS-90) is not stalled: a PC-cycle trace
  (`nmk004_cyc.trace`, cycle = `clk_sys_ticks/5`) shows 500-800
  *distinct* program addresses executed per second, steadily, both
  before and after the point where new YM2203 instrument-register
  writes (`0x30-0x8F`) stop — the CPU keeps running comparable code,
  it just stops calling whatever routine loads a new instrument.

### Second pass: PC/cycle-level trace comparison pins the divergence to a 150ms window

Reused the "cycle-timestamped NMK004 trace tooling" built earlier for
the protection-MCU/mustang investigation
(`sim/oracle/capture_cyc_trace.py`, `sim/compare/cyc_diff.py`; format:
`"<cumulative cycles> <PC>"`, gunnail's own reference testbench already
writes the RTL side to `nmk004_cyc.trace`). Captured a fresh 20 s MAME
oracle trace of `:nmk004:mcu` (`--seconds-to-run 20`, ~13.2M
instructions) and a matching 20 s RTL trace (13.1M instructions; must
be run from `sim/rtl/gunnail/` itself — the `$readmemh` paths baked
into the Verilated binary via `-G...FILE=` are resolved relative to
the process's CWD at run time, not compile time, so running the same
binary from a different directory silently loads all-zero ROMs).

`cyc_diff.py`'s strict ordered-PC-subsequence walk breaks almost
immediately (at oracle instruction 293,571, ~0.445 s in) on a genuine
but **benign** async timing artifact, not the real bug: the boot
handshake's own status-poll loop (`$0EC7: ld a,($FB00)` /
`$0ECB: or a,a` / `$0ECD: jr nz,$0EC7`, waiting for the 68000 to clear
its own command latch) takes one more pass in MAME than in the RTL at
that specific moment — an expected consequence of the two CPUs'
residual, already-documented sub-1%-per-instruction cycle-cost
differences (see "TLCS-90 cycle-timing fix" above) compounding into a
few-microsecond relative skew by then. Confirmed harmless: both sides
take the identical branch immediately afterward
(`$0196: jr c,$01A8`, carry clear on both, same fall-through).

Since the strict matcher can't recover from a loop-count skew, checked
alignment directly instead: took a run of 40-60 consecutive oracle PCs
as a landmark (discarding windows with under ~10 distinct addresses,
which are just the same generic 2-instruction idle-poll recurring
everywhere and match everywhere/nowhere meaninglessly) and searched for
that exact contiguous sequence anywhere in the full RTL trace:

| MAME time | landmark found in RTL trace at | verdict |
|---|---|---|
| 14.60 s | 14.614 s (+14 ms) | still in lockstep |
| 14.65 s | 14.650 s (+0 ms) | still in lockstep |
| 14.70 s | 14.619 s (-81 ms) | still in lockstep |
| 14.75 s | not this exact sequence (coincidental early match only) | diverging |
| 14.85 s | not found anywhere in the 20 s RTL trace | diverged |
| 15.4-18.0 s | not found anywhere in the 20 s RTL trace | diverged |

So the two CPUs run the **identical instruction sequence**, in
lockstep to within ~100 ms, all the way to ~14.7 s — then MAME
executes something the RTL's own 20-second run never executes at all,
starting somewhere in 14.7-14.85 s. That 150 ms window is real time
right after the `10` host command (~14.6 s) — consistent with "the
68000 kicks off a track and the sound CPU's self-driven player
diverges shortly after starting it."

### What MAME executes in that window: a table-driven register loader

The MAME PCs right at 14.7-14.85 s repeatedly enter this loop (address
correspondence confirmed against an earlier 1-second full-disassembly
capture, same addresses, same code — this loop is a shared subroutine
called from many places, not something unique to this one moment):

```
00160: ld  a,(hl)        ; register number
00162: inc hl
00163: ld  ($F800),a     ; YM2203 register-select port
00167: call $03BD        ; fixed-length push/pop-bc pad, no host wait
0016A: ld  a,(hl)        ; register value
0016C: inc hl
0016D: call $03B9        ; -> ld ($F801),a  (YM2203 data port), same pad
00170: cp  (hl),$FF      ; end-of-table marker?
00173: jr  nz,$0160      ; loop until $FF
```

A straight-line `(register, value)` byte-pair table walk, terminated
by `$FF`, with `HL` as the read pointer — this **is** the instrument
register loader (`$3B9`/`$3BD` write exactly the YM2203 data/register
ports the earlier `dbg_ym_we` trace was watching). Critically, the
loop itself has no host- or timer-wait inside it: given the same
starting `HL`, it is entirely deterministic. So the actual divergence
is not in this loop — it's in whatever computes the `HL` pointer (i.e.
which note/instrument to load next) before each call, which was
already configuring the TLCS-90's internal hardware timer
(`TRUN`/`TMOD`/`TCLK`/`TFFCR`/`TREG0-3`) during the very earliest boot
instructions traced. `rtl/tlcs90/nmk004_periph.sv` does implement that
timer (real prescale/compare-match counters, with its own comments
noting prior careful matching against MAME's `t90_timer_callback`/
`t90_timer4_callback`) — but the leading theory, not yet confirmed, is
that the same class of sub-1% residual per-instruction cycle-cost
imperfection documented for the CPU core compounds, via this timer,
into a one-tick-different note-advance point by ~14.7 s of elapsed
real time: individually tiny errors, invisible for 14+ seconds while
nothing depends on absolute timing, then large enough in aggregate to
shift which table offset a periodic timer-driven event loads from.

**Not yet done**: confirming the timer-drift theory directly (compare
the TLCS-90's own timer-compare event count/timing between the two
traces in the few seconds before 14.7 s, the way `cyc_diff.py` compares
instruction costs) or finding an alternative cause if it doesn't hold
up, and then the actual fix in either `tlcs90.sv`'s per-opcode cycle
table or `nmk004_periph.sv`'s timer logic.

### Third pass: the timer-drift theory is disproven; the real signature narrows the field

Did the confirmation above. Counted every PC hit on the TLCS-90's
interrupt vector addresses (`0x10 + irq*8` per `tlcs90.cpp`'s own
`take_interrupt`, cross-checked against its own `tlcs90_e_irq` enum —
`NMI=0x18`, `INTT0=0x30`, `INTT1=0x38`, `INTT2=0x40`, `INTT3=0x48`,
`INTT4=0x50`, `INTT5=0x60`) in both the MAME oracle and RTL cycle
traces, per second, across the full 20 s:

- The watchdog NMI (from the 68000's own `nmk004_x0016_w` keepalive,
  `0x080016/17`) fires **1094 times in both traces**, at 56-57/s
  throughout, matching frame rate exactly.
- GunNail's music firmware uses **Timer 1** (not T0/T4/T5 as first
  guessed): **3587 (MAME) vs 3584 (RTL)** fires over 20 s, ~198-199/s in
  both from ~3 s onward — a 3-event difference over 20 seconds is noise,
  not drift, and both stay in lockstep straight through the divergence
  point with no widening gap afterward.

**This directly disproves the timer-drift theory** — the peripheral
that was the leading suspect is not where the problem is; both its rate
and its phase already track MAME almost exactly, including for the 5+
seconds *after* 14.7 s where the instruction-level PC trace has already
diverged. So whatever branches differently at 14.7-14.85 s isn't
reading a timer value that disagrees between the two sides.

Re-examined the actual scale of the divergence to make sure "timer
drift" was even the right shape of theory to begin with: a fresh 90 s
YM-register-write count, per second, RTL vs. a fresh MAME capture of
the identical scenario (first independently re-run twice to rule out
attract-mode non-determinism — MAME reproduced **byte-for-byte
identical**, 0-line diff, so that's not a factor):

| | total instrument-reg writes over 90s | seconds with any activity |
|---|---|---|
| MAME | 20,160 | 76 of 90 |
| RTL | 2,832 | 10 of 90, in short isolated bursts |

Not a small phase shift or an occasional missed tick — MAME keeps the
music engine continuously active for the rest of the captured run
while the RTL's mostly falls silent apart from a few bursts. That rules
out "benign, self-correcting async jitter" as an explanation too (which
would show up as a *differently-ordered but similarly active* output,
not a near-total drop in activity) and confirms the user-audible
"static/stalled music" symptom is a real, substantial divergence, not
a rounding artifact.

Also checked, and already fine: the actual host command bytes
exchanged at the critical moment (`0x08001E`/`0x08000E`, the "play
track" `$10` command around frame ~819-822) are bit-for-bit identical
between MAME and the RTL — this was established in the first pass
above and re-confirmed here. And MAME's own `nmk004_device::write()`
(the handler for this specific register, unlike the deliberately
unsynchronized `nmk004_x0016_w` NMI line) does call
`machine().scheduler().synchronize()`, so this specific write is not
the same already-documented "scheduler-arbitrary" class of gap that
was found and closed as unfixable for mustang's NMI line.

**Where this leaves it**: CPU opcode timing (verified independently to
2/7779 residual for mustang), timer/NMI firing rate and phase, and the
host command content are all now checked clean. The divergence is a
real, localized, substantial event right at 14.7-14.85 s that these
checks don't explain — most likely a genuine state difference (a
register or RAM byte) that traces back to the identical-outcome but
different-iteration-count boot poll loop found in the first pass, or a
race at this specific moment not yet identified. Pinning it down needs
register/RAM-state-level tracing (not just PC) around 14.6-14.9 s on
both sides — a new capability, not yet built. No fix was attempted this
pass: the leading theory it would have targeted (the timer peripheral)
is now known not to be the cause, and guessing at a different fix
without first finding the actual mechanism isn't warranted.

### Fourth pass: register-state tracing built, root cause found and fixed

Built the register-state tracing the third pass called for.
`sim/oracle/capture_reg_trace.py` (new, mirrors
`capture_cyc_trace.py`'s mechanism) and a `TB_NMK004_REGS=<path>`
option added to `tb_gunnail.cpp` capture A/F/BC/DE/HL/IX/IY/SP
alongside PC at every instruction boundary, in the same "<cycles>
<PC> ..." shape so the two sides diff directly. `tlcs90.sv` gained
`dbg_bc`/`dbg_ix`/`dbg_sp` outputs (only `dbg_a`/`dbg_f`/`dbg_hl`/
`dbg_de`/`dbg_iy` existed before) to have the full register file
available.

Two real gotchas hit building the MAME side, both worth remembering:
- `tlcs90_device::device_start()` registers the accumulator as
  `state_add(T90_A, "~A", ...)` — tilde-prefixed — and never registers
  a standalone flags state at all, only the combined 16-bit `AF`. The
  debugger's plain expression evaluator (what `tracelog`'s own
  arguments are) has no way to reference a tilde-prefixed symbol
  (`~a` parses as *bitwise NOT of the expression `a`*, not "the state
  named ~A"), and a bare `a`/`f` silently resolved to *something* that
  happened to read as a constant 0x0A/0x0F for an entire 16-second,
  10-million-instruction capture — which looked exactly like a
  glaring, systematic MAME-vs-RTL register divergence before it turned
  out to be a symbol-name bug in the capture script, not a real value.
  Caught by checking how many *distinct* values each field actually
  took across the whole capture (`af`/`bc`/`hl` — real, unprefixed
  symbols — showed hundreds to thousands; the broken `a`/`f` showed
  exactly one). Fixed by capturing the working `af` symbol and
  splitting it into A (high byte) / F (low byte) in the script's own
  `reformat()`.
- A same-nominal-time window cut across both traces only works at a
  point already confirmed to have near-zero relative offset (checked
  via the third pass's own landmark search) — cutting both at, say,
  t=13.5 s and walking the ordered PC match from index 0 of each
  failed after 5 instructions, not because the CPUs had actually
  diverged that early, but because 13+ seconds of even a tiny relative
  rate difference is enough absolute offset (tens of thousands of
  instructions, at ~660K instr/s) to make "the same nominal second on
  each side's own clock" not correspond to the same point in execution
  at all. Anchoring the window at 14.60 s — a point the third pass had
  already confirmed aligns to within tens of milliseconds — worked.

**Result — the first divergence, isolated to a single instruction.**
The ordered register+PC walk from a 14.60 s anchor matches every
single register on both sides for the first ~200 instructions, then
stops cold: at PC `$0DA1` (`jr ,$0D9C`, so the flags shown are the
result of the *preceding* instruction, `$0DA0: dec a`), F differs by
exactly one bit — MAME `0x4A`, RTL `0x42`, XCF (bit 3) set in MAME,
clear in RTL — while A itself matches on both sides. A single-opcode
flag bug, not a value bug: `dec a`'s numeric result was right, the
flag it left behind was wrong.

**Root cause 1 — XCF never set on 8-bit INC/DEC.** MAME's reference
(`tlcs90.cpp`, `case DEC:`/`case INC:`) computes `F = (F & (IF|CF)) |
SZHV_dec[a8]`, then, as a genuinely separate step, `if (a8 == 0) F |=
XCF` — XCF is unconditionally *recomputed* every INC/DEC (cleared
unless the result is exactly zero), never left holding a stale value.
`tlcs90.sv`'s own `szhv_inc8()`/`szhv_dec8()` — shared by all four of
OP_INC, OP_DEC, OP_INCX, OP_DECX — never included that bit at all, so
XCF was silently cleared to 0 unconditionally on every 8-bit INC/DEC,
regardless of the result. Consequence: XCF is INCX/DECX's own
execute-gate (`if (F & XCF) { ...actually increment... }` in the
reference — the mechanism TLCS-90 uses to chain a 16-bit increment or
decrement across two 8-bit register operations, "INC lo; INCX hi",
where INCX only fires when the low byte's own INC just wrapped to
zero) — a permanently-clear XCF means any such chained pointer or
counter can *never* advance its high byte. Fix: add the same
"`XCF = (result == 0)`" term directly into `szhv_inc8()`/`szhv_dec8()`,
so all four callers get it at once.

**Root cause 2 — `SET`/`RES` on a register operand silently discarded**
(found immediately after re-measuring with fix 1 alone — the match
extended from 193 to 4,086 instructions before hitting a *second*,
different bug). `tlcs90.sv`'s `OP_SET`/`OP_RES` execute block
unconditionally wrote its result to a *memory* address (`addr <=
eff2; dout <= ...; mem_wr <= 1`), with no check for `mode2 == M_R8` —
unlike OP_INC/OP_DEC right next to it, which correctly branch on
`mode1 == M_R8` to write back to a register via `a_or_r8_write()`
instead. `mode2 == M_R8` here is this opcode group's compact "`bit
n,A` / `res n,A` / `set n,A`" form (the register operand is
*implicit* — decode never assigns `d2_r2e` for it, unlike every
genuine register-selected LD/ADD/etc. form, so it silently defaults
to 0/`R8_B`, confirming this path was never meant to look up a
register selector at all — the target really is always A). Net
effect: `res 7,a` (and every other register-form `bit`/`res`/`set`)
was a complete no-op on the register — the bit-modified value was
computed and then discarded into whatever `eff2` happened to resolve
to for a register operand, never reaching A at all. Fix: branch on
`mode2 == M_R8` and call `a_or_r8_write(R8_A[2:0], result)` in that
case, mirroring OP_INC/OP_DEC's own pattern exactly.

**Verification.**
- Register+PC match now extends to 4,086 instructions with fix 1 only
  (from 193), then to 4,086+ with both — the walk stops around
  14.6085 s on a value that looks like the same already-documented,
  already-accepted "scheduler-arbitrary NMI phase" class of artifact
  (a port-toggle byte one NMI-firing out of phase — not a functional
  bug, matches the mustang investigation's own closed finding), not a
  new CPU bug.
- The real-world test: instrument-register write activity over the
  full 90 s, RTL vs. a fresh MAME capture of the identical scenario —
  before the fix, 2,832 total writes, active only 10 of 90 seconds;
  **after both fixes, 20,136 writes active 77 of 90 seconds, against
  MAME's own 20,160 active 76 of 90** — the per-second activity
  pattern now tracks MAME's almost line for line for the entire
  capture. This is the actual, audible symptom the user originally
  reported, now fixed.
- Both fixes live in the CPU core (`tlcs90.sv`) shared by every
  TLCS-90 user in this project, not anything gunnail-specific.
  Regression swept: `raphero` (bare sound-CPU role) reference sim
  runs unchanged (frame count, OKI/YM write counts identical before
  and after); `mustang`/`bioship`/`vandyke`/`blkheart`/`acrobatm`/
  `strahl`/`tdragon`/`tdragon1`/`hachamf`/`hachamfb`/`macross`/`bjtwin`
  (NMK004 sound-MCU and NMK-215/protection-MCU roles) all rebuild and
  run cleanly, no crashes or hangs. `gunnail_hw`/`raphero_hw` (the
  real hardware-path sims, SDRAM caches and all) re-verified: ROM and
  OKI golden-byte audits still 0 wrong.
- **Were failing at the time (fixed later the same day — see the last
  bullet)**: the project's own standalone TLCS-90 opcode self-tests
  (`sim/rtl/tlcs90/tb_*test.cpp` — banktest, blocktest, rldtest,
  muldivtest, ldarcallrtest, switest, extest) were found already
  failing on the *unmodified* tree (confirmed via `git stash`, e.g.
  `extest` fails identically with or without this session's changes) —
  a pre-existing test-harness issue, unrelated to and not caused by
  this fix, out of scope here. Given several of the failing checks
  (switest's `F restored by RETI (CF=1,XCF=1)`, banktest's own IX-
  relative store) plausibly exercise the exact flag/opcode paths this
  session just changed, these tests are worth fixing and re-running
  as a real regression gate before trusting this area of the CPU core
  again — not done in this pass.
- **Rebuilt for hardware**: `releases/Raphero.rbf` and
  `releases/Gunnail.rbf` (the only two bitstreams whose CPU core
  changed — `Macross2.rbf` doesn't use `tlcs90.sv` at all, its sound
  path is Z80/jt03). `docs/hw-bringup.md`'s "Sound effects corrupted"
  section below and the OKI mixer-gain fix are unrelated, unaffected
  by this change.
- **Audio band correlation re-measured on the board** (2026-09-10,
  later the same day, shipped `Gunnail.rbf`, attract from boot, MAME
  `-wavwrite` 100 s vs a 110 s `arecord` capture, `tools/audio_compare.py
  --offset-search 20`): 0.919 mean band corr / 0.951 envelope over the
  full 100 s at −1.1 dB, and **0.968 / 0.997 over the first 60 s** at
  −1.3 dB — up from 0.849 / +2.4 dB before the two CPU fixes, and now
  in Thunder Dragon 2's own hardware range (0.987). The 100 s figure is
  lowered by the attract demo's known post-~1-minute divergence from
  MAME (RNG/timing, see the GunNail section), not by the sound path.
- **The TLCS-90 standalone self-tests were fixed the same day** (see
  `docs/known-issues.md` NMK-4): they had been silently failing since
  `tlcs90.sv` gained its `cen` input, because the raw-module
  testbenches never drove it. With `top.cen = 1` all eight pass —
  including `switest`'s "F restored by RETI (CF=1,XCF=1)", which
  exercises the XCF path this fix changed. None of them covered the two
  bugs themselves, so a dedicated gate was added next (NMK-5).
- **`tb_flagtest` added, and it found a third bug** (2026-09-10,
  `sim/rtl/tlcs90/gen_flagtest_rom.py` + `tb_flagtest.cpp`, `make
  run-flagtest`, folded into `make run-selftests`): nine checks — XCF
  set on a zero INC/DEC result and cleared on a non-zero one with CF
  preserved, INCX/DECX firing exactly once across a memory pair (a
  never-firing and an always-firing INCX each fail a distinct check),
  and SET/RES `b,g` writing back to the register. The last one is
  deliberately run on B and C as well as A, with bit choices that would
  visibly corrupt A if the writeback went there regardless of `g` —
  and it did: the SET/RES fix above wrote back to `R8_A`
  unconditionally, which is right for prefix `0xFE` (`g=A`, the only
  form GunNail's firmware uses) and wrong for `0xF8..0xFD`. The
  reference decode is `R8( 2, b0 - 0xf8 )` — the prefix byte's own
  register — and the RTL's `S_PFX_SEL` already fills `r2 <= gg` and
  `val2 <= r8_read(r2)` for this group, so `r2[2:0]` was both where the
  value came from and where it had to go back. Negative controls: the
  RTL from before the GunNail fixes fails 6/9 checks (both XCF flag
  checks, both INCX/DECX "hi ran once" checks, both SET/RES checks);
  the write-to-A version fails exactly the two register-writeback
  checks; the current RTL passes all nine and the other eight
  self-tests. No shipped game is known to execute `set/res b,g` with
  `g≠A`, so no behaviour change is expected on the board — Raphero and
  Gunnail were rebuilt anyway so `releases/` matches the RTL.
  Verification of that rebuild: `gunnail_hw` sim ROM audit 13.3M
  words / 0 wrong, OKI audits 0/0, NMK-215 still emitting its 2 NMK214
  config writes; `raphero_hw` ROM audit 18.9M / 0 wrong, OKI1 0 wrong,
  OKI0 1 wrong of 727,249 — and re-running that exact sim against the
  previous `tlcs90.sv` gives identical instruction counts and the same
  single byte, so it is pre-existing (now tracked as NMK-15), and the
  CPU change has no observable effect on Raphero's execution at all.
  Quartus: Gunnail +0.444 ns setup, Raphero +0.011 ns (positive; SEED
  23 unchanged). Both RBFs deployed, MD5-verified, boot into their
  attract demos with continuous audio (Raphero 23/25 s active from
  load, Gunnail 21/25 s including the ROM-upload gap). The full
  sim-only sweep of every TLCS-90 user (mustang, bioship, vandyke,
  blkheart, acrobatm, strahl, tdragon, tdragon1, hachamf, hachamfb,
  macross, bjtwin's `run-prot` variant, gunnail, raphero — run
  concurrently) is clean too; the three games sharing the NMK-215
  protection firmware (gunnail, macross, bjtwin-prot) all report the
  identical 2,824,804-instruction / last-PC `$0088` MCU run, so that
  firmware is provably untouched by the writeback change.

### Fifth pass: the residual is a 3-tick Timer-1 phase offset from boot

The fourth pass left one open thread (docs/known-issues.md NMK-3): after
the two CPU fixes the register walk from the 14.60 s anchor still
stopped, ~4,000 instructions in, on "a port-toggle byte one NMI out of
phase". That was a guess. Disassembling the NMK004 boot ROM
(`mame/unidasm -arch tmp90840`, mind that `-skip` needs `-basepc` or
every address prints 0x10 low) pins it: the NMI vector `$0018` jumps to
`$0079`, which only reloads the watchdog countdown `($FF30)` from
`($EFFC)`; the divergent PC `$009C` is in the **Timer-1** handler at
`$0082` — `di; decw ($FF30); jr z,<halt>; …five sequencer calls…;
ld a,($FF80); xor a,$08; ld ($FF80),a; ld (P4),a; reti`. P4.3 is a
heartbeat that flips every T1 tick, so the mismatch means one side had
taken one more Timer-1 interrupt. And MAME's `check_interrupts()`
returns early when IF is clear for *every* source, NMI included, so
NMI gating is identical on both sides — the NMI was never involved.

Counting T1 handler entries in both 16-second register traces
(`t1stats.py`; the MAME trace prints PC as five hex digits, so compare
numerically): steady-state period identical (median 40,316 vs 40,320
cycles; 198-199 entries/s on both), but the cumulative MAME−RTL
difference per second is 0, 1, 3, 3, 3, … 3 — the RTL loses one tick
in second 1 and two in second 2, during the boot phase where the timer
runs its long ~113k-cycle mode, and is then exactly three behind for
the remaining thirteen seconds. Three is odd; hence the parity flip.
The first tick lands 4.5 ms later on the RTL (0.5611 vs 0.5566 s), the
same boot-handshake timing the second pass saw as the poll-loop
iteration difference — where the timer starts relative to the 68000's
boot progress, which MAME resolves at scheduler granularity.

What the offset does: the host's "play track" commands arrive with
the same bytes (`00` then `10`), the same 12.5 ms spacing, on both
sides (`$01DD` is the per-tick command poll: `ld a,($FB00)`, dedup
against `($FF21)`, append at `$FF00+($FF22)`), but relative to a
sequencer running ~15 ms behind they fall on different ticks — at one
tick the RTL's queue holds 2 commands where MAME's holds 0, which is
exactly the "BC′ 0002 vs 0000" the widened trace shows (`$0201`:
`ld b,($FF22)`, the queue count, with the alternate register set
live). From there the two execute the same program one tick apart.
Re-anchoring the register walk later in the window then locks onto the
per-channel loop one iteration out of phase (IX F600 vs F640 is
channel 0's vs channel 1's block) — the tool's limit, not divergence.
The right yardsticks are semantic: the track-start routine `$0A63`
runs 36 times on both sides; YM instrument writes match to 0.1% over
90 s; band correlation 0.968. Closed as benign, with numbers.

One apparent discrepancy fell out (NMK-17) and was run down the same
day: in the boot phase the Timer-1 intervals are ~113k cycles and the
RTL's are 81 cycles (0.07%) shorter than MAME's, while the
free-running mode agrees to 0.01 cycles (40,319.99 vs 40,320.01 =
8 × 16 × 315). A `+define+TIMER_TRACE` in `nmk004_periph.sv` logs every
TREG/TCLK/TMOD/TRUN write, and it shows the boot phase is not a timer
mode: from 0.57 s the sound program stops the timers, rewrites
TMOD=04 / TCLK=aa / TREG0..3 and restarts with TRUN=23 every ~14.1 ms
— each "interval" is one 40,320-cycle hardware period plus ~73k
cycles of software between restarts (its first 0.05 s also use
T0/T1/T2 as one-shot delays, TRUN 27→25→21→20→27, whose start→stop
spans match 8 × prescale × TREG on the RTL exactly). The hardware part
is identical by the free-running measurement, so the 81 cycles are in
the software part: 0.11%, the CPU core's known per-instruction
cycle-cost residual against MAME's cycle table. Not a timer bug; the
free-running mode was always exact. Closed.

## Sound effects corrupted on hardware: the OKI sample fetch

Reported after the fixes above: music fine, sound effects noisy/garbled
in both games. Hardware-only again, and again a consumer that the
reference sim's ideal memory hides.

`rtl/third_party/jt6295/hdl/jt6295_rom.v` shares one ROM port between
the four ADPCM channels and the phrase-table (ctrl) reads. Each channel
slot (cen_sr4, ~412 clk_sys) it puts the sample address on `rom_addr`
for two cen_sr32 periods (~104 clk_sys) and keeps whatever `rom_data`
shows on the last clock of the second one; the rest of the slot
`rom_addr` carries the ctrl address. Only the ctrl read waits for
`rom_ok`; the sample read assumes an asynchronous ROM. Behind
`rom_cache1_byte` (a single 4-byte line) on the arbitrated SDRAM port 1
the two addresses evicted each other every slot, so every sample byte
was a full SDRAM round trip competing with the Z80 and the other OKI,
and any trip that missed the window handed the decoder the previous
line's byte. ADPCM is differential with adaptive step size, so one bad
nibble smears into a burst of noise until the phrase ends.

Measured, not inferred: a Verilator-only audit in `tdragon2_core.sv`
(`g_oki_hw`, hierarchical references into `oki0_chip.u_rom`) counts
sample latches where the cache was not ready. Before the fix, over 211
frames of the `tdragon2_hw` testbench at the 100MHz-equivalent SDRAM
ratio: 218,676 of 582,312 sample bytes stale (37.6%), the same on both
chips. The audit lines are printed by `tb_tdragon2_hw` ("OKI ADPCM
fetch audit", "OKI cen stall audit").

Fix, `rtl/oki_rom_cache.sv`, replacing `rom_cache1_byte` on both OKIs
(HW path only; the sim path keeps its registered arrays):

1. 16 fully-associative 4-byte lines with NRU replacement, so the four
   channels' current lines and the ctrl line all stay resident, plus a
   sequential prefetch of the next line once a channel has consumed
   byte 2 of its current one (ADPCM phrases are read strictly
   sequentially). Unit test `sim/rtl/oki_rom_cache_test` drives the
   jt6295 slot pattern against the real `sdram.sv` + model: 99.95% of
   sample bytes resident on first presentation, 0.10% of time stalled.
2. `stall` = byte not resident, ANDed out of the chip's `cen`. Every
   internal timing pulse of jt6295 derives from `cen`
   (`jt6295_timing.v`), so a miss now freezes the chip for the few
   clocks the fetch takes instead of feeding it a wrong byte; the write
   strobe is sampled on `clk` (`jt6295_ctrl.v` `last_wrn`), so Z80
   writes during a stall are not lost.

Both testbenches also gained `TB_DUMP_AUDIO=<path>` (raw signed 16-bit
mono at 48 kHz from `audio_l`) so sim audio can be compared with MAME's
`-wavwrite` output; until now the sims had no audio output at all,
which is how a 37% sample corruption rate went unnoticed.

### The second bug the first one exposed: the Z80 read mux

The first hardware build with the new cache played clean sound effects
but went completely silent, FM included, from the attract's second
music change until the next one — deterministically, at the same
seconds of the recording every run, while MAME plays through. The
`tdragon2_hw` sim never showed it. Found with a diagnostic overlay
(`DBG_SND_PAINT` parameter on `tdragon2_core`, off by default): the
core paints live status bits into the top-left corner of the picture —
cache-stall flags, Z80 opcode-fetch/wait-state flags, both OKIs' busy
nibbles, the Z80 PC latched at each M1, the sound latch — and the
MiSTer's own `screenshot` command reads them back exactly. During the
silence the Z80 was executing, unstalled, at PC $0018-$001B:

    0018: in   a,($00)   ; YM2203 status
    001a: rlca           ; bit 7 (BUSY) -> carry
    001b: jr   c,$0018

The YM2203 busy-wait. It never saw BUSY clear because it was never
reading the YM2203: the Z80 read mux tested the address-only memory
decodes (`sel_z80_rom` = `z80_a < $8000`, bank, RAM) before the I/O
decodes, and on an `in a,(n)` the Z80 drives register A onto A15..A8 —
so with A below $E0 the "status" was a program-ROM, bank or RAM byte at
`{A, n}`. The loop then chased ROM contents (`rlca` of the byte it just
read becomes the next address's high byte), and whether that chain ever
reached a byte with bit 7 clear depended on which line the Z80's ROM
cache happened to hold at that instant. The old OKI cache's SDRAM
traffic left the cache in a state where the chain terminated; the new
one's did not. Fixed by qualifying every memory select in the read mux
with `z80_mem_re` (the write decodes already were). This bug was
present in every build of both games; MAME reads the real status.
`rtl/gunnailb/gunnailb_core.sv` (sim-only) had the same unqualified mux;
it was fixed the same way as NMK-14 (see `docs/known-issues.md` for the
before/after sim counts).

### The third bug: OKI2 was reading the BG tiles

With the cache and the mux fixed, the `tdragon2_hw` sim still sounded
wrong against the reference sim, so a golden-byte audit was added
(`g_oki_hw`, Verilator only: every sample byte the chip latches is
compared with the ROM image loaded from `OKI1_ROM_FILE`/`OKI2_ROM_FILE`,
which the HW top now passes for this purpose alone). OKI0: 0 wrong of
727,273. OKI1: 608,053 wrong — at address 0, with the cache reporting a
hit. The cache's fill print showed why: it fetched SDRAM word 0x060000,
not 0x460000. `BASE_WORD_OKI2` was written `23'h8C0000 >> 1`, and
0x8C0000 needs 24 bits; the 23-bit literal silently dropped bit 23, so
the constant was 0x0C0000 >> 1 — the BG tile region. The second OKI
had been decoding tile graphics as ADPCM in every build, on hardware
and in the HW sim alike (the reference sim loads the hex directly and
was right, which is why the HW sim's audio was louder and less like
MAME than the reference's). Every 2-chip NMK112 game puts the second
sample ROM above 8MB in this layout, so this affected both games. The
base constants are now 24-bit byte offsets with the word offsets
derived from them.

Note on the MiSTer screenshot rows for the overlay: the native
384x224 screenshot proved to start some lines into the core's frame
and repeat lines (the box now runs the 640x480 output mode), so decode
overlay rows by their marker colour, never by absolute y.

## NMK-15: the one OKI byte the fetch-hazard fix left (2026-09-10)

The `raphero_hw` golden-byte audit had one residual: `oki0 727249
latches / 1 wrong`, and the same latch counted as "unserved" — the chip
latched a sample byte while `rom_ok=0`, which the `cen` stall gating
of the OKI section above exists to make impossible. Identical against
the previous `tlcs90.sv`, so not a CPU-core regression.

**First hypothesis, refuted.** The obvious one-clock hole: jt6295's
internal pulses (`cen_sr32` etc., `jt6295_timing.v`) are *registered*
copies of the gated `cen`, so the ADPCM latch (`adpcm_dout <= rom_data`
on the clock `st` leaves state 2, `jt6295_rom.v`) lands one clock after
the stall check that let the `cen` through. `oki_rom_cache`'s
"never evict the line in use" guard is only evaluated when a prefetch is
*issued*; its fill lands many clocks later, and the chip could have
moved onto that line — a fill in that clock would clobber the byte
being latched. A guard was added to drop such a fill (kept: it closes
a real sibling hazard), and the audit went to 0 wrong — but the
dropped-prefetch counter read **0 on every OKI cache**; the 16 drops
were all in the audio CPU's program cache (also an `oki_rom_cache`),
and OKI0's stall and latch counts had shifted by a few clocks. The
byte had been *displaced*, not fixed. That is exactly the failure
mode a "fix" can hide behind when the only evidence is a count going
to zero.

**The diagnostic that settled it.** The audit's mismatch branch now
prints the previous two clocks' address, residency and fill activity
(`raphero_core.sv`, `g_oki_hw`). On the pre-fix cache: one clock
before the latch the address was `0x1D0000`, resident, gated `cen`
passed; at the latch it was `0x170000`, not resident; **no fill on
either clock**. Same 64 KB-page offset (`0x0000`), different bank —
an **NMK112 bank-register write** landing on the very edge that
sampled the passing `cen`. The bank registers update on `reg_we` on
any clock (the sound CPU's write is sampled on `clk`, not `cen`) and
the remap is combinational, so the cache sees a new, non-resident
address inside the registered-`cen` window and the chip latches
whatever `data` shows for it (the default line's byte, `0xBB`). The
chip's own address pipeline cannot cause this — its updates are
cen-aligned and ten clocks apart — and jt6295's phrase-start address
load is `cen4`-aligned too, so NMK112 writes are the only
asynchronous path. Gunnail has no NMK112, hence its permanent 0/0.

**Fix.** `nmk112.sv` gains a `hold` input: a write arriving while
hold is high is captured in a one-entry slot and applied on the next
clock. Each core drives `hold = oki_cen & (~oki0_stall | ~oki1_stall)`
— "a gated cen is passing *this* clock" (combinational: the harmful
write is the one coincident with the `cen`, since it lands on the edge
that samples it; a registered copy would block the wrong clock). The
deferred write lands after the latch; the chip takes the old bank's
byte — a 25 ns shift, inside MAME's own sub-sample write/fetch
ordering, and inside the real ROM's access time. `oki_cen` is 1-in-10,
so one clock always suffices. tdragon2's Z80 `io_we` is a level held
for the whole I/O cycle and simply re-captures the same write each
clock (idempotent); only a *different* write within one clock of a
pending one could be lost, which neither CPU can produce — the
Verilator counter for that case reads 0.

**Proof, the right way round.** The pre-fix cache (no prefetch guard)
with the hold alone, on the *original* timeline — same 727,249
latches, same 10,829,725 stall count as the failing run — gives 0
wrong / 0 unserved, 40 writes deferred, 0 lost. `gunnail_hw`,
`tdragon2_hw` and `macross2_hw` stay clean on the final RTL;
`tdragon2_hw` shows the hold firing on its Z80 path as well. The
`oki_rom_cache` unit test is unchanged (99.94% resident, 0 wrong,
0.12% stall).

**Build note.** Gunnail's first rebuild with the cache guard missed
timing by −1.066 ns; a `quartus_sta` path report showed every failing
path on `video_timing hcount[4] → video_macross2 tile_rgb_r[18/19]` —
the compositing path, untouched — i.e. placement wobble, and `SEED 3
→ 11` gave +0.378 ns. Raphero then did the same twice on the final
RTL — `SEED 23` −0.132 ns on the framework's `d[14] → hdmi_out_d[14]`
register, `SEED 31` −0.080 ns inside `ascal` (`o_vacpt[0] →
o_vpixq_pre[2].b[5]`) — neither anywhere near the cores; seeds 7, 19
and 43 run in parallel all passed (+0.069, +0.356, +0.429) and 43 is
now the tracked seed. Macross2 passed first time (+0.132). Worth
remembering: check *which* paths fail before attributing a miss to the
change that triggered the rebuild — and that three parallel Quartus
runs plus the scratch copies of earlier builds overflow the 16 GB
`/tmp` tmpfs (all three died with "Disk is full"); delete finished
`build_*` copies before launching a batch.

All three RBFs deployed and MD5-verified: tdragon2 20/20 s audio
active from load, gunnail 16/20 s (ROM-upload gap), raphero 18/20 s,
each in its attract demo.

## Autofire (tdragon2 and macross2)

OSD `P1 Autofire` / `P2 Autofire` (status[12:10] / [15:13], default
Off, unconditionally shown — no longer hidden for macross2 as of
2026-09-10; see below). The pattern is clocked by the game's own
vblank (~56 Hz): 10Hz = 3 frames on / 3 off, 12Hz = 2/3, 15Hz = 2/2,
20Hz = 1/2, 30Hz = 1/1. The phase counter restarts on each new press
so a tap fires on its first frame. While a player's autofire is on,
that player's button 3 is OR'd in as a plain non-autofire button 1 and
its own bit is not sent to the game — `af1_en`/`af2_en` (`Macross2.sv`)
used to be gated `& ~game_macross2`, both to match the menu being
hidden for that game and because macross2's own `INPUT_PORTS_START`
has no 3rd button at all. Removing the gate is safe, and the OR path
is not dead on macross2 either: since macross2.mra now declares the
full 5-entry `<buttons>` list (the gamepad Coin fix), a gamepad's
Button 3 *is* mapped, and while autofire is on it acts as the plain,
non-autofire Button 1 — exactly as on tdragon2. With autofire off it
does nothing, as the game itself never reads that bit. Saved with the
other status bits by OSD > System > Save settings.

## DIP switches in the OSD

Both .mra files already declared every DSW1/DSW2 option from
nmk16.cpp, but MiSTer only renders its DIP submenu where the core's
CONF_STR carries a `"DIP;"` line — `Macross2.sv` now has one, between
Orientation and Reset. The submenu lists the eight options per game,
Enter cycles a value (Right/Left switch OSD pages instead), and MiSTer
saves every change by itself to `config/dips/<setname>.dip` (8 bytes,
the `<switches>` bytes) and restores it on the next load of that .mra;
"Reset to apply" because the games sample the switches at boot. The
core side is unchanged: the bytes arrive through ioctl index 254
(`dip_sw`), with F2's service-mode toggle XORed on top.

Two .mra corrections found while testing: `bits` is a RANGE
("start,end"), so the coin fields must be `bits="8,11"` and
`bits="12,15"` — as `"8,9,10,11"` they were read as a 2-bit field and
1C_1C showed as 1C_4C; and Service Mode is active low
(PORT_SERVICE_DIPLOC), so its ids are "On,Off". Verified on the box by
driving the OSD with `tools/mister_keys.py`: Lives 3 -> 1 saved as
37 FF, still 1 after a core reload, back to 3 (F7 FF) afterwards;
macross2's submenu shows Language and 1C_1C coins. F12 from inside a
submenu returns to the core page; a second F12 closes the OSD.

## Orientation option (vertical games upright over HDMI, both quarter-turn directions)

tdragon2 is MAME ROT270: the board draws it on its side. Same for
gunnail and raphero. `Macross2.sv`/`Gunnail.sv`/`Raphero.sv` each
offer `Orientation: Horz/Vert 270/Vert 90` in the OSD (`H0O[9:8]`,
default Horz — 2 status bits now, was a single bit before 2026-09-10).
Both "Vert" choices enable the framework's `screen_rotate` (the second
module in `sys/arcade_video.v`) and raise FB_EN so the scaler shows
the DDR3 framebuffer it writes into; "Original" aspect follows to 3:4
for either. "Vert 270" is `rotate_ccw=1` — the MAME-correct direction,
same as the original single-choice "Vert" — and "Vert 90" is
`rotate_ccw=0`, the opposite quarter-turn. Both present the game
upright on an HDMI monitor; the reason to offer both is that on a real
vertical cabinet, which physical direction the CRT/LCD is actually
mounted in is a property of that cabinet, not of the game or the
core, and only one of the two choices will match a given cabinet's
DDR3->scaler->HDMI output orientation without the operator manually
rotating the physical display. With Horz selected, `no_rotate` keeps
FB_EN low, nothing touches DDRAM and the scaler takes the direct VGA
path as before — the core's own video pipeline is not in the loop
either way. In `Macross2.sv` the entry is hidden (status_menumask bit
0) for macross2, which is horizontal (and gets its own Flip screen
option instead, below, which works for both games); in
`Gunnail.sv`/`Raphero.sv`, which only serve vertical games, it's shown
unconditionally. All three hide it under direct_video, where the
framebuffer path does not exist; `no_rotate` is forced in that case
too. The framebuffer ports need `MISTER_FB=1` in the .qsf, which is
also what compiles ascal's DDR read path into the framework — that
costs a little slack on the HDMI PLL domain (see the build notes in
the commit).

## H Shift / V Shift options (sync-position trims for CRT users, NMK-2)

The sync placement (`hsync` at hcount 440..471, `vsync` at vcount
244..246 of the 512x278 raster, active x 28..411 / y 16..239) was
always a documented placeholder — this board's real CRT sync timing
isn't published anywhere this project has sourced, and the sim/HDMI
paths don't care (the scaler frames the picture by DE). Rather than
guess, each core now exposes the position as two OSD trims (added
2026-09-10) so a baseline can be measured on real CRT equipment:

- `H Shift` (status[21:18]): 0, +2 .. +14, -16 .. -2 px, listed in
  two's-complement order so the 4-bit value 0 is the shipped
  placement (hsync at 440). `V Shift` (status[27:22]): 0, +1 .. +20,
  -20 .. -1 lines (41 entries, 6 bits, value 0 = default).
- Mechanism: only the sync pulses move; the DE window (the picture)
  does not. Positive = picture right / down on the CRT = sync
  *earlier*, i.e. start = nominal minus the shift. On a CRT, moving
  the sync earlier makes the retrace happen sooner, so the same
  active video lands further right/down on the tube.
- H range: hsync start 426..456 (+32 wide) stays inside hblank
  412..511 for every setting.
- V range and the re-centred nominal (second pass, same day): the
  first cut kept the original vsync start at row 244 and could only
  offer +4 / −8, because only four blank lines precede row 244 (active
  video ends at 239). A ±20 range asked for on the CRT side cannot fit
  around that zero, so the nominal pulse is now placed in the middle of
  the 54-line vblank — which is one contiguous interval, rows 240..277
  followed by rows 0..15 of the next frame — at row 264. The RTL works
  in a blank-relative index (rows 240..277 → 0..37, rows 0..15 → 38..53;
  active rows map to 54..277 and can never match), nominal 24, range
  4..44 = row 244 .. row 6 of the next frame, pulse end ≤ 47: every
  setting stays in blanking, and the pulse may straddle the frame wrap.
  Consequence, stated plainly: the CRT default moved 20 lines compared
  with the previous build (picture 20 lines further *up* the tube at
  V Shift 0); the previous placement is exactly `V Shift +20`. HDMI is
  unaffected either way (DE-framed).
- Persistence is the MiSTer's own (OSD > System > Save settings).
  Once a good baseline is found on a CRT, fold it into the constants
  and keep the trims at 0 = that new baseline.
- Verified on the box (all three RBFs rebuilt first time, Macross2
  +0.263 / Raphero +0.541 / Gunnail +0.359 ns): both entries appear
  and cycle as listed (H wraps 0 → +14 → −16 → −2 → 0, V 0 → +4 →
  −8 → −1 → 0). Over HDMI the picture does not move at all — the lit
  window in a 640x480 capture is x 58..541 / y 26..453 at H+14 and at
  V+4, exactly the documented game area, where a 14-px source shift
  would be ~23 px — because the scaler frames by DE, which the trims
  leave alone. So the trims are analog-only by construction; the CRT
  measurement itself has to happen on real CRT equipment (this
  environment captures HDMI only).
- Second pass (±20 V range, re-centred nominal) verified the same way:
  all three RBFs rebuilt first time (Macross2 +0.335 / Raphero +0.296
  / Gunnail +0.403 ns), deployed, MD5-checked; on tdragon2 the 41-entry
  V list cycles 0 → +20 (twenty presses) → −20 (one more) → 0 (twenty
  more), i.e. the list closes exactly; HDMI framing unchanged at both
  extremes — at −20 the lit window is x 58..541 / y 26..453 (a
  black-background title, identical to every earlier dark-scene
  capture), at +20 it is 21..617 / 16..463 (a bright full-window
  scene, identical to the earlier bright-scene capture at shift 0 —
  the capture box bleeds a few pixels at the edges on bright content),
  where a 20-line source shift would be ~43 px. Box left at 0/0.

## Flip screen option (all four games, upside-down over HDMI)

`screen_rotate`'s own `flip` input only takes effect while `no_rotate`
is asserted (`do_flip <= no_rotate && flip` in `sys/arcade_video.v`) —
it still routes through the DDR3 framebuffer (`fb_en` is raised on
`~no_rotate | flip`, not just `~no_rotate`), but writes pixels into it
in reverse raster order instead of doing a quarter-turn, producing a
180-degree upside-down image with no rotation. Aspect stays 4:3 either
way, since `video_rotated` (which drives the 4:3-vs-3:4 choice) is
tied to `~no_rotate`, and `no_rotate` stays asserted for a flip-only
selection.

macross2 is horizontal, so it doesn't use Orientation — `Macross2.sv`
offers `Flip screen: Off/On` (`H2O[17]`, default Off) for it, always
meaningful since macross2 is permanently `no_rotate`. tdragon2,
gunnail and raphero are all MAME ROT270 (vertical), so for them Flip
screen only takes *visible* effect when their own Orientation is left
at Horz — an operator playing one of these games un-rotated (the way
the board naturally outputs it) on a HORIZONTAL monitor that happens
to be mounted upside-down (added 2026-09-10, extending the option
originally built for macross2 alone; requested explicitly for this
use case). `Macross2.sv`'s own `flip` wire dropped its `& game_macross2`
term to cover tdragon2 too — the option is hidden (H2) only under
direct_video now, not per-game. `Gunnail.sv`/`Raphero.sv` reuse
Orientation's own `H0` tag/mask for their new `Flip screen` line
(same direct_video-only hide condition), rather than adding a new
status_menumask bit.

Persistence is the MiSTer's own: OSD > System > "Save settings" writes
`config/<mra name>.CFG`, and the option(s) come back on the next load
of that .mra. The original single-choice Orientation was verified on
the box by driving the OSD with `tools/mister_keys.py` (F12, cursor
keys, Enter; Right/Left switch between the Core and System pages) and
capturing HDMI before/after and after a core reload; the expanded
3-way Orientation and macross2-only Flip screen were added and
verified 2026-09-10; Flip screen extended to tdragon2/gunnail/raphero
and autofire enabled for macross2 followed immediately after, same
session — all confirmed on the box by capturing the un-flipped and
flipped Horz frame for each of tdragon2/gunnail/raphero (HUD/text
elements land on the opposite side and upside-down in the flipped
capture, not just re-colored) and by reading the P1 Autofire OSD value
back after setting it on macross2. Persistence of the new options
(NMK-12) was then verified explicitly on all three cores, both
directions: Orientation Vert 90 / Flip screen On / H Shift +14 /
V Shift +20 saved, core reloaded, all four read back; defaults
restored, saved, reloaded, defaults read back. When scripting this
with `tools/mister_keys.py`, remember F12 *toggles* the OSD: the key
sequence has to track whether the menu is open, or the presses go
into the game. `Raphero.qsf`'s `SEED` moved 19 ->
23 in the same pass: the Flip screen addition alone pushed the build
just far enough that `SEED 19` missed timing (setup slack -0.065 ns);
`SEED 23` in a fresh scratch rebuild passed (+0.255 ns) and was
persisted into the tracked .qsf — same chronic near-100%-utilization
sensitivity as every other Raphero timing note in this file, not a
new problem.

## Keyboard input (MAME default keys)

`Macross2.sv` decodes hps_io's `ps2_key` stream into held-key
registers and ORs them into IN0/IN1 next to the joysticks, always on,
using MAME's default bindings: P1 arrows + LCtrl/LAlt/Space + `1`;
P2 R/F/D/G + A/S/Q + `2`; coins `5`/`6`; service `9`; F2 toggles the
DSW1 SW1:8 service-mode switch (a toggle, like MAME's Service Mode
key, applied on top of the OSD DIP value). Scan codes are PS/2 set 2
with the E0 prefix carried as bit 8 of the matched code.

The game samples the service switch only at boot (checked in MAME:
flipping the field mid-attract from Lua changes nothing until a
reset), so F2 then an OSD reset enters test mode, exactly as F2 then
F3 does in MAME. Verified on the MiSTer without a physical keyboard:
`tools/mister_keys.py` creates a uinput keyboard on the box (python3
and /dev/uinput are present) and presses keys from the command line —
`5 5` gave CREDITS 2, `1` started player 1, `9 9 9` gave CREDITS 3,
`2` started player 2, arrows/R and LCtrl/A moved and fired.

## Gamepad Coin broken on macross2 only (not tdragon2/gunnail/raphero)

Reported: macross2's Coin button did nothing on a gamepad, but worked
fine from a keyboard, and the other three games (sharing this same
`Macross2.rbf`/`Gunnail.rbf`/`Raphero.rbf` codebase) were unaffected.
The keyboard-vs-gamepad split was the key clue: `Macross2.sv`'s
keyboard path (`kb_coin1`/etc., see above) decodes PS/2 scancodes
directly in the RTL, entirely independent of any `.mra` metadata — so
a bug specific to gamepads but not keyboards has to live outside the
RTL, in the `.mra`.

Root cause: `Macross2.sv`'s CONF_STR declares a single, fixed 5-entry
button list shared by both games it serves — `"J1,Button 1,Button 2,
Button 3,Start,Coin;"` — since the core is a runtime-selected merge of
tdragon2 (3 buttons) and macross2 (2 buttons; see `in0_i`'s own
comment on why the extra bit is harmless to the *core*). `tdragon2.mra`
correctly declares all 5 names in its own `<buttons>` tag,
matching the CONF_STR 1:1. `macross2.mra` (and its two clones,
`macross2g`/`macross2k`, both generated from `tools/gen_family_c_mra.py`)
declared only 4 — `"Button 1,Button 2,Start,Coin"` — since macross2's
own game logic only reads 2 buttons. But MiSTer's default gamepad
button-to-joystick-bit assignment is positional against the `.mra`'s
own `<buttons>` list, not against the core's CONF_STR — so with only 4
entries, the default mapping put "Start" at ordinal position 2 and
"Coin" at position 3, landing them on the bit positions the CORE
actually decodes as Button 3 and Start respectively (not Start and
Coin) — nothing at all reached the bit the core reads as real Coin.
This is the same class of positional-count mismatch the project's own
`docs/mra-workflow.md` warns to keep aligned, just not one this
project had hit yet in the other direction (a shared core across two
games with a different real button count).

Fix (2026-09-10): all three macross2-family `.mra` files now declare
the full 5-name list, adding a placeholder `"Button 3"` (unused by
macross2's own game logic, same as the existing in0_i/in1_i comment
already documents) with default `"A"` — matching tdragon2.mra's own
`"Y,B,A,Start,R"` convention exactly, so both games get the same
default gamepad face-button layout. `tools/gen_family_c_mra.py`'s
`MACROSS2` dict updated to match and re-run to regenerate
`macross2g`/`macross2k`'s `.mra` files (tdragon2's own clones
unaffected — their table entry didn't change).

This environment has no gamepad hardware to attach to the MiSTer, only
the `tools/mister_keys.py` virtual *keyboard*, which doesn't exercise
HPS's own joystick-default-mapping path at all, so the diagnosis
(button count/order must match the CONF_STR the shared core declares)
was inferred from the code-level asymmetry between macross2.mra and
tdragon2.mra being the only meaningful input-related difference
between two games whose CORE-side coin/start decode
(`in0_i`/`kb_coin1`/etc.) is otherwise identical, plus matching the
reported symptom exactly (broken only on gamepad, only on macross2).
**Confirmed fixed by the user with a real gamepad, 2026-09-10** —
Coin now works on macross2 with the corrected `.mra` files.

## Sprite-on-sprite stacking: what MAME really does (a reverted "fix")

Reported as a transparency problem on tdragon2's desert-stage palm
trees and the ocean-stage whale. Native MiSTer screenshots showed the
trees rendered exactly like MAME's; what differed from expectation was
stacking (an enemy plane behind a tree's leaves). A first fix reversed
the draw walk on the strength of `nmk16spr.cpp`'s shape — collect the
table front to back, then draw the list back to front — reasoning that
entry 0 ends up on top. That was wrong, and it made ships fly under
the slot-0 cloud sprite. The complete rule:

* `prio_transpen` ORs bit 31 into `pmask` ("high bit of the mask is
  implicitly on", drawgfx.cpp) and sets the priority buffer to 31
  under every pixel it draws. So once a sprite pixel is on screen no
  later sprite can replace it: in the back-to-front loop the LAST
  collected entry is drawn first and wins. Net effect: the HIGHER table
  slot is on top, which is what a single forward walk with plain
  overwrite (the original `video_macross2.sv` behaviour, restored)
  produces. Verified on MAME frame 1398 of the tdragon2 demo: enemy
  lasers (slots 109/110) over the 128x160 cloud sprite (slot 0), and
  the smoke cloud (139) under later explosions (140-146).
* The TX layer is drawn with priority 2 and the sprites' pmask holds
  bit 2, so TX always covers sprites; BG never does. The core's
  composite (`tx_opaque ? tile : spr_valid ? spr : tile`) matches.

So an enemy at slot 23 behind a tree at slot 24 is MAME-correct too.
Tools kept from the investigation: MAME's sprite table can be dumped at
chosen frames with a Lua `-autoboot_script` (main RAM + $8000, the
sprite DMA source; frames = seconds x 56.2 on the hires boards), and
same-index frame diffs against MAME are not a valid stacking check —
the sim's sprite plane is a frame late and explosion phases change
every frame, so look at a dumped table and a matching crop instead.

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

And one more, visible only in the core's own native screenshots
(`echo screenshot > /dev/MiSTer_cmd`, exact 384x224 pixels — the
capture box's downscale had hidden it): every sprite row's 2-pixel
column pairs were swapped on hardware, a jagged "combing" along sprite
edges, while the sim was pixel-exact. The sprite ROMs are
`ROM_LOAD16_WORD_SWAP`; MAME's graphics decoder reads that region
byte-wise from the swapped memory image, so byte b is raw file byte
b^1, and the sim's `$readmemh` array is built that way (`mkgfxrom
--mode word_swap`: `sim[i] == raw[i^1]` on every sampled byte). The
SDRAM image holds the raw file order: the download rebuilds words by
byte parity and `rom_cache1_byte` picks the byte by the same parity, so
the two cancel — correct for the 68000's word reads (which is what the
.mra note had verified), wrong for a byte-wise consumer. Fixed by
inverting bit 0 of the sprite byte address on the hardware path.
BG/TX/OKI/Z80 regions are plain `ROM_LOAD`s and were never affected.
Verified two ways: native MiSTer screenshots of the tdragon2 demo
reproduce the player-plane sprite pixel for pixel (all 410 non-water
pixels of a 33x26 masked template) against the MAME-matched reference
sim, and the `tdragon2_hw` testbench — which streams the raw zip bytes
through the same ioctl path as the .mra — reaches the same 100% at its
demo frames 1157/1158. macross2's demo sprites are clean on hardware
too.

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

**Correction (2026-09-10, docs/known-issues.md NMK-1):** the "one frame
after MAME and the real board" above is wrong, in both halves. MAME
keeps *two* table copies — `sprite_dma()` in `nmk16.cpp` does
`old2 <- old <- mainram` at line 242 ("2 buffers confirmed on PCB")
and `screen_update_macross`, used by every shipped game, draws `old2`
at VBOUT (line 240, before that frame's DMA) — so MAME's frame *j*
shows the table from DMA *j-2*, the same two-stage pipeline as this
whole-plane renderer. Measured directly: a Verilator-only `SPRLAT`
tag in `video_macross2.sv` numbers every DMA trigger and carries the
number through snapshot, pass and swap, and reports lag 2 on 59/59
steady-state frames. Then sim frames (`TB_DUMP_PPM`) against MAME
snapshots taken at *exact* frame numbers (a Lua `frame_done` hook
calling `video:snapshot()`, since `-str` is seconds, not frames): sim
frame *S* equals MAME frame *S-3* with 0 differing pixels on half the
frames and 126-141 px (one 14-px HUD text column, NMK-16) on the rest,
against 3,000-4,000 px for a one-frame motion step. The 94.7% / 96.7%
figures above are this same comparison at an alignment off by one
frame (offset 2 gives 2,932 px = 96.6%); the tilemaps "matching" at
that offset was a scene that barely scrolls. Moving sprites are on the
right frame. No line-buffer renderer is needed.

## NMK-16: the HUD marquee is two frames out of phase with gameplay (2026-09-10)

The one residual NMK-1's frame comparison left: with gameplay aligned
(sim *S* = MAME *S-3*), 2 of every 4 frames differ by 126-141 px in a
14-px strip at x 353-366 — the vertical HUD text column of this
sideways-drawn game. The first guess, a TX-VRAM write landing between
the strip's scanout and VBOUT, was wrong, and the way it was disproved
is the reusable part.

- Which cells: output x maps to TX x through `tx_sum = rd_x + 28 +
  512 - 92`, i.e. TX x = x - 64, and rows are offset by `BITMAP_Y0` =
  16, so the strip is TX columns 36-39, rows 2-29 (`index = col*32 +
  row`). The game writes them through the 0x1719xx *mirror*
  (`txvram_addr = byte_addr[11:1]` ignores bit 12; MAME maps
  0x170000-0x170FFF with `.mirror(0x1000)`) — a first `TB_LOG_M68K`
  filter on 0x1709xx saw nothing for that reason.
- When: all 84 cells are rewritten every frame at vpos 249-263 (in
  vblank; `frame_done` in the core pulses at vcount 0 and the raster
  numbering matches MAME's `vpos`, active 16..239), and 12 of them step
  through tile codes 321E → 3220 → 3222 → 3224 every 4 frames — a
  16-frame marquee. A vblank write shows on the next frame on both
  sides, so display timing cannot produce the difference.
- MAME's side, from VRAM not pixels: a Lua `frame_done` hook reading
  the `:txvideoram` share shows the same 4-frame stepping. `frame_done`
  fires at VBOUT — `time_until_vblank_start()` returns exactly one
  frame period (17,792 µs) and `time_until_vblank_end()` 3,456 µs (54
  lines) there — so a VRAM read at `frame_done` *f* predates frame f's
  own vblank writes. (`screen:vpos()` is not exposed to Lua in this
  build; the two `time_until_*` calls are the substitute.)
- The model-free answer: a strip-only diff matrix, sim frames
  1148-1166 against MAME snapshots 1150-1165, restricted to the 12
  marquee cells. The marquee aligns at sim *S* = MAME *S-1* (0-6 px on
  that diagonal, 63-105 px everywhere else), while scroll, sprites and
  the other 72 HUD cells align at *S-3*. Two frames of relative phase
  on a 4-frame step is exactly "2 of 4 frames differ".

Both counters are 68000 software started during boot: the RTL's boot
lands gameplay 3 frames later than MAME but the marquee counter only 1
frame later, so they sit 2 frames apart relative to each other. That
is the same boot-handshake timing class as NMK-3 (the NMK004 ran 3
ticks behind for the same reason); the likeliest 68000-side source is
its wait on the Z80/YM2203 initialisation busy-loops, whose duration
depends on FM-chip status timing that MAME and jt03 model differently.
Real hardware has its own arbitrary phase here. Both video paths are
exact on their own diagonals; nothing to fix.

## Rapid Hero / Arcadia (the "Raphero" rbf)

`rtl/raphero/raphero_core.sv` is the second hardware core, built on
`tdragon2_core.sv`'s `HW_ROMS=1` machinery with `video_macross2.sv` (now
parameterised: `RASTER_SCROLL=1` for the per-scanline X+Y scroll tables,
`SPRITES_BYTES` for the 6 MB sprite ROM) — `Raphero.sv`/`.qsf`/`.sdc`/
`files_raphero.qip`, `sim/rtl/raphero_hw/`, three `.mra` files
(`tools/gen_raphero_mra.py`). What is different from the Family C core,
checked against `nmk16.cpp`'s `raphero()`:

- **68000 at 14 MHz** (7/20 clock-enable accumulator), **TMP90841 sound
  CPU** (`rtl/tlcs90/tlcs90.sv` + `nmk004_periph.sv`) at 8 MHz, memory-
  mapped (`raphero_sound_mem_map`), no sound-CPU reset from the 68000
  (`0x100016` is `nopw()`), OKIs at 4 MHz pin 7 low, NMK112 with two 4 MB
  sample ROMs, `VIDEO_START(gunnail)` per-line scroll, tdragon2's main-RAM
  address swap, same V-PROM as tdragon2/macross2.
- **SDRAM image** (bytes): maincpu 0, audiocpu 0x080000, fgtile 0x0A0000,
  bgtile 0x0C0000, sprites 0x2C0000 (6 MB), then `rhp94099.5`, `.6`, `.7`
  once at 0x8C0000 — MAME loads `.6` into both OKI regions (oki1 = .6+.7,
  oki2 = .5+.6), so oki2 reads from 0x8C0000 and oki1 from 0xAC0000 out of
  one 6 MB copy, keeping the whole image (14.75 MB) inside the 16 MB the
  23-bit cache word addresses reach. The `.mra` part order is exactly that.
- **Sound CPU ROM fetch without a WAIT pin.** `tlcs90.sv` and
  `nmk004_periph.sv` gained a `cen` input (the NMK004/protection wrappers
  tie it high); raphero runs them on `clk_sys` with an 8 MHz enable that is
  withheld while the program-ROM cache (`oki_rom_cache`, 16 lines + next-
  line prefetch, not the 1-line `rom_cache1_byte`) does not hold the byte
  being fetched. In the hardware sim 0.1% of clock pulses are withheld.
  `Raphero.sdc` declares the CPU/peripheral register-to-register paths as
  5-cycle multicycle paths (they only ever update on the enable) — without
  that the execute logic fails timing by ~10 ns at 40 MHz.
- **Per-scanline scroll.** `bg_update()` in `nmk16_v.cpp` draws bitmap line
  y (16..239) with `yscroll = scrollramy[0] + scrollramy[y]`, tilemap row
  `(y + yscroll) & 0x1ff`, and `xscroll = scrollram[0] + scrollram[y]` — both
  tables indexed by the *bitmap* y (screen y + 16). `video_macross2.sv`
  outputs that row address (`scroll_row_addr`) and adds the taps into the
  BG line calculation for both the use and lookahead pixels; the prefetch
  tags are tile positions, so per-line changes cost nothing. The core keeps
  the tables (plus the plain 0x130400 RAM) in one 1024x16 block RAM with a
  registered CPU port and a registered video port that reads the two rows
  on alternate cycles; word 0 of each table is mirrored in a register for
  the `tilerambank` derivation (`(scrollram[0] >> 12) & 3`) and the video
  taps. Result in the reference sim: pixel-identical to MAME on every frame
  compared (title, starfield, ship intro at frames 450-560).

Two hardware-path bugs the 14 MHz bus exposed that the 10 MHz Family C core
never showed (both found with `sim/rtl/raphero_hw`, whose testbench now has
a `TB_TRAP_PC` ring buffer of the last 64 bus cycles and a golden-word audit
of every ROM read):

1. **Speculative ROM-cache fetches clobbering a hit.** `rom_cache1` refetches
   whenever its address input changes, and the core fed it the raw 68000 bus
   address — every main-RAM/VRAM access started an SDRAM read of an
   unrelated word. When that fill landed during the *next* program fetch,
   after the CPU had sampled DTACK on a cache hit but before it latched the
   data (fx68k samples both on `enPhi2`, one 68000 clock apart), the line
   was overwritten under it: the boot RAM test read `$FFFF` for the opcode
   at `$0025DA` and took an F-line exception into the game's error handler
   (a `clr.b $3.w; bra` watchdog loop, black screen). At 10 MHz the fill
   always landed before the next fetch's DTACK sample. Fix: the cache only
   sees ROM addresses (`rom_cache_addr = sel_rom ? bus : held`). The same
   guard is now in `tdragon2_core.sv` for both the 68000's `rom_cache1`
   and the Z80's `rom_cache1_byte` (whose RAM/latch accesses used to start
   speculative bank-window fetches the same way); the reference sim trace
   is unchanged and the Macross2 rbf was rebuilt and re-verified.
2. **Registered `ready` flags stale for one clock.** `mainram_ready <=
   (addr_r == addr)` is high for the first `clk_sys` after the address
   changes (it still reflects the previous address); at 14 MHz `enPhi2`
   can fall in that window. The flags are now combinational on the
   registered address (`ready = (addr_r == addr)`), which is also one clock
   earlier for the sprite-snapshot FSM.

Hardware sim after the fixes: 68000 and TLCS-90 both run the attract
sequence, every ROM word and OKI sample byte matches the images, and the
frames are pixel-identical to the reference sim 14 frames later (the boot
ROM check runs slower through real wait states); the reference sim is
pixel-identical to MAME on every frame compared. Audio from both sims
scores 0.96 band correlation against MAME's `-wavwrite` output
(`tools/audio_compare.py`, whose level column shows the same ~9 dB
MAME-louder offset the Family C hardware captures have).

Real hardware (DE10-Nano, `Raphero.rbf`, `Rapid Hero (NMK).mra`): boots
and plays the attract loop; native screenshots of the title screen are
pixel-identical to MAME's snapshots of the same scene, scrolling scenes
match to within the capture-time offset; a 40 s audio capture scores
0.96 band correlation against MAME with the usual level offset. The
15 MB ROM upload takes about 18 s. Quartus: 81% ALMs, 94% of the M10K
blocks, worst setup slack +0.37 ns with the multicycle constraints.

Per-line scroll in the game: a Lua probe of `scrollram`/`scrollramy`
over 150 s of MAME's attract mode (title, demo play on two stages, high
score table) never found a row entry differing from the others — the
game drives the background through entry 0 of each table (X and Y both
change; `tilerambank` comes from entry 0's bits [13:12]), and the
row-table path is exercised with zero rows. So the "dual" X+Y scroll is
verified on hardware against MAME through those scenes; the genuinely
per-line raster case is verified only structurally (same expressions
as `bg_update()`, both taps indexed by bitmap y) until a stage that
uses it is reached.

## GunNail (the "Gunnail" rbf): NMK004 sound MCU and NMK-215 protection on hardware

`rtl/gunnail/gunnail_core.sv` is the third hardware core: raphero's
`HW_ROMS=1` machinery around the Family D/NMK004 board — `Gunnail.sv`/
`.qsf`/`.sdc`/`files_gunnail.qip`, `sim/rtl/gunnail_hw/`, two `.mra`
files (`tools/gen_gunnail_mra.py`, GunNail and the location test).
`video_macross2.sv` gained the gfx_macross parameters (`SPR_COLOUR_BITS=4`,
`TX_PAL_BASE_P=0x200`, `BG_CODE_BITS=13`) and `NMK214=1`, which puts the
two descramblers after the tile/sprite caches (a pure data bitswap keyed
by the logical address, so the SDRAM image stays raw; the sprite word
comes from a new `word` output of `rom_cache1_byte`). Cross-checked
against `nmk16.cpp`'s `gunnail()`/`gunnail_prot()`:

- **68000 at 10 MHz**, `gunnail_map` (I/O at 0x080000, BG VRAM 8192
  words with no `tilerambank`, TX at 0x09C000 mirrored, plain main RAM).
  maincpu is a `ROM_LOAD16_BYTE` pair: the `.mra` interleaves it with the
  low-byte chip `3o.u133` on even stream addresses (`map="01"`) so the
  core's byte-parity word rebuild gives the 68000's words —
  `tools/mk_ioctl_stream.py` gained the matching `lo+hi` region syntax.
- **NMK004** (`rtl/tlcs90/nmk004_core.sv`) on `clk_sys` with an 8 MHz
  enable: the wrapper gained `USE_CEN`/`ROM_EXTERNAL` — its 8 KB boot ROM
  (`nmk004.bin`, delivered by the `.mra` from `nmk004.zip`) and the 64 KB
  game program both come through one `oki_rom_cache` on SDRAM port 1, the
  enable withheld on a miss (0.04% of pulses in the hardware sim). The
  OKIs (4 MHz, pin 7 low) use the NMK004's own bank writes for their upper
  128 KB window, through `oki_rom_cache`s with the golden-byte audit.
- **NMK-215 protection MCU** (`nmk_prot_core.sv`, `USE_CEN`, 4 MHz
  enable): its 8 KB ROM is written into the on-chip array straight from
  the ioctl stream (`rom_we` port). The shared-bus path steals each RAM's
  CPU-side port when the 68000 is not mid-cycle there (the 68000's
  combinational ready flag then holds DTACK one clock), the MCU's enable
  waiting for `prot_rd_ready`/`prot_wr_done`; its 68000-ROM reads have
  their own byte cache on port 1. What the firmware actually does in
  this game (MAME Lua taps, 30 s of attract mode): loads the two NMK214
  configs at boot (port 7 data, port 3 bit 2 strobe — 0x02 for the
  sprite chip, 0x0E for the BG chip), then polls P5 for scanline 116 and
  writes P6 = 0x03/0x0B once per frame; it never accesses the 68000 bus
  and never writes the 0x08 that halts the 68000 in the NMK-110/113
  firmware. `docs/tier2-system.md`'s "macross/gunnail never assert HALT
  so they are not playable" was a misreading of that: the reference sim
  was fine all along and simply ran out of cycles on the "PRESENTS"
  splash, which MAME also holds until frame ~570.
- **Per-line scroll**: `RASTER_SCROLL=1` with both tables indexed by
  bitmap y (the old `video_gunnail.sv`, now deleted, indexed
  `scrollramy` by screen y and had no bitmap offsets — its frames sat
  (28,16) off MAME's). A Lua probe of the tables over 200 s of MAME's
  attract mode never found a row entry differing from the others: like
  raphero, this game drives the background through entry 0 of each
  table; the row path is exercised with zero rows.

Verification (`sim/rtl/gunnail`, `sim/rtl/gunnail_hw`, MAME 0.270):

- Reference sim, 12 s: every MAME snapshot from frame 60 to 660 (ROM
  check, logo animation, PRESENTS, fade) has a pixel-identical sim frame
  within ±4 frames. Audio: 0.977 band correlation against MAME's
  `-wavwrite`, the same silence/sound timeline second by second.
- **NMK004 handshake**: the 68000↔NMK004 latch traffic (`TB_LOG_HOST`,
  `dbg_host_cmd*`/`dbg_mcu_reply*`) reproduces MAME's boot protocol
  byte for byte and frame for frame — reply 02/82 at power-on, then at
  frame 31 (MAME 30) the three command rounds 00→82, 22→C7, 62→00,
  00, 8C→2C, C7→6C, 00 / 3F→C7, 7F→00, 00, 89→29, C7→69, 00 / 2B→C7,
  6B→00, 00, then FE (sound on) at frames 32/111/119 and CC/F0 (music)
  at 152 — MAME: 31/110/117 and 150. The hardware sim (real SDRAM wait
  states, cache-stalled NMK004) does the same one frame later.
- Hardware sim: ROM golden-word audit 0 wrong of 3.8 M reads, OKI
  golden-byte audit 0 wrong of 2 × 242 K sample latches, frames
  pixel-identical to the reference sim ~30 frames later (the ROM check
  is slower through real wait states), NMK214 configs 0x02/0x0E loaded
  at frame 1, protection MCU running (940 K instructions in 2.5 s) with
  0 bus accesses, as in MAME.
- Regressions of the shared TLCS-90 wrappers (`cen`/`ROM_EXTERNAL`
  parameters default off): mustang, hachamf (802 HALTs, unchanged),
  tdragon1 (508 HALTs, unchanged) and macross rebuilt and rerun;
  `sim/rtl/nmk214` self-test 80,102 checks / 0 failures after the
  generate-loop rewrite Quartus 17 needed.

The first hardware build ran the game (ROM check, NMK004 music, demo
play) but drew every BG tile and sprite scrambled while the TX layer
was right. Not the NMK214: rebuilding with its `ADDR_BITSWAP` parameter
flattened to a 65-bit vector gave a byte-identical RBF (the flat form is
kept — Quartus 17 also rejects `for (...) assign` without a named block
and bit-selects on function results, which `tlcs90.sv` hit for raphero).
The cause was the SDRAM layout: the `.mra` loader streams the `<part>`s
back to back and cannot place one at an offset, and the first gunnail
layout had a 0xC000 gap between the protection ROM (ends 0x094000) and
`fgtile` (0x0A0000). Everything after the gap landed 0xC000 too low, so
BG tiles, sprites and OKI samples were read from shifted data (the HUD
font lives high enough in `fgtile` to survive). `tools/mk_ioctl_stream.py`
pads regions to their offsets, so both sims were fine. The layout is now
contiguous (fgtile 0x094000, bgtile 0x0B4000, sprites 0x1B4000, oki1
0x3B4000, oki2 0x434000) — the rule for every core: no gaps between
`BASE_BYTE_*` regions.

Real hardware with the contiguous layout (DE10-Nano, `Gunnail.rbf`,
Quartus 61% ALMs / 74% of the M10K blocks, worst setup slack +0.45 ns
with the multicycle constraints on both MCUs): boots through the ROM
check, logo and title into the attract demo. Native screenshots of the
title, the stage high-score table and the demo's static moments are
pixel-identical to MAME's snapshots of the same scenes; the scrolling
demo frames match to within the capture-time offset (boss, ships,
parallax backgrounds, HUD). A 45 s audio capture scores 0.92 band
correlation against MAME's `-wavwrite` output with the same
silence/jingle/music timeline (boot jingles, then the stage music)
second by second, at the usual ~8 dB lower level. Coin/start/joystick/
fire work through the keyboard path (Start and Coin are joystick bits
6/7 on this two-button core), the OSD shows Orientation, both autofire
entries and the DIP submenu, and the location-test set (`gunnailp`,
single word-swapped program ROM from its own zip plus the parent's
files) boots and plays.

Per-line scroll, verified with real data: the game does use it — a
screen shake during the death explosion (MAME frames 5369-5417 and
8226-8250 of the attract demo, up to 223 rows with their own X offset,
±8 px, alternating bands). The attract demo drifts from MAME's by a few
frames well before that point (in the sim and on the board alike — it
depends on timing the sims do not reproduce cycle-exactly), so no
frame-exact comparison is possible there. Instead `sim/rtl/video_state`
renders a MAME video-state dump (Lua: the `:scrollram`/`:scrollramy`/
`:bgvideoram0`/`:txvideoram`/`:palette` shares, the sprite RAM copy and
the tilebank at one `frame_done`, read through the shares because the
scroll regions are write-only through the CPU map) through
`video_macross2.sv` alone: the dump of frame 5396, whose X table holds 14
distinct row values, renders pixel-identical to MAME's snapshot of that
frame (0 differing pixels; the sprite table must be taken at the same
`frame_done` as the snapshot, and the drawn sprite plane only shows
after the next DMA trigger, so the harness pulses it twice). The HDMI
recording of the board through the same explosion shows the same
alternating-band shifts as MAME's frames, within what moving sprites
allow the measurement to say.

## Slowdown in play: 68000 wait states and the sprite pass (2026-09-09)

Thunder Dragon 2 slowed down on the board in busy scenes — many sprites
and explosions — where MAME does not. Two separate mechanisms, both
hardware-path only (the zero-latency reference sims match MAME frame
for frame and never see either):

**1. The 68000 lost about an eighth of its time to ROM wait states.**
MAME and the real board run the 68000 with zero wait states from EPROM.
Through the 1-pair `rom_cache1` on SDRAM port 0, 56% of ROM bus cycles
missed (the instruction stream and the game's ROM data-table reads
thrash one pair), each miss a ~10 clk_sys round trip = 1-2 wait states,
13% (median) to 20% (worst frame) of every frame stalled; instructions
per frame ran 12% below the reference sim. In frames where MAME's CPU
is already near the frame budget that is the difference between
keeping up and dropping a frame. Measured with the CPU audit counters
in `sim/rtl/tdragon2_hw/tdragon2_hw_top.sv` (`CPUFRAME` lines) and a
replay of every ROM access (`TB_ROM_TRACE`) through candidate caches
with `tools/rom_cache_eval.py`: 16 lines alone leave 4% misses
(sequential streaming of code and tables), 16 lines + next-pair
prefetch 0.35%. `rtl/rom_cache_n.sv` (16 aligned pairs, FIFO, next-pair
prefetch, never replacing the pair being read) now serves the program
ROM in all three hardware cores: rom_wait 0.03% of a frame (median),
instructions per frame within 0.1% of the reference sim, and the
gunnail/raphero/macross2 hardware sims run within 1-3 frames of their
references instead of 30 behind.

**2. The sprite compositing pass outlasted the frame.** The attract
demos never showed it (the old build's attract cycle is 33.3 s on the
board, exactly MAME's, with no repeated frames), but MAME autoplay
(`scratchpad/autoplay.lua`: coin, start, fire taps, movement sweeps)
shows the game keeps 800-1200 on-screen 16x16 sprite units per frame
in play (median 835, p99 1130, max 1214 in 4 minutes). The pass costs
one clk_sys per pixel plus its ROM fetch stalls, and with the 1-pair
`rom_cache1_byte` every 4-byte group of a unit was a full arbiter
round trip behind TX: 585 clk per unit, 358 of them stall, plus the
86k-cycle plane clear — a 1070-unit frame no longer fits in the 711k
cycles of a frame, the plane swap waits a frame, and the sprites
update at half rate while the tilemaps keep scrolling. On the board a
measurement build (`DBG_SWAP_MARK`: an 8x8 block at the screen origin
alternating red/white on every plane swap, counted from a 60 fps HDMI
capture with `scratchpad/markerstats.py`, scripted play via
`mister_keys.py`) showed the old build swapping 44-50 times per second
in busy play against 56.2 when light (25 of 45 five-second windows
below 55/s, mean 53.2); the same script with the 8-pair prefetching
sprite cache alone (TX still sharing the port) gave 56.0-56.4 in every
window (mean 56.2 = every frame), as does the final layout (sprites
on their own port): 56.0-56.4 in all 45 windows, mean 56.20. The
release build plays normally on the board and its attract cycle is
33.3 s with no repeated gameplay frames, as in MAME; Raphero and
Gunnail were rebuilt with the same three changes, their hardware sims
match their reference sims pixel for pixel (raphero now one frame
behind its reference instead of thirty), and both boot and run their
attract demos on the board.
Fix, in two parts: `rtl/rom_cache_n_byte.sv` (8 pairs + next-pair
prefetch) for the sprite fetch, and the sprite fetch alone on SDRAM
port 1 with the TX prefetch moved to the sound port at top priority
(`TX_EXTERNAL`, see the port table). Measured in the hardware sim
playing the game (`TB_AUTOPLAY=1`, `SPRFRAME` lines):

| sprite fetch path | clk per unit (stall) | pass at 852 units | pass at 1214 units |
|---|---|---|---|
| 1 pair, shared with TX | 585 (358) | 585k | 796k — late |
| 8 pairs + prefetch, shared with TX | 467 (240) | 484k | 653k |
| 8 pairs + prefetch, own port | 303 (76) | 344k | 459k |

(frame = 711,744 clk_sys; the plane clear is 86k of each pass; the
1214-unit column extrapolates from the measured per-unit cost, the
852-unit column is the median gameplay frame of the scripted run.) The
final layout's gameplay frames are pixel-identical to the baseline
run's (57 of 57 sampled frames, same lag), i.e. the game itself plays
the same — only the time the pass takes changed.
The OKI cen-stall and unserved-sample audits are unchanged by the TX
move (gunnail 24.755% before and after), and the reference sims are
bit-identical (the change is inside the `HW_ROMS=1` branches).

**Headroom (2026-09-10, NMK-9).** The 1214-unit column above was an
extrapolation from a MAME Lua count of the sprite *table*; the hardware
never draws that many. MAME's `nmk16spr.cpp` charges 16 sprite clocks
per scanned entry plus 128 per 16x16 unit and stops at
`set_max_sprite_clock`, which is 512*263 = 134,656 for every hi-res
game (gunnail, macross2, tdragon2, raphero all use `set_screen_hires`)
— the same `MAX_SPRITE_CLOCK` that `video_macross2.sv` applies in
`S_SPR_HEAD_DECIDE`. So a frame hands the renderer at most ~1,051
units (one large sprite) or 935 (single-unit sprites). Re-measured on
the current RTL with the same `TB_AUTOPLAY=1 TB_RAM_PER2=5` 400 M-cycle
run (347 gameplay frames): pass = 44.7 k + 351 clk x units (fit, max
residual +5.4 k); per-unit cost 303/308/309 clk median/p99/max, of
which 77-81 clk is SDRAM stall; median frame 344 k, worst 354 k
(49.8 % of the frame); no late plane swap after frame 0. At the
1,051-unit bound the fit gives 414-420 k, 58-59 % of a frame — about
41 % headroom in the worst frame the game can construct. The stall
term is structural rather than scene-dependent (a unit's 128 bytes are
contiguous, the next pair is prefetched while the current one is
consumed), which is why the per-unit cost is flat across the run. The
68000 on the same run: 3.9 k clk median / 4.9 k max of ROM wait per
frame (0.55 % / 0.69 %), 32,104 instructions per frame. Re-run this
audit after any change to the ROM caches or SDRAM port assignment.

## Status

Three RBFs run on the DE10-Nano and are tracked in `releases/`:
`Macross2` (tdragon2, macross2 and their clones — one runtime-selected
core), `Raphero` (raphero, rapheroa, arcadian) and `Gunnail` (gunnail,
gunnailp). Each one boots through the `.mra` loader with its ROM image
matching simulation, renders its attract demo without the smearing,
tearing or missing-sprite problems the sections above walk through,
and is pixel-identical to MAME in native screenshots of the scenes
that can be compared (the video-state harness covers the ones the
demo's timing drift puts out of reach). Audio is level-corrected and
compared band by band against MAME (`tools/audio_compare.py`): 0.987
on tdragon2, 0.988 on raphero, 0.968 on gunnail over the first 60 s
after the NMK004 sequencer fix. Coin/start/joystick/fire work from
both the keyboard path and a gamepad (the macross2 gamepad Coin bug
was a `.mra` button-count mismatch, fixed above), the OSD carries
Orientation (Horz / Vert 270 / Vert 90), Flip screen, P1/P2 Autofire
and the per-game DIP submenu, and settings persist through the
MiSTer's own save. In-play slowdown on the sprite-heavy stages is
gone (56.2 plane swaps/s in every measured window). The shared TLCS-90
core has a passing nine-target standalone self-test suite (`make
run-selftests` in `sim/rtl/tlcs90/`), and every TLCS-90-using game in
the tree runs clean in simulation on the current core.

What is still open is tracked, one entry per item with a stable ID and
status, in `docs/known-issues.md` — that file, not this paragraph, is
the authoritative list. As of 2026-09-10 the only item a player could
notice is the untuned HSync/VSync placement (NMK-2) — the supposed
one-frame sprite latency (NMK-1) turned out on measurement to be an
off-by-one in the old frame comparison; the core's sprite pipeline
matches MAME's two-buffer PCB behaviour exactly, and the sole frame
residual is a 14-px blinking HUD strip (NMK-16). The rest are
verification gaps and build-margin notes (Raphero is at the edge of
the device, NMK-10).
