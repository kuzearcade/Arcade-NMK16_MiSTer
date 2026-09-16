# Known issues and areas for improvement — released cores

Tracked list for the four RBFs shipped in `releases/` (`NMK16_Macross2`,
`NMK16_Raphero`, `NMK16_Gunnail`, `NMK16_Afega`). One entry per issue with a stable ID; update the
**Status** line in place rather than deleting entries, so the history
stays readable. Details and evidence for each live in
`docs/hw-bringup.md` (section named in **Ref**). Started 2026-09-10.

Status values: `open`, `in progress`, `fixed (unreleased)` (fix committed,
RBF not yet rebuilt/shipped), `fixed`, `wontfix` (with reason).

Severity: `bug` (behaviour differs from MAME/board in a way a player can
notice), `limitation` (known, documented gap in fidelity), `gap` (works,
but not proven), `infra` (build/test/doc health).

---

## Cross-core

### NMK-1 · Sprites display one frame late
- **Cores:** NMK16_Macross2, NMK16_Raphero, NMK16_Gunnail · **Severity:** limitation · **Status:** not a bug (measured 2026-09-10 — the core matches MAME and the PCB exactly)
- **Ref:** "Lines through moving sprites, and flicker" (with its dated correction)
- The premise was that MAME/the board show the DMA'd table on the
  *next* frame while the whole-plane renderer shows it a frame later.
  Both halves were wrong. MAME (`nmk16_v.cpp`) keeps two copies —
  `sprite_dma()` does `old2 <- old <- mainram` at line 242, with the
  comment "2 buffers confirmed on PCB" — and every shipped game's
  `screen_update_macross` draws `old2`, rendered at VBOUT (240) before
  that frame's DMA: frame *j* shows the table from DMA *j-2*. A
  Verilator-only tag in `video_macross2.sv` (`SPRLAT`, numbering each
  DMA and carrying it through snapshot, pass and swap) reports the core
  at lag 2 on 59/59 steady-state frames — identical. Then a direct
  frame comparison (sim `TB_DUMP_PPM` vs MAME snapshots taken at exact
  frame numbers by a Lua `frame_done` hook) shows sim frame *S* equal to
  MAME frame *S-3* with **0 differing pixels** on half the frames and
  126-141 px on the rest (see NMK-16), where one motion step is
  3,000-4,000 px. The earlier "94.7% at the same index" figure is what
  this same table gives at an off-by-one alignment (2,932 px = 96.6%),
  i.e. the old comparison was misaligned by one frame — MAME's `-str`
  is *seconds*, not frames, so the index pairing was empirical.
- No line-buffer renderer is needed; NMK-9/NMK-10's budget concern for
  it is moot.

### NMK-2 · HSync/VSync placement is an untuned placeholder
- **Cores:** all three · **Severity:** limitation · **Status:** closed (2026-09-11 — the nominal placement with the H/V Shift trims in place was reported ideal on CRT equipment; nothing to fold in)
- **Ref:** "H Shift / V Shift options (sync-position trims for CRT users, NMK-2)"
- Scaler locks and reports 384x224 @ 56.2 Hz; sync *position* has never
  been tuned against a reference (real board sync timing isn't
  documented anywhere this project has sourced). Cosmetic on HDMI;
  matters more for direct/analog video users.
- Each core now has `H Shift` (±16 px, 2-px steps) and `V Shift`
  (±20 lines) OSD trims that move the sync pulses inside blanking with
  the picture (DE) fixed. H's 0 is the original placement. V's range
  was widened from +4/−8 to ±20 the same day, which required
  re-centring the nominal vsync in the 54-line vblank (row 264 instead
  of the original 244, which had only four blank lines before it); the
  original placement is exactly `V Shift +20`. On real CRT equipment
  the shipped nominal placement (H 0 / V 0, i.e. hsync at 440 and
  vsync at row 264 of the 512x278 raster; the same relative positions
  in the 7 MHz powerins mode) was reported ideal, so the constants stay
  as they are and the trims remain available for individual monitors.

### NMK-3 · Residual TLCS-90 register divergence vs MAME (NMI phase)
- **Cores:** NMK16_Gunnail, NMK16_Raphero (shared `tlcs90.sv`) · **Severity:** gap · **Status:** closed — characterized as a benign boot-phase timer phase offset (2026-09-10)
- **Ref:** "Fifth pass: the residual is a 3-tick Timer-1 phase offset from boot"
- The "port-toggle byte" is `$009C` in the NMK004 boot ROM's Timer-1
  handler — `ld a,($FF80); xor a,$08; ld (P4),a`, a heartbeat that
  flips P4.3 every tick — so a mismatch there means one side has taken
  one more T1 interrupt. It was never the NMI: the NMI handler only
  reloads the watchdog countdown, and MAME gates NMI on IF exactly as
  the RTL does. Counting T1 entries in both register traces: steady-
  state period identical (median 40,316 vs 40,320 cycles, 198-199/s on
  both), but the RTL loses one tick in second 1 and two in second 2
  of the boot phase and then stays exactly 3 behind for the rest of
  the trace (cumulative MAME−RTL: 0,1,3,3,3,…). Three is odd, hence
  the parity flip. The offset comes from where the timer starts
  relative to the 68000 boot handshake (first tick 0.5611 vs 0.5566 s;
  the previously-noted boot poll-loop iteration difference) — the same
  cross-CPU-timing class already accepted for mustang, now measured.
- Consequence: the host's "play track" commands (`00`, `10`, same
  bytes, same 12.5 ms spacing on both sides) land on different ticks
  relative to the sequencer, so at one tick the RTL's command queue
  holds 2 where MAME's holds 0 (`$0201`: B′ ← ($FF22) is the queue
  count — the "BC′ 0002 vs 0000" the trace shows). From there the two
  run the same program one tick (~5 ms) apart, so register-exact
  comparison stops being the right yardstick; the semantic ones are:
  the track-start routine `$0A63` executes 36 times on both sides,
  YM instrument writes match to 0.1% over 90 s, band correlation 0.968.
  Nothing left to fix here. Re-traced on the final core (after the
  SET/RES `b,g` writeback fix): byte-identical instruction stream,
  same 2,791 Timer-1 entries, same 3-tick offset — that fix touches
  nothing GunNail's firmware executes.

### NMK-17 · Timer-1 "long-mode period" ~0.1% shorter than MAME's — not a timer difference
- **Cores:** NMK16_Gunnail, NMK16_Raphero (NMK004 / bare TLCS-90) · **Severity:** gap · **Status:** closed — explained (2026-09-10)
- **Ref:** "Fifth pass…" (addendum); `nmk004_periph.sv` `+define+TIMER_TRACE`
- Found while characterizing NMK-3: with partial intervals excluded,
  the free-running mode agrees to 0.01 cycles (40,319.99 vs 40,320.01 =
  8 × 16 × 315, the boot ROM's 16-bit T0/T1 setup) while the boot
  phase's ~113k-cycle Timer-1 intervals were 81 cycles shorter on the
  RTL (113,347 vs 113,428). Tracing every TREG/TCLK/TMOD/TRUN write
  (`TIMER_TRACE`) shows the boot phase is not a timer mode at all: from
  0.57 s the sound program stops the timers, rewrites TMOD=04 / TCLK=aa
  / TREG0..3 and restarts with TRUN=23 every ~14.1 ms, so each interval
  is one 40,320-cycle hardware period plus ~73k cycles of software
  between restarts (the game's own program also uses T0/T1/T2 as
  one-shot delays, TRUN 27→25→21→20→27, in its first 0.05 s). The
  hardware part is identical by the free-running measurement; the 81
  cycles sit in the software part — 0.11%, the CPU core's known
  per-instruction cycle-cost residual against MAME's TLCS-90 cycle
  table (cf. 2/7779 on mustang). Restart semantics were checked too:
  both models reset the count and prescaler phase on a TRUN start (the
  RTL's free-running ÷8 base gives 0..7 cycles of start jitter, mean
  3.5). Nothing to fix in the timer; the cycle-cost residual is
  inaudible and already documented.

### NMK-4 · TLCS-90 standalone self-tests were silently not running
- **Cores:** NMK16_Gunnail, NMK16_Raphero (+ every sim-only TLCS-90 game) · **Severity:** infra · **Status:** fixed (unreleased — harness only, no RBF change)
- **Ref:** this file; `sim/rtl/tlcs90/`
- All seven opcode self-tests (`banktest`, `blocktest`, `rldtest`,
  `muldivtest`, `ldarcallrtest`, `switest`, `extest`) and the base `run`
  target failed with every result reading `0x00`. Root cause: `tlcs90.sv`
  gained a `cen` clock-enable input for NMK16_Raphero's 14 MHz path; the
  NMK004/protection wrappers tie it high, but the eight raw-module
  testbenches never drove it, so Verilator left it 0 and the CPU never
  stepped. Fixed 2026-09-10 by setting `top.cen = 1` alongside reset in
  each testbench; all eight pass, plus `run-irqtest`/`run-nmk004`.
- **Follow-up (open, see NMK-5):** none of these tests cover the two
  bugs found via register tracing.

### NMK-5 · No regression test for the XCF-on-INC/DEC and SET/RES-on-register fixes
- **Cores:** NMK16_Gunnail, NMK16_Raphero · **Severity:** infra · **Status:** fixed (unreleased until the NMK16_Raphero/Gunnail RBF rebuild lands — see below)
- **Ref:** "Fourth pass…"; `sim/rtl/tlcs90/gen_flagtest_rom.py`, `tb_flagtest.cpp`, `make run-flagtest` / `make run-selftests`
- Added 2026-09-10: nine checks covering XCF recompute on 8-bit
  INC/DEC (set on zero, cleared on non-zero, CF preserved), INCX/DECX
  chaining in both the fires and must-not-fire directions on a memory
  pair, and SET/RES `b,g` register writeback for `g=A` *and* `g=B/C`.
- **Writing the test found a third bug:** the first GunNail fix wrote
  the SET/RES `b,g` result back to A unconditionally. That is right for
  prefix `0xFE` (`g=A`, the only form GunNail's firmware uses) and wrong
  for `0xF8..0xFD` (`g=B..L`) — MAME's decode is
  `R8( 2, b0 - 0xf8 )`, i.e. the prefix byte's own register, which the
  RTL already loads into `r2`/`val2` but was not writing back to.
  Fixed in `tlcs90.sv` (`a_or_r8_write(r2[2:0], rv)`). Negative
  controls: the pre-fix RTL fails 6/9 checks, the write-to-A RTL fails
  exactly the two register-writeback checks, current RTL passes all
  nine plus the other eight self-tests. No shipped game is known to
  execute `set/res b,g` with `g≠A`, so no audible/visible change is
  expected — the RBFs are rebuilt so `releases/` matches the RTL.

### NMK-21 · Flip Screen DIP did nothing on any core
- **Cores:** all four · **Severity:** bug · **Status:** **fixed and confirmed
  on hardware 2026-09-14** (three separate defects — a dropped register, a
  backwards prefetch, and an unimplemented Afega mechanism)
- The games read their Flip Screen DIP and write bit 0 of the flipscreen
  register (`nmk16_v.cpp`'s `flipscreen_w` -> `flip_screen_set` +
  `m_spritegen->set_flip_screen`). Every core decoded that write and latched
  it into `flip_screen_reg` — and **nothing ever read that register**.
  `video_macross2.sv` had no screen-flip input at all (`spr_flip_en` is the
  unrelated per-sprite attribute flip). So the DIP was wired correctly all
  the way to the 68000 and then dropped on the floor.
- Confirmed the chain is intact up to that point by tapping MAME's 68000
  writes: tdragon2 writes `0x100014 = 0000` with the DIP off and `0001` with
  it on (566 times over 600 frames — re-asserted per frame); gunnail writes
  `0x080014` once at boot, `0000` vs `0001`.
- **What flip actually is, measured rather than assumed:** MAME flips the
  tilemaps and mirrors the sprite coordinates internally, but for a
  full-screen window the net result is exactly a 180-degree rotation of the
  visible area. tdragon2 frame 600 with the DIP on is bit-identical to
  rot180 of the same frame with it off — 0 of 86,016 pixels differ, where a
  vertical-only mirror differs by 57,822 and a horizontal-only by 21,854.
  gunnail agrees on 229 of 260 frames, the other 31 being the boot frames
  *before* its single register write lands.
- Fixed by mirroring the readback coordinates in each core
  (`rd_x_flip`/`rd_y_flip` feeding `video_macross2`), which reproduces MAME
  by construction and leaves the tilemap/sprite/prefetch pipeline untouched.
  The mirror is blanking-safe: off-screen positions arrive >= the visible
  size and the modular subtraction keeps them there. `vandyke`/`vandykeb`
  take the inverted sense (`vandyke_flipscreen_w` calls `flipscreen_w(~data)`).
- Verified in the reference sim against MAME for both DIP settings:
  tdragon2 194 of 211 frames pixel-exact, gunnail 69 of 85 — every
  non-exact frame a blank boot-lag frame (`sim nonblack 0`), and the
  statistics *identical* with the DIP on and off, so turning flip on costs
  nothing in fidelity.
- **Do not measure "RTL flip == rot180(RTL no-flip)" and call it
  verification.** In the reference sim the only thing the flip bit does is
  drive this mirror, so that identity holds by construction whatever the
  rest of the pipeline does — it was reported as "211/211 frames" in an
  earlier draft of this entry and is worthless. The load-bearing numbers are
  RTL-vs-MAME and hardware-path-vs-reference-path, both below.
- `tdragon2_core.sv` gained a `SIM_DSW` parameter (as `gunnail_core.sv`
  already had) so a HW_ROMS=0 reference sim can drive the DIPs at all;
  without it `sel_dsw1` reads a hardcoded 0xFFFF and no DIP-selected
  behaviour can be exercised.

#### NMK-21b · …and the first fix broke the picture on real hardware only
The coordinate mirror above is correct and is invisible to the reference
sim, but it inverted an assumption the **hardware** tile fetch depends on.
`video_macross2.sv` prefetches tiles for the pixel 16 ahead of the one being
drawn (`tile_prefetch_byte`, PF=16 — see NMK-16). That lookahead was a fixed
`rd_x + 16`. With the raster mirrored, `rd_x` counts **down**, so `+16`
pointed 16 pixels *behind* the beam: every prefetch fetched a tile already
drawn, and every drawn pixel missed. The board showed vertical striping; the
HW_ROMS=0 sim, which has zero-latency `$readmemh` arrays and no prefetch at
all, showed nothing. Fixed by making the lookahead direction-aware:

```systemverilog
wire [8:0] x_look = flip_screen ? (rd_x - 9'd16) : (rd_x + 9'd16);
```

The 9-bit wrap stays symmetric — unflipped, the pre-line blank `rd_x`
496..511 gives `x_look` 0..15; flipped, the mirrored 399..384 gives 383..368,
the flipped line's own first pixels, fetched just as early. `video_macross2`'s
`flip_screen` input therefore means the **horizontal** axis specifically: it
only steers this lookahead, and a vertical mirror just reorders whole lines.

How it was found, after a long detour: `DBG_MISS_PAINT` reported 0 BG-miss
and 0 TX-miss pixels under flip, and a coordinate dump showed `rd_x_flip`,
`tx_line_x` and `bg_line_x` **identical** in both paths, which looked like the
fault had to be downstream of the tilemaps. It was not — the cache was
hitting, on the wrong entry. What settled it was widening the dump to carry
the *data* alongside the coordinates: the TX ROM byte (`fgtile_rom_byte`),
the VRAM word travelling with it (`tx_vram_use`) and the resulting palette
nibble, logged per pixel on one scanline in both paths and diffed
frame-by-frame. **Dump the value, not just the address** — a cache that
serves stale data from a correctly-computed address is invisible to an
address-only trace, and `hit` flags cannot see it either.

Two traps in that harness, both of which wasted time:
- `tb_tdragon2_hw.cpp` opens its dump file *after* the multi-minute ioctl
  ROM-download loop, so short runs produce an empty (or stale) file that
  looks like broken instrumentation. Check the file's **format**, not just
  its existence, before concluding the probe is dead.
- Verilator `--public-flat-rw` makes the hardware build roughly 10x slower.
  Add explicit `output` ports to `tdragon2_hw_top.sv` instead.

The probe itself is committed (the `TB_XDUMP` blocks in `tb_tdragon2.cpp` /
`tb_tdragon2_hw.cpp` and the `dbg_*` ports on `tdragon2_hw_top.sv`), so the
dumps are regenerable and none was kept — they run to several MB. Write them
as `TB_XDUMP=<name>.xdump`: that extension is gitignored, where a blanket
`sim/rtl/*/*.txt` rule would wrongly cover the tracked
`sim/rtl/powerins_*/cmp_*.txt`.

#### NMK-21c · Afega boards flip from the DIP bus, not from a CPU write
`afega_map` has **no `flipscreen_w` at all**, so `flip_screen_reg` is never
written and the fix above does nothing for that family.
`afega_state::video_update` reads the DIP word live every frame instead, as
two independent axes:

```cpp
flip_screen_x_set(BIT(~m_dsw_io[0]->read(), 8));   // horizontal
flip_screen_y_set(BIT(~m_dsw_io[0]->read(), 9));   // vertical
```

Always bit 8 = X and bit 9 = Y regardless of which one that port set happens
to *label* "Flip Screen" — `grdnstrm` names bit 9 Flip and bit 8 Mirror,
`grdnstrk` names them the other way round. Implemented in `gunnail_core.sv`
as `flip_x`/`flip_y` driving `rd_x_flip`/`rd_y_flip` separately, gated to the
seven game ids whose machine config keeps `screen_update_afega`:
`G_STAGGER1`, `G_REDHAWK`, `G_GRDNSTRMK/J/G`, `G_REDFOXWP2/A`. The sets on
`screen_update_firehawk` (grdnstrm, grdnstrmau, firehawk, spec2k),
`screen_update_redhawki`, `screen_update_redhawkb` and
`screen_update_bubl2000` (popspops, mangchi, bubl2000, hotbubl) read no DIP
in MAME and correctly ignore it here too.

**Deliberate divergence from MAME:** MAME flips only the tilemaps on these
boards and leaves the sprites in place (the `grdnstrm` GAME line says
"flip-screen doesn't work on sprites for all sets"). That reads as a MAME
limitation rather than board behaviour, so this core mirrors the whole
composed output, as the other three families already do. Measured on
grdnstrmk against MAME frame 600:

| | differing pixels (of 57,344) |
|---|---|
| our unflipped vs MAME unflipped | **0** |
| our Y-flipped vs MAME Y-flipped | 5,038 |
| MAME Y-flipped vs Ymirror(MAME unflipped) | **5,038** |

i.e. the entire difference is the sprite set MAME declines to mirror, and
nothing outside it. Our sim frame 598 corresponds to MAME frame 600 (the
neighbours differ by ~1,000 px; only 598 hits zero).

#### Verification on the DE10-Nano (2026-09-14)
Two boot-to-attract runs per game, DIP off and on, compared as
`flipped == rot180(unflipped)` on native `screenshot` PNGs (**not** the
capture box — its downscale hides pixel differences):

| core | game | exact matches | frame content |
|---|---|---|---|
| NMK16_Macross2 | tdragon2 | 9/11 | demo, ~80k lit px |
| NMK16_Gunnail | gunnail | **10/10** | demo, ~80k lit px |
| NMK16_Raphero | raphero | 8/10 | demo, ~80k lit px |
| NMK16_Afega | grdnstrmk, X axis | **8/8** | demo, ~55k lit px |
| NMK16_Afega | grdnstrmk, Y axis | 7/8 | demo, ~55k lit px |

Non-matching frames are attract-animation drift between separate boots, not
geometry: on the one grdnstrmk Y miss the flipped frame differs from
`Ymirror(off)` by 5,617 px while the competing hypotheses differ by 25,000+.
Regression controls: grdnstrm (the no-flip Afega set) stays byte-identical
with the DIP on, and gunnail is unaffected by the shared `gunnail_core.sv`
edit. Corroborated in simulation — hardware path vs reference path under
flip, tdragon2 frames 210-390 sampled every 10, **19/19 pixel-exact** (all
title-screen frames; the sim's attract had not reached the demo, so the
sprite-and-scroll evidence for that core is the board captures).

- **Harness trap that faked a null result:** MiSTer reads DIP overrides from
  `config/dips/<mra name>.dip`, **not** `<setname>.dip`. The stale
  `tdragon2.dip` left over from the 2026-09-09 .mra rename was being ignored,
  so the first "flipped" run came back byte-identical to the unflipped one
  and looked like the core still dropping the DIP.
- Earlier readings in this entry that the x_look fix superseded — "0 of 31
  non-blank frames equal rot180", "ROM CHECK text renders at the unmirrored
  x" — were taken against the pre-fix build and no longer describe this RTL.
  A related retraction: an intermediate "68/99 frames exact" was vacuous
  because all 68 were blank boot frames. **Always report the non-blank count
  alongside any frame-match statistic.**

### NMK-22 · The V-PROM was compiled into the bitstream
- **Cores:** all four · **Severity:** bug (redistribution) · **Status:** **fixed
  and swept on hardware 2026-09-15**
- `nmk_irq.sv` read its scanline-timing V-PROM with `$readmemh` at synthesis,
  so every shipped `.rbf` carried 256-2304 bytes of arcade PROM dump, and the
  Quartus build needed locally generated `roms/*_vtiming.hex` that could not
  be committed. A clone therefore could not build, and the distributed
  bitstreams contained ROM data.
- Now streamed like every other ROM: each `.mra` carries the PROM as its own
  **`<rom index="1">`** region and the core writes it into `nmk_irq` from
  `ioctl_download`. Index 1 has its own address space, so **no SDRAM region
  base moves** — the constraint that makes adding a region to index 0
  dangerous (see NMK-17). 48 of the 97 sets get a region; the other 49 are all
  `irq_hacky` boards that read no PROM, verified set by set.
- **Adding a write port turned the array from a constant into a RAM, so the
  read had to become registered** — an asynchronous read would have cost 4096
  flops. NMK-10 for the fourth time. The sample now runs off a one-cycle
  delayed `line_start`, which is safe because `line_start` is
  `ce_pix & (hcount==0)`, exactly one cycle wide, and `vcount` is already the
  new line's value at that edge. The fit confirms it: **M10K +3 and ALMs
  slightly DOWN on every core**, which is what a real block RAM looks like.
- **ssmissin/airattck/airattcka needed a transform, and the recipe for it had
  been lost** — the baked table was built by an undocumented one-off step. It
  was recovered by analysis: `ssm-pr1.114` (and `82s147.uh6`, same CRC
  ed0bd072) is a **half-populated 512-byte dump of a 256-byte device** in
  which every 32-byte block with address bit 5 set was never programmed and
  reads 0x00. The real table is `table[i] == dump[{i[7:5], 1'b0, i[4:0]}]` —
  exact for all 256 entries, with all 256 skipped bytes zero. `gunnail_core`
  drops the hole blocks and compacts the address on load (`vprom_halfpop`);
  an `.mra` cannot express a transform, so it belongs in RTL.
- **Verified before building**: the whole load path was modelled off-board —
  extract each PROM from the zips its `.mra` actually names, push it through
  the RTL's address logic — and compared against the tables the bitstream used
  to bake in. **48 of 48 reproduce byte-for-byte, 0 failures.** That also
  proved the zip lists cover the clones that inherit a parent's PROM.
- **Swept on hardware**: all 97 `.mra` loaded one at a time, each given a
  settle, a screenshot, an injected coin-coin-start and a second screenshot.
  **97/97 boot, render and respond to input** (`tools/mister_sweep.sh`,
  `tools/analyse_sweep.py`). Four initially flagged — raphero, rapheroa,
  strahlj, strahlja — were the 26 s settle being too short, not defects:
  raphero's 15 MB upload alone takes ~18 s, and the flag was a colour-count
  heuristic firing on a legitimately 2-colour title logo and a text-mode DIP
  page. At 45 s all four pass. **Judge a "flat screen" by what the game draws
  next, not by the colour count of one frame.**

## NMK16_Gunnail

### NMK-6 · Audio band correlation not re-measured since the sequencer fix
- **Severity:** gap · **Status:** fixed (measured 2026-09-10)
- **Ref:** "OKI still ~8-13 dB too quiet" (table) and "Fourth pass…"
- Last `tools/audio_compare.py` figure on hardware was 0.849 (90 s,
  +2.4 dB) *before* the TLCS-90 fixes; post-fix verification had been
  YM-write activity only. Re-measured on the board with the shipped
  `NMK16_Gunnail.rbf` (attract from boot, MAME `-wavwrite` 100 s vs board 110 s,
  `--offset-search 20`): **0.919 mean band corr / 0.951 envelope over
  100 s, −1.1 dB**; **0.968 / 0.997 over the first 60 s, −1.3 dB** — the
  same range as Thunder Dragon 2 on hardware (0.987). The 100 s figure
  is pulled down by NMK-7 (demo diverges after ~1 min), not by audio.

### NMK-23 · tharrier ignores Coin A = Free Play (its MCU is undumped)
- **Cores:** NMK16_Gunnail · **Severity:** limitation · **Status:** wontfix —
  matches MAME; not fixable without a dump of the MCU
- Setting **Coin A (or Coin B) to Free Play** in the DIP Switches menu has no
  effect on `tharrier`/`tharrieru`: the attract still reads INSERT COIN and
  Start does not begin a game.
- **The DIP reaches the core correctly** — checked end to end before blaming
  the game. The `.mra` field is `bits="5,7"`, matching MAME's `0x00E0` mask,
  with `ids` in value order so `Free_Play` is value 0; `NMK16_Gunnail.sv`'s
  `game_mustang` list includes game id 20, so `dsw1_i = {dip_sw[1], dip_sw[0]}`
  and Coin A lands in `dsw1_i[7:5]`. Nothing is dropped or mis-ordered.
- **MAME behaves identically.** With Coin A forced to Free Play from a cfg file
  (`:DSW1` verified reading `FF1F`), MAME's attract is **pixel-identical to the
  default DIPs across 41 sampled frames** of a 22 s run. We match the reference.
- **The cause is in MAME's own source.** tharrier's MCU is undumped and MAME
  fakes it with a 15-byte canned table (`to_main[]` in `tharrier_mcu_r`). At
  that read path the comment reads: *"it should also read DSW1 from here,
  almost certainly through the MCU. The weird 0x080202 address where we read
  IN2 is also probably just a mirror of 0x080002"*. The coinage logic lives in
  silicon nobody has dumped, so neither MAME nor this core can honour Free Play.
- **`tharrierb` DOES honour it**, which is what isolates the cause: the
  Lettering bootleg runs a real, fully dumped MC68705R3 here (NMK-22 era work,
  `docs/tier7-tharrierb.md`). Same core, same DIP plumbing, same setting —
  Start with Free Play boots straight into a game. On the board, `tharrier`
  differed from its default run by **0 px** while `tharrierb` differed by
  **43,885 / 57,334 px** (attract vs. a game in progress). **Use the Lettering
  bootleg set if you want Free Play on this game.**
- **Both Coin entries are now hidden on `tharrier`/`tharrieru` (2026-09-16).**
  Offering a setting that provably cannot work is worse than not offering it,
  so the two `<dip>` lines are gone from those two `.mra` and from the
  `THARRIER` spec in `tools/gen_gunnail_mra.py`. The bits keep the
  `switches="FF,FF"` default (all ones = the last id = **1C_1C**, which does
  work), and `tharrierb` keeps both entries because its MCU is dumped and it
  honours them.
- **Method caveat worth repeating:** MAME's Lua `field:set_value()` silently
  does nothing in this build — the same failure as the DIP-setting attempt in
  NMK-21 — so the MAME half of this rests on attract comparison, not on
  pressing Start. Force DIPs through a `-cfg_directory` file and verify with
  `port:read()`; drive Start on the board instead, where `mister_keys.py`
  works. A control that fails (here: coin+start also changed nothing in MAME)
  is the signal the harness is broken, not the game.

### NMK-25 · Sprite tile codes above 3x the ROM's tile count fetched the wrong graphics
- **Cores:** all four · **Severity:** bug · **Status:** fixed (2026-09-16)
- **Symptom:** a sprite renders correctly one moment and as a block of
  *coherent but wrong* graphics the next. Reported on hachamf's character over
  **GAME OVER** and on the name-entry screen; it flickers because the game
  alternates that sprite with others, not because anything is racing.
- **Cause:** `video_macross2.sv` wrapped the tile code with **two** conditional
  subtractions, which is only correct below `3 * spr_units`. MAME does a true
  `code %= total_elements` (`gfx_element`). hachamf draws its big character
  with code **0x81D6 = 33238** against `spr_units = 8192`:

  | | tile | result |
  |---|---|---|
  | MAME | `33238 % 8192` | **470** |
  | old RTL | `33238 - 2*8192` | **16854** |

  16854 is not merely the wrong tile: `16854 * 128 = 0x20D700` is past the end
  of the 1 MB sprite ROM, so the fetch returned a different region's graphics.
  That is why the corruption looked like real artwork rather than noise.
- **Not specific to hachamf, and not new.** The old chain was wrong for
  **206,072** of the reachable code values (a 16-bit code plus up to 255 units
  for a 16x16 sprite): 41,215 bad codes at `spr_units=8192`, 53,503 at 4096.
  Confirmed pre-existing by running the **pre-NMK-24 bitstream** on hardware
  with the same `.mra` and no `.nvm` -- identical signature, 6 corruption
  events over 240 GAME OVER frames.
- **Fix:** every `spr_units` these cores use is either `2^k` (1, 4096, 8192,
  16384, 65536) or `3*2^k` (12288 acrobatm/strahl, 49152 raphero). Powers of
  two now use an exact mask; the rest use four conditional subtractions, exact
  below `16*spr_units` and therefore for any reachable code when
  `spr_units >= 4112`. **Keep that bound in mind before adding a smaller odd
  size.** Checked exhaustively against MAME's modulo over the whole code range
  for every value in use: **0 mismatches**.
- **It must not sit in the per-pixel path.** The first attempt put four chained
  32-bit compare-subtracts in series with the address multiply and the sprite
  cache's same-cycle `ready`, and **Afega failed timing at -6.248 ns**
  (TNS -6,157). The wrap depends only on `s_unit_code`, which is registered
  once per 16x16 unit in `S_SPR_UNIT`, so it is computed there into
  `s_unit_wrapped_r` at 21 bits: same value, same cycle, per-pixel path
  unchanged. Afega went **-6.248 -> +0.119**. Verilator compiled the bad
  version happily; only Quartus caught it.
- **Evidence (hardware, 60 fps capture, identical detector and conditions):**

  | build | GAME OVER frames | sprite-corruption events |
  |---|---|---|
  | pre-NMK-24 (seed 11) | 240 | 6 |
  | NMK-24 rework | 240 | 6 |
  | **NMK-25 fix** | 240 | **0** |

  Method: record the screen at 60 fps, select frames that are the GAME OVER
  screen, and count frame-to-frame changes confined to the sprite's bounding
  box. On a static screen any such change is corruption. Each event changed
  exactly 2,894 pixels -- the sprite toggling between two fixed renderings.

### NMK-23b · tharrier's Cabinet=Cocktail cannot flip the screen (undumped MCU)

**Not fixable without the MCU dump, and the core already matches MAME.** Two
independent blockers, both tracing to `upl.13m` being `NO_DUMP`:

1. **The flipscreen write is not decoded.** `tharrier_map` in `nmk16.cpp` has

   ```cpp
   //  map(0x080015, 0x080015).w(FUNC(nmk16_state::flipscreen_w));
   ```

   commented out (and `tharrierb_map` explicitly `unmaprw()`s `0x080014-15`
   with the comment `// flipscreen`). `gunnail_core.sv` mirrors that exactly:
   `decode[S_FLIP] = io && (r == 4'hA) && (m != M_THARRIER) && ...`. The game
   *does* issue the writes -- found in the 68000 ROM (`2.18b`/`3.21b`
   interleaved):

   | ROM | instruction |
   |---|---|
   | `0004F4` | `33C2 00080014`  `MOVE.W D2,$00080014` (D2 = a computed 0/1) |
   | `007972` | `33FC 0001 00080014`  `MOVE.W #$0001,$00080014` |
   | `0078E0`, `007958`, `007A2E` | `42F9 ...`  `CLR.W $00080014` |

   -- and both MAME and this core discard them.

2. **The flip bit is read from the wrong source, and nobody knows the right
   one.** The value written at `0004F4` is built as:

   ```
   0004D4: 3239 00080002    MOVE.W  $00080002,D1     ; tharrier_mcu_r
   0004E2: 0241 7FFF        ANDI.W  #$7FFF,D1
   0004EC: 3401             MOVE.W  D1,D2
   0004EE: E31A             ROL.B   #1,D2            ; bit7 -> bit0
   0004F0: 0242 0001        ANDI.W  #$0001,D2
   0004F4: 33C2 00080014    MOVE.W  D2,$00080014
   ```

   i.e. **flipscreen = bit 7 of the word read from `$080002`**. That address is
   `tharrier_mcu_r`, and for a *word* access MAME returns `~IN1`, whose bit 7
   is `IPT_COIN1` -- not Cabinet. MAME says so itself in that handler:
   *"it should also read DSW1 from here, almost certainly through the MCU"*.

   **So enabling the decode would make it worse, not better:** the screen would
   flip whenever a coin is held. The missing piece is the MCU's DSW routing,
   which is undumped -- the same root cause as NMK-23 (Coin A/Coin B hidden on
   tharrier/tharrieru).

Verified against MAME 0.289 with the Cabinet DIP genuinely set to Cocktail
(`DSW1 via bus = FEFF`): the only write to `$080014` in ~900 frames is a single
`0000` at boot.

**MAME Lua trap worth remembering:** `emu.add_machine_frame_notifier()` and
`space:install_write_tap()` return subscription tokens that must be stored in a
**global** -- when they are garbage-collected the callback silently stops
firing, which looks exactly like a script that never ran. Also
`manager.machine.screens[":screen"]` threw here, killing the notifier after its
first call; count frames in the callback instead. And the earlier note that
`field:set_value()` "does not stick" was wrong -- it was this same GC bug;
`f.user_value = 0` works, confirmed by reading the DSW back over the bus.

**Fixed in passing (NMK-23b), and CONFIRMED ON HARDWARE.** `th_in1` was a
17-bit concatenation assigned to a 16-bit wire (verilator `WIDTHTRUNC`), so the
MSB was dropped and every field above it sat one bit high -- `IPT_START2`
"in game" landed on bit 9 instead of MAME's `0x0100`, meaning **player 2 could
not join mid-game**. Corrected to sum to exactly 16 bits.

Verified by A/B on the DE10-Nano, identical scripted sequence both times
(4 coins, start 1P, play ~16 s, then two 0.8 s START2 presses), reading the
top HUD from the native screenshot:

  | | before START2 | after START2 |
  |---|---|---|
  | **pre-fix** (`20260917`, first build) | `1UP 2 0 ... PUSH START 2UP` | `1UP 0 100 ... PUSH START 2UP` |
  | **post-fix** (`20260917`, rebuilt) | `1UP 2 0 ... PUSH START 2UP` | `1UP 0 100 ... `**`2UP 2 0`** |

i.e. the "PUSH START 2UP" invite is replaced by a live 2UP score with 2 lives.
Rebuilt Gunnail fits at setup **+0.697** / hold **+0.246**.

The baseline was deliberately re-run with longer key holds and two presses
first: a press too short to register would fail identically in both halves of
the A/B and look like a fix that did not work. The input path was also checked
independently -- `NMK16_Gunnail.sv:264` maps keyboard `2` to `kb_start2` and
`in0_i` bit 4 is START2, so the press was reaching `th_in1` all along and
landing on the bit the game never reads.

**NOTE:** `gunnail_core` also backs `NMK16_Afega`, whose bitstream is therefore
one commit behind. tharrier does not run on that core so its games are
unaffected, but the two should be rebuilt together at the next release.

### NMK-24 · FIXED (2026-09-16). Was: eleven games halt once a high-score dump exists

**Resolved by `0c1a389`** -- `pause` was masking fx68k's `enPhi1`/`enPhi2`
independently, breaking the strict phase alternation the sequencer requires.
Verified on hardware by a full 82-set sweep on the post-fix `20260917`
bitstreams, with the 64 stashed `.nvm` dumps restored so the failing condition
was actually reached: **81/82 pass, and 10 of the 11 originally-broken sets are
recovered** (hachamf, hachamfa, hachamfb, hachamfp, strahl, strahlj, strahlja,
strahljbl, acrobatmbl, macross2g).

The one holdout, **macross2k, turned out to be a different bug entirely** -- a
data error, not the clock gating. See `HS_CHECK_OVERRIDE` in
`tools/gen_hiscore_mra.py`: its hiscore.dat block matches its siblings' except
the final record's check bytes at `1fd600` (`00,73` vs their `01,63`), and with
`00,73` the module's check never passes so it retries forever and hammers the
CPU. Given the parent's bytes it runs. Measured, hiscore ON with a dump:

  | macross2k config | result |
  |---|---|
  | hiscore OFF | runs |
  | `00,73` (dat as written) | FROZEN, both shots byte-identical, reproduced twice |
  | final record dropped | runs |
  | `01,63` (parent's bytes) | runs |

`HS_EXCLUDE` is now **empty**, and all 82 hiscore-enabled `.mra` ship their
regions.

Sweep-method notes worth keeping:
- The discriminator is the **A->B screenshot diff**, not whether shot A is
  blank. A wedged game freezes ~5 s after load so both shots are the same
  frozen frame; a blank shot A is just an attract fade at the 45 s mark.
  hachamf and hachamfa both read `A lit% = 0.0` while being perfectly healthy,
  and scoring on blankness would have reported them as failures.
- Status bits live in `config/<SETNAME>.CFG`, 16 bytes, little-endian:
  `status[39]` (High Scores) is **byte 4, bit 7 = 0x80**. Writing that file
  directly is equivalent to toggling it in the OSD (verified byte-identical
  against one MiSTer wrote itself), which is how 82 games get enabled without
  82 OSD navigations. `.nvm` files are named by MRA DESCRIPTION, `.CFG` by
  SETNAME -- they do not match.
- The dumps live in `/media/fat/hs_nvms/`. They had been moved out of
  `config/nvram/` to stop the games breaking, so **a sweep that does not
  restore them passes vacuously**.

---

#### Original investigation (kept for the method, and because the chain was wrong twice)

### NMK-24 · Eleven games halt themselves once a high-score dump exists
- **Cores:** NMK16_Gunnail, NMK16_Macross2 · **Severity:** bug ·
  **Status:** mitigated (hiscore removed from the affected sets and the whole
  feature off by default); **root cause confirmed 2026-09-16** — the NMK004
  resets the 68000 and the reboot never completes. Not yet fixed.
- **Symptom:** with a saved `.nvm` present, the game boots, draws, then stops
  responding, with audio at exactly 0.0 RMS. Delete the `.nvm` and it is
  perfect.
- **THE CAUSE (confirmed on hardware 2026-09-16): the NMK004 sound MCU resets
  the 68000, and the game never finishes rebooting.** `gunnail_core.sv`'s
  `m68k_extReset = reset | (nmk004_p4[0] & has_nmk004) | prot_loading | ...`
  gives the sound MCU a direct line to the main CPU's reset. Probing each term
  separately with a sticky latch (armed only after `reset` has been low ~1.7 s,
  so the power-on reset cannot pollute it) and reading it off a screenshot:

  | | `reset` | **`nmk004_p4[0]`** | `prot_loading` | extReset edges |
  |---|---|---|---|---|
  | healthy | 0 | **0** | 0 | **0** |
  | frozen | 0 | **1** | 0 | **2** |

  The full chain: hiscore becomes active -> the NMK004 asserts its host-reset
  line -> the 68000 is reset mid-game -> boot re-runs from the reset vector
  `$007E42` -> boot writes the `BRA *` placeholder to `$0FEF00` and jumps
  there before the real routine is copied over it -> the CPU spins forever.
  Four independent measurements agree: the PC-trap (CPU spinning in RAM), the
  crash context (`JMP $0FEF00` reached from boot), the `$0FEF00` write snoop
  (the boot placeholder `60FE` is the LAST write, so boot ran after the game
  was already up), and this reset probe naming the term.
- **WHY the NMK004 asserts it: it takes a TRAP through vector `$0038`.** A
  4-deep history of the MCU's fetch PCs, frozen at the instant it asserts
  `p4[0]`, reads `$0082 <- $0083 <- $0085 <- $00A7` -- sequential execution in
  the boot ROM's low region. The vector table entry at `$0038` is
  `1A 82 00` = **`JP $0082`**, so that is the trap handler, and it ends:

  ```
  00A7: 37 C8 01    LD (FFC8),#$01   ; assert the 68000 reset (port 4 bit 0)
  00AA: 1A 00 00    JP  $0000        ; restart the MCU itself
  00AD: "All Music,E..."             ; ASCII diagnostic string
  ```

  So the sound MCU hits an error trap, deliberately resets the 68000 and
  restarts. The `$018B` assert caught by the earlier probe is the SECOND
  pass -- boot init after that restart. Full chain: trap at `$0038` ->
  handler `$0082` -> reset the 68000 at `$00A7` -> 68000 reboots -> `BRA *`
  at `$0FEF00` -> spin.
- **The `$0038` trap is INTT1, and the handler is a WATCHDOG.**
  `tlcs90.sv:1337` computes `irq_vector = 0x0010 + (irq_idx+3)*8`, so `$0038`
  is `irq_idx = 2` -- the third source, a timer interrupt. The handler decodes
  as:

  ```
  0082: 02       DI            ; disable interrupts
  0083: 9F 30    DECW ($30)    ; decrement the counter at $FF30
  0085: C6 20    JR Z,+$20     ; at ZERO -> $00A7, otherwise fall through
  0087: 09       EX AF,AF'     ; \ the ordinary music-tick work
  0088: 0A       EXX           ; /
  00A6: 1F       RETI
  00A7: 37 C8 01 LD (FFC8),#01 ; assert the 68000 reset (port 4 bit 0)
  00AA: 1A 00 00 JP $0000      ; restart the MCU
  ```

  `cc = 6` is ZF (`tlcs90.sv:559`), so the reset fires only when the counter
  reaches **zero**. Direct 8-bit addressing is the `$FF00+n` short form, so
  `($30)` is `$FF30` -- inside the internal RAM window `0xfec0-0xffbf`
  (`nmk004_core.sv:22`), not an SFR. `$0082` is just the normal music-tick
  ISR; the watchdog check is its first two instructions. (The ASCII after the
  handler is only a copyright banner, "All Music,Effect Software(C)1990 N M K
  Corporation" -- not a diagnostic.)
- **The reload is the NMI handler, and NMI means "the host sent a command".**
  The vector table is sparse -- only two live entries, everything else a bare
  `RETI`:

  | vector | source | target |
  |---|---|---|
  | `$0018` | NMI | `JP $0079` |
  | `$0038` | INTT1 (idx 2) | `JP $0082` |

  and `$0079` does nothing but reload the counter:

  ```
  0079: 0A            EXX
  007A: E3 FC EF 4A   LD HL,($EFFC)    ; per-game constant; hachamf: $0800 = 2048
  007E: 4F 30         LDW ($FF30),HL   ; reload the watchdog
  0080: 0A            EXX
  0081: 1F            RETI
  ```

  The same two instructions appear once more at `$0175`/`$0179`, in boot,
  immediately before the `37 C8 00 / 37 C8 01 / 37 C8 00` pulse at `$0188`
  that releases the 68000 -- i.e. boot arms the watchdog, then starts the CPU.

  **So the NMK004 resets the 68000 if it goes 2048 INTT1 ticks without a sound
  command.** The timeout constant lives at the top of the per-game external
  ROM (`$EFFC`), which is why the shared boot ROM can implement it generically.

  Note the search trap that hid this for a whole session: a scan for writes to
  `$FF30` found *nothing*, because the reload is opcode `0x4F`
  (`LDW ($FF00+n),HL`, `tlcs90.sv:480`) -- the register-store form. Scanning
  only the immediate (`0x3F`/`0x37`) and prefixed (`0xEF`/`0xEB`) forms misses
  it. When a byte-pattern scan over a ROM returns zero hits, enumerate the
  addressing modes from the decoder before concluding the write does not exist.
- **The watchdog does not drift from the pause.** `nmk004_core` passes the
  same `cen_eff` to BOTH the CPU core and `nmk004_periph`, and the timers are
  `cen`-gated (`nmk004_periph.sv` lines 166/236/333), so pausing the MCU
  pauses its timers too. The counter and the main loop stay in step -- a pause
  alone cannot expire the watchdog.
- **MEASURED: the watchdog is DOWNSTREAM. The causal chain recorded earlier in
  this entry was backwards.** The NMI that reloads the counter is raised by an
  ordinary 68000 register write (`sel_nmi & cpu_write`,
  `gunnail_core.sv:2021`), not by a RAM access -- so a *paused* 68000 still
  reloads it, and only a *wedged* one stops. `sim/rtl/gunnail_hs` with the real
  `hiscore.v`, hiscore ON, 260M ticks (`tb_gunnail_hs.cpp`, the `$0082` /
  `$00A7` / `$0FEF00` taps):

  ```
  watchdog ISR($0082) 939 entries (first tick 26147266)
  watchdog FIRE($00A7) 0
  68000 spin($0FEF00) 409199 fetches (first tick 10144920)
  ```

  The 939 ISR entries span ~234M ticks, i.e. one per ~249k ticks: at
  clk_sys = 40 MHz that is **INTT1 ~= 160 Hz**, so the 2048-tick timeout is
  **~12.8 seconds of continuous silence**. Two consequences:

  1. The watchdog cannot be the initiating cause of a freeze that appears
     immediately -- it needs ~13 s of silence to expire. The **two** reset
     edges the hardware probe measured are two such cycles: wedge -> watchdog
     -> reset -> reboot -> wedge again.
  2. This sim can never exercise the watchdog at all: 260M ticks is 6.5 s,
     half a single timeout. Any future test of the reset path needs ~800M+
     ticks (45+ min), and the `wd_fire = 0` above is therefore **not**
     evidence that the reset does not happen -- only that it is out of range.

  So the first cause remains the hiscore arbitration wedging the 68000, and
  the whole `$0038` -> `$00A7` -> reboot -> `$0FEF00` chain documented above is
  a *symptom*. Work the arbitration, not the MCU.
- **The hiscore-OFF control, same binary, same 260M ticks** (`gunnail_hs`,
  `run_wd_on.log` / `run_wd_off.log`):

  | metric | OFF | ON |
  |---|---|---|
  | frames rendered | 366 | 366 |
  | 68000 instructions | 10,942,638 | 8,470,348 (**-22.6%**) |
  | watchdog ISR entries | 1127 | 939 (-16.7%) |
  | host commands | 22 | 23 |
  | distinct PCs, final quarter | 366 | 473 |
  | `$0FEF00` spins | 409,202 | 409,199 |
  | last-frame nonzero px | 57,344/86,016 | 13,835/86,016 |

  Three metrics are now **retired as useless** for this bug, each having
  briefly looked like evidence:
  - **`$0FEF00` spin count** -- 409,202 vs 409,199. Identical. It is the
    game's normal idle-until-interrupt loop, entered every frame.
  - **host-command count** -- 22 vs 23. The "23 vs 243" reading was a
    comparison against a *differently configured* older run, not a control.
  - **distinct PCs in the final quarter** -- ON is *higher* (473 vs 366).

  What does separate them is the 68000 losing **22.6% of its instructions**,
  and the frame content diverging. Note the MCU only loses 16.7%, so the CPU
  is slowed ~7% more than the sound MCU rather than exactly in step -- far too
  little to matter against a 12.8 s watchdog, but worth knowing.
- **Caveat on the `$0FEF00` tap:** first-spin tick 10.1M is 0.25 s, which is
  *boot* -- `$007F2A` jumps there on every power-up, so "first spin" fires even
  on a healthy run. The control above then showed the *count* is useless too.
- **hachamfp (NO protection MCU) is CLEAN in sim on current master, and that
  puts the MCU path back in scope.** Same harness, `SEL=11`, 260M ticks, using
  hachamf's hiscore config -- which is legitimate: hiscore.dat gives
  `hachamfa`/`hachamfp` `fc000,3df,01,4e` and `hachamf`/`hachamfb`
  `fc000,3f0,01,4e`, i.e. the **same address and the same start/end check
  bytes**, differing only in length, so the module engages identically.

  | | hachamfp OFF | hachamfp ON |
  |---|---|---|
  | distinct PCs, final quarter | 387 | 387 |
  | 68000 instructions | 11,579,446 | 11,415,789 (**-1.4%**) |
  | last-frame nonzero px | 57,344 | 57,344 (identical) |

  1.4% and identical frames = hiscore engages, completes and settles. Compare
  hachamf's -22.6% with diverging frames: something there keeps thrashing.

  **So the split is the opposite of what this entry assumed.** The set WITHOUT
  the protection MCU is fine; the set WITH it is not. The earlier note that
  "the MCU-less hachamfp fails too, so this is not about protection" was
  measured on the shipped `20260916` bitstreams, which **predate both committed
  fixes** (`b22abee` `~pause`, `52963f3` CPU read latch). The sim builds from
  master and has them.
- **`HS_EXCLUDE` in `tools/gen_hiscore_mra.py` is STALE and must be
  re-measured.** Every set on that list was determined on pre-fix bitstreams.
  hachamfp already looks clean in sim with the fixes present, and the release
  chore (rebuild all four cores from master, re-run the hiscore sweep) is the
  thing that decides which entries can come off. Do not treat the current list
  as the set of genuinely broken games.
- **Caveat on the pixel count:** 13,835 vs 57,344 px is not yet established as
  a wedge. The ON run is 22.6% slower, so it is at a different point in the
  attract loop, and a blank-ish screen may simply be a transition. Deciding
  this needs the frame *series* (`TB_DUMP_PPM=1 TB_PPM_FROM=330`, run in
  separate directories or the second run overwrites the first's PPMs): a
  wedged game shows a STATIC picture across many frames, a healthy one does
  not. Do not quote the single-frame number as a failure metric until that
  check is done.
- **What remains: what makes the MCU take that trap.** Freezing it mid-fetch
  is NOT it -- deferring `pause` to a fetch-free point (`snd_pause_eff`,
  sampled only while `~nmk004_rom_rd`) removed the `pause & snd_stall`
  coincidence entirely and changed nothing: hachamf 1, hachamfp 1, with
  hachamfb still 8 (no regression). Suspect instead either a bad opcode
  reaching the decoder or our TLCS-90 raising this trap spuriously when `cen`
  is gated. Identify which vector `$0038` is on the TMP90C840 and probe the
  trap condition directly.
- **Superseded:** `pause` does land mid-ROM-fetch (`pause & snd_stall` is 1
  frozen, 0 healthy -- that measurement stands), but it is benign; the model
  that it caused a stale-word latch was wrong.
- **What NOT to try: simply not pausing the sound MCU.** Splitting `pause` so
  hiscore gates only the 68000 (leaving NMK004/Z80 running) **regressed**
  `hachamfb` from 7/8 to 3 and fixed nothing -- it breaks the 68000<->NMK004
  handshake in a new way. Pausing both together is also not enough, since that
  is what the shipped build does. The fix must stop the MCU deciding to assert
  the line, not change who gets paused.
- **Earlier framing, now superseded:** the halt at `$0FEF00` was first read as
  an error handler the game jumps to on failure. It is not -- `$007E42` is the
  **reset vector**, so that code is boot, and `BRA *` is a placeholder boot
  installs before copying the real routine over it. hachamf's 68000 is not
  crashed, stalled or starved — it is *executing an infinite loop it installed
  on purpose*. From the ROM (`mame_roms/hachamf.zip`, `7.93`/`6.94`
  interleaved):

  ```
  007E82: 33F9 00007F30 000FEF00   MOVE.W  $00007F30,$000FEF00  ; copy 60FE...
  007E8C: 2E0F                     MOVE.L  A7,D7                ; ...i.e. BRA *
  ...
  007F1E: 2E47                     MOVEA.L D7,A7                ; restore SP
  007F20: 598F                     SUBQ.L  #4,A7
  007F22: 33FC 00FF 000FEF18       MOVE.W  #$00FF,$000FEF18     ; set a flag
  007F2A: 4EF9 000F EF00           JMP     $000FEF00            ; jump to it
  007F30: 60FE                     BRA     *                    ; the loop word
  ```

  `$0FEF00` is **main RAM**. The game copies `BRA *` there, stashes the stack
  pointer, and jumps in. So NMK-24 is an **error path in the game's own code**,
  reached because something upstream decided the machine was faulty.
- **How it was found, after six wrong answers.** Six candidate fixes were
  derived by reading the RTL. Every one was a real defect; **none was the
  cause.** What settled it was looking at the hardware instead: two debug
  bitstreams with an on-screen overlay (a few 8-px cells along the top of the
  active area, read back out of a native screenshot).

  | probe | what it showed |
  |---|---|
  | `hiscore.v` FSM state + `pause_cpu` | `pause_cpu` **0** while frozen for 48 s — *not* a stuck pause |
  | last instruction-fetch PC + fetch counter | PC `$0FEF00` (RAM, not ROM) and the counter still moving — CPU **alive** |
  | last in-ROM PC + first out-of-ROM PC (sticky) | jumped from `$007F2A`, stable across frames |

  Healthy hachamf runs at `$008DB2–$008DF6`. **Build the probe; do not reason
  about the symptom.** Each overlay build was ~35 minutes and worth more than
  every hypothesis that preceded it.
- **This explains what defeated every earlier theory.** It freezes even when
  hiscore provably never writes a byte (the never-matching-marker variant);
  slowing its retry rate **220x** (135,600/s -> 610/s) changes nothing; a
  single 5 s OSD pause is harmless (5/5 distinct frames after release); and
  `acrobatm` vs `acrobatmbl` land on opposite sides of a **byte-identical**
  hiscore config, as do `macross2` and `macross2k` on the **same 5504-byte
  dump**. Those are different games' self-checks reacting to the same
  perturbation — which is exactly why the affected set follows no structural
  rule and **must be measured per `game_sel`, never predicted**.
- **Affected (measured):** NMK16_Gunnail `hachamf`, `hachamfa`, `hachamfb`,
  `hachamfp`, `strahl`, `strahlj`, `strahlja`, `strahljbl`, `acrobatmbl`;
  NMK16_Macross2 `macross2k`, `macross2g` — 11 `.mra`, 7 `game_sel`. Their
  `<rom index="3">`/`<nvram index="4">` are removed and the sets are in
  `tools/gen_hiscore_mra.py`'s `HS_EXCLUDE`. The other **71** sets keep
  working high scores. All four cores have been swept with the feature ON.
- **Four real defects were fixed along the way. Keep them; none is the cause.**

  | fix | evidence it is real | why it is not the cause |
  |---|---|---|
  | `grant` ignored `hs_access`, so MCU writes were acknowledged then dropped | 242 -> 0; MCU bus 4,402 -> 22,885 | MCU-less `hachamfp` fails too |
  | `hs_access` held across the whole pause (`ram_intent_*` unconnected) | hard freeze -> boots further, animates | still stops short of play |
  | hiscore overrode the RAM port instead of yielding | stress sim 2 PCs -> 367, 1,000 px -> 57,344 | hardware unchanged |
  | `cpu_wants`/`grant` not qualified with `~pause`, and the CPU read the shared port live (DTACK-to-latch race) | recovered `hachamfb` and `strahl` (1 -> 7/8) | the other five still halt |

  The last two are cumulative and independent: `~pause` fixed `hachamfb` and
  not `strahl`; the CPU read latch fixed `strahl`. Both are in
  (`b22abee`, `52963f3`).
- **`hiscore.v` has NO synchronous reset** — `reset` appears only as
  `reset_last` (falling-edge detect) and a `reset == 0` guard, and nothing
  clears `pause_cpu`. Holding the module in reset therefore cannot release the
  CPU, so the "High Scores" option gates `pause_cpu` at the **output**
  (`hs_pause = hs_pause_raw & hs_enable`), not just the module's reset.
- **Where to resume:** the code at `$007EE0–$007F1E` — a series of
  `MOVE.W <ROM addr>,Dn` / `DBF` loops, with `$007E8C` stashing the stack
  pointer that `$007F1E` restores — has the shape of a self-test or protection
  check. Identifying which condition routes into `$007F2A` would name the
  exact thing the hiscore module disturbs. Note no arbiter work can prevent
  this: the game halts *itself*.


### NMK-20 · ssmissin BG "corruption": two missing driver behaviours
- **Severity:** bug · **Status:** **FIXED and confirmed on hardware
  2026-09-14**; the original "hardware-only" diagnosis was a
  misdiagnosis
- **Ref:** `/home/vboxuser/archive_e6e7074/FINDINGS.md` (superseded on
  this point), "Restoring ssmissin onto NMK16_Gunnail.rbf" in
  `docs/hw-bringup.md`
- S.S. Mission's highway/field scenes rendered with dense 1-pixel
  vertical striping. This was recorded as corruption appearing **only on
  real hardware** — the reason the set was withdrawn from `master`. That
  premise was wrong: the cause was `decode_ssmissin()`, a graphics ROM
  decode the port never implemented, which affected every path equally.

**Confirmed fixed on the DE10-Nano (2026-09-14)** with the rebuilt
`Arcade-NMK16_Gunnail_20260913.rbf` (md5 `536a6426…`, 0 timing violations,
+0.640 ns, 26,560 ALMs), on the same attract city scene that produced
the original report:

| terrain box | h-run | v/h |
|---|---|---|
| board **before** | 1.18 | **3.74** (hard 1-px vertical stripes) |
| board **after** | 7.62 | **0.30** |
| MAME, city scene | 2.13 | 1.55 |

  The zoomed terrain now shows the same **isotropic green/tan dither**
  MAME draws, with clean horizontal lane markings. (The residual numeric
  gap to MAME is only a different scroll position inside the crop box —
  the texture character is the thing that matters, and it matches.)

**No collateral damage** — both changed signals are shared, so four sets
were re-checked on the same bitstream: **tdragonb** (the other
`gfx_swap34` user, the one set that would break if the OR were wrong) —
coastline/boats/foliage correct; **Bombjack Twin** (exercises the
`txvram_addr` mux with a busy TX layer) — round 1-1 and HUD correct;
GunNail — in-game starfield/sprites/HUD clean; US AAF Mustang — Normandy
map intact.

**What was measured (2026-09-14):**

| comparison | result |
|---|---|
| board frame vs reference sim frame (city scene) | **byte-identical (md5)** |
| hw-path sim vs reference sim (city window, 96MHz-equivalent) | **224/224 pixel-identical** |
| hw-path sim vs reference sim (coastline window) | 202/202 pixel-identical |
| hw-path sim 96MHz- vs 120MHz-equivalent (coastline) | 203/203 identical |

  The reference sim (`gunnail_mg`, `HW_ROMS=0`) has **no SDRAM, no
  arbiter and no prefetch cache** — it reads ROMs from `$readmemh`
  arrays. The board producing a byte-identical frame therefore rules out
  the entire memory path. **The SDRAM controller, arbiter and
  `tile_prefetch_byte` caches are exonerated**, on the failing scene and
  at the correct clock ratio.

**The two defects, both found by reading nmk16.cpp rather than pixels
(2026-09-14).** Neither is observable in any ssmissin attract/title
frame, which is exactly why every pixel-based test — including the
archive's "477/477 pixel-exact" claim — missed them.

1. **`decode_ssmissin()` was never implemented** (`gunnail_core.sv`,
   `g_gfx_swap34`). MAME permutes every byte of the **`bgtile` and
   `sprites`** regions at init with `{0x7,0x6,0x5,0x3,0x4,0x2,0x1,0x0}`
   — i.e. **bits 3 and 4 swapped** — and that table is byte-identical to
   `decode_data_tdragonbgfx`; the source comment says so outright
   ("Like Thunder Dragon Bootleg without the Program Rom Swapping").
   This core already had the exact transform as video_macross2's
   `gfx_swap34`, applied to BG tiles and sprites, but wired only to
   tdragonb. It now reads `g_gfx_swap34 = g_tdb_dec | g_ssmissin`, which
   needs its **own** signal: `g_tdb_dec` also drives the program-ROM word
   swap, and `decode_ssmissin` explicitly does not touch the program ROM.
   Corrupts BG and sprite *graphics* wherever real artwork is drawn —
   ssmissin's title and early attract have an all-tile-0 BG, so they look
   perfect.

2. **`txvideoram`'s `.mirror(0x1800)` was treated as address bits**
   (`gunnail_core.sv`, `txvram_addr`). `ssmissin_map` maps 1024 words at
   0x0D0000-0x0D07FF with bits 12 **and 11** don't-care. The index was
   `byte_addr[11:1]`, which consumes bit 11, so a mirrored write lands at
   word 1024+ instead of aliasing into 0-1023. Measured in MAME over 1200
   frames: **ssmissin 4096 base / 0 mirrored; airattck 0 base / 4096
   mirrored** — airattck writes through the mirror *exclusively*, using
   both bits. So this is inert for ssmissin and **fatal for
   airattck/airattcka**, which share this map and game id 52: their TX
   layer would be entirely lost. That is a strong candidate for
   airattck's own long-standing "vertical streaks over the background/
   starfield". Now masked for this map only — every other board maps
   0x800 of TX with no mirror (bit 11 never set), and tomagic maps a real
   0x1000 with bit 12 as its mirror.

Neither fix moves ssmissin's reference-sim score (54/62 before and
after), as expected: frames 20-81 exercise neither path. They were found
by reading the driver source. Defect 1 is **confirmed on hardware**
(table above); defect 2 is **confirmed in simulation on airattck**:

| airattck vs MAME, frames 20-81 | pixel-exact |
|---|---|
| **with** the TX mirror fix | **55/62** |
| without it (control, same build) | 10/62 |

  The 7 remaining misses are 6 boot-lag black frames (`sim nonblack 0`)
  and one transition frame — the usual shape. Visually the unfixed build
  draws a column of garbage blocks down the right edge of the AIR ATTACK
  title, which is precisely the "vertical streaks" airattck was recorded
  as suffering; the fixed build is pixel-identical to MAME there. So the
  prediction made from reading `.mirror(0x1800)` — that ssmissin is inert
  but airattck loses its whole TX layer — is borne out, and **airattck is
  now shipped**, together with airattcka.

**A third defect on this map, found while shipping them (2026-09-14).**
airattcka boots into a black screen: it reads **0x0C000C**, which
`ssmissin_map` leaves unmapped and MAME's 68000 space returns as
**0x0000**, while this core's read mux has always defaulted unmapped
reads to **0xFFFF**. On 0xFFFF it computes a bad jump target and spins
forever in unmapped space at PC 0x5F0C56 — 1.37M instructions and 853k
writes in the window, against airattck's 2.53M/212k. Matched to MAME
**for this map only**: the 0xFFFF default is wrong everywhere in
principle, but no other shipped game reads an unmapped address, and
flipping it globally under 50 working games is not worth the risk.

| set | before | after |
|---|---|---|
| airattcka | 24/62 (black from frame ~50) | **55/62** |
| airattck | 55/62 | 55/62 (unchanged) |
| ssmissin | 54/62 | 54/62 (unchanged) |

  All three verified in gameplay on the DE10-Nano: clean BG, TX and
  sprites, no streaking.
Note the same-scene `video_state` harness still disagrees with MAME for
unrelated, unresolved reasons (see below), so it played no part in
validating either fix.

**Also disproven, each with evidence:**
- *Prefetch-cache false hit on an in-flight entry* — `tile_prefetch_byte`
  writes tags only together with `sd_valid`.
- *Tile bank* — exactly one `tilebank_w` in the whole attract, value 0,
  so every scene reads the same half of the BG ROM.
- *SDRAM row-thrash from the scene's tile codes* — the striped city
  scene thrashes **less** than the clean coastline (85.7 vs 93.5 row
  changes per tilemap row).
- *Sprite/gameplay load* — the attract demo stripes too.
- *SDRAM timing margin* — a build with `RASCAS_DELAY=3`,
  `PRECHARGE_DELAY=1` (both clean, +0.384 ns) changed nothing, matching
  `rtl/sdram.sv`'s own record of both failing before.
- *Anything analog* (setup/hold, clock phase, refresh decay) — a striped
  frame reproduced **bit-for-bit across two runs on two different
  bitstreams and separate power cycles**. Marginal analog behaviour does
  not repeat bit-exactly.

**What is still open:** whether the two fixes above fully account for
the reported appearance. They cannot be confirmed against ssmissin's own
attract frames (which exercise neither), and the striped scenes only
appear ~5000 frames in, by which point the demo has drifted from MAME
(best same-index match 34% differing — see NMK-7).

`sim/rtl/video_state` was extended for exactly this: it now takes the
runtime layer configuration as parameters (`RASTER`, `LOWRES`,
`NMK214_EN`, `CFG_RT`, palette bases/masks) plus whole-layer scroll
inputs for non-raster games, and `gunnail_core.sv` gained `STATE_*` file
parameters with `VIDEO_ONLY=1` so a MAME dump can be rendered through the
**full shipping core** instead of a hand-mirrored standalone
`video_macross2` (`make GCGAME=ssmissin GCSEL=52 GCDUMP=<dir>/ssm_
gcrun`). The gunnail control renders byte-identical to the committed
`render_05394.ppm`, and injection is verified live by a zeroed-VRAM
probe.

**That harness still disagrees with MAME on ssmissin (~52% at frame 900)
for reasons not yet isolated, so it has NOT validated the two fixes.**
What has been checked and is correct: the BG VRAM dump equals MAME's own
`:bgvideoram0` share; the tile ROM equals MAME's region; the snapshot is
the right frame; `m_scroll[0]` is genuinely {0,0,0,0} (no writes at all
in frames 898-901); the BG VRAM index mapping matches MAME's geometry
(marker probe: VRAM row N renders at screen row N-1, which is right
because `set_raw(...,278,16,240)` puts the visible area at y>=16 against
our `BITMAP_Y0=16`, and x cancels via `scrolldx(92)` vs visible-x-92);
and the core's tile decode is bit-identical to an independent Python
decode. Two dead ends worth not repeating: a Lua `write_u16` marker probe
into MAME's VRAM proves nothing, because the debug path writes the RAM
share **without** calling `bgvideoram_w`, so `mark_tile_dirty` never
fires and MAME keeps rendering cached tiles; and `register_frame_done`
state produces frame N+1, not N.

**The methodological lesson, which is the most reusable part.** This bug
carried four wrong conclusions — stale-serve, a 1-pixel shift, timing
closure, and "hardware-only" — plus several more during the 2026-09-14
session (sprite load, SDRAM bandwidth via `TB_RAM_PER2`, the whole
analog-timing line). **Every one of them traces to comparing frames that
were not the same scene.** The defects were then found in about twenty
minutes by reading `nmk16.cpp`'s `ssmissin_map()` and `init_ssmissin()`
line by line against the RTL. **When a game-specific rendering fault
resists pixel comparison, diff the driver source against the port before
investing further in measurement** — a missing `init_*` decode or a
mishandled `.mirror()` is invisible to every frame statistic and cheap to
find by reading. The archive's own headline
numbers — terrain mean colour-run 1.34 (hw) / 1.74 (MAME) / 2.28
(reference sim) — were measured on non-corresponding frames and
therefore never meant anything. Two specific traps:
- A colour-run or anisotropy statistic does **not** separate defect from
  artwork here. ssmissin's terrain is genuinely dithered, and its
  highway scenes are genuinely full of vertical structure: the reference
  sim scores v/h 3.56 on a city frame that is provably correct output.
  Whole-frame variants are confounded further by sprite coverage.
- Before comparing two frames, prove they are the same scene (a
  near-zero pixel diff), rather than assuming equal frame indices
  correspond.

### NMK-7 · Attract demo diverges from MAME after ~1 minute
- **Severity:** limitation (verification only) · **Status:** wontfix
- **Ref:** "GunNail (the "NMK16_Gunnail" rbf)"
- RNG / non-cycle-exact timing; only static scenes are pixel-comparable
  on the board. Not a gameplay bug. Use `sim/rtl/video_state` (MAME RAM
  dump rendered through the video module) for pixel-exact checks of
  later scenes.

## NMK16_Macross2 (tdragon2 / macross2 / powerins)

### NMK-18 · powerins is drawn with an 8 MHz pixel clock, not the board's 7 MHz
- **Cores:** NMK16_Macross2 (powerins only) · **Severity:** limitation · **Status:** fixed (2026-09-11) — see "Video output at the board's pixel clock" in hw-bringup
- **Ref:** "Power Instinct on the NMK16_Macross2 rbf"
- The shared raster is 512 px at 8 MHz; the real board is 448 px at
  7 MHz (`set_screen_midres`). The line period is identical (64 us), so
  timing, interrupts and the frame rate were already exact, but the 320
  visible pixels spanned 40 us instead of 45.7 us — invisible on HDMI
  (the scaler stretches to 4:3), 12.5 % narrower than the PCB on an
  analog monitor. A 7 MHz enable from 40 MHz is fractional (40/7).
- Fix: `rtl/video_retime.sv` re-clocks the core's raster through a
  two-line buffer onto a new 56 MHz video PLL (`rtl/pll_video.v`,
  50 x 28/25), reading it out at an exact 8 MHz (56/7, tdragon2 and
  macross2, 512 px) or 7 MHz (56/8, powerins, 448 px) — 3584 clocks =
  64 us per line either way — one line behind, and regenerates HS/VS/DE
  with the H/V Shift trims in the board's own pixel units. CLK_VIDEO is
  now 56 MHz. Verified by a two-clock Verilator unit test
  (`sim/rtl/video_retime_test`: pixel-exact readback, HTOTAL 512/448,
  DE 384/320 x 224 lines, sync widths, with and without trims) and on
  the board (native screenshots unchanged, HDMI stable on all three
  games).

### NMK-19 · Power Instinct prototype sets have no .mra yet
- **Cores:** NMK16_Macross2 · **Severity:** gap · **Status:** fixed (2026-09-11)
- `powerinspu` / `powerinspj` use a different board layout in MAME —
  `ROM_LOAD16_BYTE` sprite pairs and split BG/OKI files. Both `.mra`
  files are now generated by `tools/gen_family_c_mra.py` (parent spec
  `POWERINSP`): the eight sprite pairs are `<interleave output="16">`
  blocks with the odd-offset chip (`fo*`) on even stream addresses
  (`map="01"`) and `fe*` on odd — the convention GunNail's maincpu pair
  already used — which reproduces the parent's raw word-swapped file
  order that the core's parity word rebuild and sprite byte-swap expect.
  Verified on the board: both sets boot, the attract fight and a played
  round show intact sprites, backgrounds and text, audio plays. The
  bootlegs `powerinsa`/`powerinsb`/`powerinsc` remain out of scope:
  different sound hardware (`powerinsa` has no Z80; `powerinsc` is not
  working in MAME either).
  **Update (2026-09-12/14):** `powerinsa` and `powerinsb` are no longer
  out of scope — both were ported as NMK16_Macross2 runtime clone modes and
  ship (`powerinsa` really does have no Z80; its OKI is driven straight
  off the 68000). `powerinsc` does not: MAME cannot run it either
  (*"different sprites' format not implemented"*), and although the port
  boots, its sprites draw wrong the same way. Its `.mra` is generated
  into the gitignored `.non-working/` rather than `releases/`, so it is
  never shipped or deployed — see `tools/gen_family_c_mra.py`'s
  `NON_WORKING` set.

### NMK-8 · macross2 shows a dead "Button 3" in the OSD button wizard
- **Severity:** limitation (cosmetic) · **Status:** fixed (2026-09-10 — not dead after all)
- **Ref:** "Gamepad Coin broken on macross2 only", "Autofire (tdragon2 and macross2)"
- The shared core's CONF_STR has one fixed 5-slot `J1` list and
  MiSTer's default gamepad mapping is positional against the `.mra`'s
  `<buttons>`, so macross2.mra must declare 5 names even though the
  game's own input port reads 2. That third slot was assumed to be a
  dead placeholder — but the autofire mux gives it a job: while P1/P2
  Autofire is on (enabled for macross2 the same day), the player's
  Button 3 is OR'd into Button 1 as a plain, non-autofire fire, exactly
  as on tdragon2. So the button a user is asked to define is the
  "hold-to-fire-normally" button when autofire is active, and only
  unused when autofire is off. Documented as such in `NMK16_Macross2.sv` and
  the Autofire section rather than as a dead slot.

### NMK-9 · tdragon2 heavy-sprite slowdown: how much margin is left?
- **Severity:** limitation · **Status:** closed — headroom measured, not thin (2026-09-10)
- **Ref:** "Slowdown in play: 68000 wait states and the sprite pass"
  (see its dated "Headroom" addendum)
- Board holds 56.2 plane-swaps/s in all 45 measured windows (was
  44-50 in busy play). The original worry was that the margin was
  unknown: the old table extrapolated to a 1,214-unit frame from a
  MAME Lua count of the sprite *table*, not of what the hardware draws.
- The hardware itself bounds the pass. MAME's sprite-clock budget
  (`nmk16spr.cpp`: 16 clocks per scanned sprite + 128 per 16x16 unit,
  cut off at 512*263 = 134,656 for every hi-res game — gunnail,
  macross2, tdragon2 and raphero all call `set_screen_hires`) is the
  same constant `MAX_SPRITE_CLOCK` in `video_macross2.sv`, so no frame
  can ever hand the renderer more than ~1,051 units (1,051 with one
  large sprite, 935 with single-unit sprites).
- Re-measured on the current RTL (`sim/rtl/tdragon2_hw`, `TB_AUTOPLAY=1
  TB_RAM_PER2=5`, 400 M cycles, 347 gameplay frames): pass = 44.7 k +
  351 clk x units (r.m.s. fit, max residual +5.4 k), per-unit cost
  303/308/309 clk median/p99/max with 77-81 clk of it SDRAM stall,
  median frame 344 k, worst observed 354 k (49.8 % of the 711,744-clk
  frame), 0 late plane swaps after boot. At the 1,051-unit hardware
  bound the fit gives 414-420 k = 58-59 % of a frame, i.e. ~41 %
  headroom in the worst frame the game can construct. The stall
  component is structural, not scene-dependent: a unit's 128 bytes
  are contiguous and the next pair is prefetched while the current one
  is consumed, so the per-unit stall is the first-fetch latency only.
- 68000 ROM wait states on the same run: 3.9 k clk median / 4.9 k max
  per frame (0.55 % / 0.69 %), 32,104 instructions per frame. The
  "any added ROM-bus latency reappears here first" caveat still holds
  for future SDRAM changes; re-run the audit after any change to the
  ROM caches or port assignment.

## NMK16_Raphero

### NMK-10 · NMK16_Raphero build is at the edge of timing/utilization
- **Severity:** infra · **Status:** fixed (2026-09-10) — see "Utilization: the palette and the duplicated VRAMs" in hw-bringup
- **Ref:** "Rapid Hero / Arcadia", "OKI still…", "Flip screen option"
- Was ~82% ALM / 94% M10K with `SEED` churning 7 → 19 → 23 → 43 and
  the Flip-screen change alone pushing one seed to −0.065 ns.
- Two causes, both in how the wrapper cores coded their RAMs, neither
  in the video logic: (1) the 1024 x 16 palette lived in flip-flops
  behind three asynchronous 1024:1 read muxes (raphero_core's own
  logic: 14,776 ALMs / 23,855 registers, i.e. more than half the core);
  (2) every dual-read VRAM (mainram, bgvram, txvram) was a 16-bit array
  with lane writes whose old-data read-during-write Quartus can only
  meet with a simple-dual-port M10K set PLUS a second full copy for the
  video read (bgvram alone: 64 spare M10K).
- Fix: palette taps registered (block RAM, one M10K pair per read port;
  the video composite gained a stage), and the three VRAMs recoded as
  two 8-bit lane arrays with the CPU port in Quartus's true-dual-port
  template, which infers one BIDIR_DUAL_PORT set. Same seeds, no
  retries:

  | core | ALMs before → after | registers | M10K | setup slack |
  |---|---|---|---|---|
  | NMK16_Raphero | 34,179 (82 %) → 20,365 (49 %) | 46,135 → 28,694 | 520 (94 %) → 442 (80 %) | +0.296 → +0.533 ns |
  | NMK16_Macross2 | 29,548 (71 %) → 15,793 (38 %) | 39,114 → 21,504 | 517 (93 %) → 439 (79 %) | +0.135 → +0.320 ns |
  | NMK16_Gunnail | 27,023 (64 %) → 21,244 (51 %) | 36,924 → 25,485 | 407 (74 %) → 375 (68 %) | +0.403 → +0.535 ns |

- Verified: the three hardware sims are frame-identical (422/422) and
  instruction-count-identical before and after each step; the three
  reference sims build; the new RBFs boot, play sound and show correct
  colours on the board. The worst setup path in every build is the
  framework's `pll_hdmi` scaler clock, not core logic (`clk_sys` has
  > 1.9 ns). NMK-1's "practical blocker" no longer applies.

## Verification gaps (works, not proven)

### NMK-11 · macross2 autofire verified via OSD only
- **Severity:** gap · **Status:** fixed (2026-09-10 — confirmed by the user in manual play on the board)
- The setting had only been seen to take hold in the OSD; no gameplay
  firing-rate capture was made for macross2 specifically (mechanism is
  tdragon2's already-proven path with the `& ~game_macross2` gate
  removed). Manual testing on the DE10-Nano confirmed autofire fires
  in macross2 gameplay, closing the gap.

### NMK-12 · New Orientation/Flip options not re-verified for settings persistence
- **Cores:** all three · **Severity:** gap · **Status:** fixed — verified on the box (2026-09-10)
- Vert 270 / Vert 90 / Flip screen were each verified by HDMI capture,
  but "Save settings → reload core → option still set" had only been
  checked for the original single-choice Orientation on tdragon2.
- Verified now on tdragon2 (NMK16_Macross2.rbf), gunnail and raphero, both
  directions: set Orientation Vert 90 / Flip screen On / H Shift +14 /
  V Shift +20 → OSD > System > Save settings (cursor confirmed on
  "Save settings", not "Reset settings", before each Enter) → reload
  the .mra → all four values come back; then restore Horz / Off / 0 /
  0 → save → reload → defaults come back. The box is left at defaults
  with a saved `config/<mra>.CFG` for each of the three .mra files.
  One procedural note for `tools/mister_keys.py` scripting: F12
  toggles the OSD, so a sequence must track whether the menu is open —
  a first pass sent the restore key presses into the game on two cores
  because the OSD had been left open after a capture.

## Documentation

### NMK-13 · `docs/hw-bringup.md` "Status" section and picture-offset item 2 are stale
- **Severity:** infra · **Status:** fixed (2026-09-10)
- The "## Status" section said input mapping was "not yet exercised in
  play on hardware" and the picture-offset section's item 2 listed the
  Orientation OSD option as "the remaining follow-up" — both long
  resolved. Rewritten: Status now summarizes the three shipped cores'
  verified state and defers the open-item list to this file (so it
  can't drift again), and item 2 points forward to the Orientation
  section.

### NMK-15 · raphero_hw sim: one OKI0 sample byte unserved at latch
- **Cores:** NMK16_Raphero, NMK16_Macross2 (both have NMK112) · **Severity:** gap (sim-observed residual) · **Status:** fixed (2026-09-10; all three RBFs rebuilt, deployed and board-checked)
- **Ref:** "NMK-15: the one OKI byte the fetch-hazard fix left" in hw-bringup; `rtl/nmk112/nmk112.sv` `hold`
- Symptom: `raphero_hw`'s golden-byte audit reported `oki0 727249
  latches / 1 wrong`, also "unserved at latch" — i.e. the chip latched
  a byte while `rom_ok=0`, which the `cen` stall gating is supposed to
  make impossible. Pre-existing (identical against the previous
  `tlcs90.sv`).
- Root cause (from a per-mismatch diagnostic that prints the previous
  two clocks): one clock before the latch the address was `0x1D0000`,
  resident, and the gated `cen` passed; at the latch it was
  `0x170000`, not resident — same 64 KB-page offset, different bank,
  **no cache fill on either clock**. jt6295 registers its internal
  pulses (`cen_sr32`) one clock after the gated `cen`, so the ADPCM
  latch lands one clock *after* the stall check; an NMK112 bank-register
  write from the sound CPU (sampled on `clk`, not `cen`) landing on the
  edge that sampled the passing `cen` changes the remapped address
  combinationally inside that window. The chip's own address pipeline
  can't do this (its updates are cen-aligned, ten clocks apart); only
  clk-asynchronous CPU writes can, and only NMK112 bank writes are
  (jt6295's phrase-start address load is cen4-aligned). NMK16_Gunnail has no
  NMK112 — hence its permanent 0/0.
- Fix: `nmk112.sv` gains a `hold` input; each core drives it with "a
  gated OKI cen is passing this clock" and a write arriving then is
  captured and applied one clock later, after the latch (a 25 ns shift,
  far inside MAME's own sub-sample write/fetch ordering). Decisive
  check: the pre-fix cache with the hold alone, on the *original*
  timeline (same 727,249 latches, same stall count), gives 0 wrong / 0
  unserved with 40 writes deferred and 0 lost. A first hypothesis — a
  prefetch fill overwriting the line being read in the same window —
  was refuted by the diagnostic (no fill occurred); the guard written
  for it is kept in `oki_rom_cache.sv` since it closes a real sibling
  hazard, but it fired 0 times on every OKI cache in every run and was
  not the fix (its 0-wrong result came from perturbing the audio-CPU
  cache's timing, which is why the diagnostic was needed).

### NMK-16 · tdragon2 HUD text column differs from MAME on alternating frames (~130 px)
- **Cores:** NMK16_Macross2 (tdragon2 measured) · **Severity:** limitation (0.15% of the frame) · **Status:** closed — boot-phase software timing, not the video path (2026-09-10)
- **Ref:** "NMK-16: the HUD marquee is two frames out of phase with gameplay"
- With the sim and MAME frame-aligned on gameplay (sim *S* = MAME
  *S-3*), 2 of every 4 frames differ by 126-141 px in one 14-px strip
  (x 353-366) — the vertical HUD text column. The first guess (a TX
  write landing between the strip's scanout and VBOUT) was wrong:
  `TB_LOG_M68K` shows the strip is TX columns 36-39 (written through
  the 0x1719xx mirror — `txvram_addr = byte_addr[11:1]`, and MAME maps
  0x170000-0x170FFF with `.mirror(0x1000)`, so both fold it the same
  way), rewritten *every* frame in vblank (vpos 249-263), with 12 of
  its 84 cells stepping through tile codes 321E → 3220 → 3222 → 3224
  every 4 frames — a 16-frame marquee. A vblank write is visible on
  the next frame on both sides, so display timing cannot separate
  them. A strip-only diff matrix (sim frames 1148-1166 × MAME
  1150-1165) then shows the marquee cells aligning at sim *S* = MAME
  *S-1* (0-6 px on that diagonal, 63-105 px off it) while everything
  else aligns at *S-3*: the marquee runs 2 frames out of phase with
  gameplay, exactly the 2-of-4 pattern. Both are 68000 software
  counters started during boot; the RTL's boot lands gameplay 3 frames
  later than MAME but the marquee counter only 1 frame later — the
  same boot-handshake timing class as NMK-3 (most plausibly the
  68000's wait on the Z80/YM2203 init busy-loops). Both video paths
  are exact on their own diagonals; nothing to fix.

## Not shipped (for completeness)

### NMK-14 · `gunnailb_core.sv` (sim-only) had the unqualified Z80 read mux
- **Severity:** bug (sim-only, no RBF) · **Status:** fixed (2026-09-10)
- **Ref:** "The second bug the first one exposed: the Z80 read mux"
- The three hardware cores qualify every memory select with
  `z80_mem_re`; the bootleg's core did not. Fixed the same way: the
  `sel_z80_rom`/`sel_z80_bank`/`sel_z80_ram` arms of the read mux are
  now `z80_mem_re & sel_z80_*`, so an `in a,(n)` (which drives A on
  A15..A8) can no longer be answered with a ROM/bank/RAM byte instead of
  the YM2203 status or sound-latch port.
- Evidence (`sim/rtl/gunnailb`, `make run`, 300 M clk_sys cycles, same
  timeline before/after; the 68000 side is identical in both runs —
  13,198,403 instructions, 345,205 writes, last PC $00C35C, 3 NMIs):

  | metric | before | after |
  |---|---|---|
  | Z80 instructions | 7,442,532 | 4,093,349 |
  | Z80 writes to YM2203 | 9 | 563 |
  | last Z80 fetch PC | $0AA5 | $0570 |

  Before the fix the bootleg's Seibu-style driver spun in its YM2203
  busy-wait reading program ROM (9 FM writes in 422 frames); after it,
  the driver runs its normal sequencer loop and programs the chip.
