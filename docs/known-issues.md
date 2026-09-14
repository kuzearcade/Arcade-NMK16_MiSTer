# Known issues and areas for improvement — released cores

Tracked list for the four RBFs shipped in `releases/` (`Macross2`,
`Raphero`, `Gunnail`, `NMK16_Afega`). One entry per issue with a stable ID; update the
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
- **Cores:** Macross2, Raphero, Gunnail · **Severity:** limitation · **Status:** not a bug (measured 2026-09-10 — the core matches MAME and the PCB exactly)
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
- **Cores:** Gunnail, Raphero (shared `tlcs90.sv`) · **Severity:** gap · **Status:** closed — characterized as a benign boot-phase timer phase offset (2026-09-10)
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
- **Cores:** Gunnail, Raphero (NMK004 / bare TLCS-90) · **Severity:** gap · **Status:** closed — explained (2026-09-10)
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
- **Cores:** Gunnail, Raphero (+ every sim-only TLCS-90 game) · **Severity:** infra · **Status:** fixed (unreleased — harness only, no RBF change)
- **Ref:** this file; `sim/rtl/tlcs90/`
- All seven opcode self-tests (`banktest`, `blocktest`, `rldtest`,
  `muldivtest`, `ldarcallrtest`, `switest`, `extest`) and the base `run`
  target failed with every result reading `0x00`. Root cause: `tlcs90.sv`
  gained a `cen` clock-enable input for Raphero's 14 MHz path; the
  NMK004/protection wrappers tie it high, but the eight raw-module
  testbenches never drove it, so Verilator left it 0 and the CPU never
  stepped. Fixed 2026-09-10 by setting `top.cen = 1` alongside reset in
  each testbench; all eight pass, plus `run-irqtest`/`run-nmk004`.
- **Follow-up (open, see NMK-5):** none of these tests cover the two
  bugs found via register tracing.

### NMK-5 · No regression test for the XCF-on-INC/DEC and SET/RES-on-register fixes
- **Cores:** Gunnail, Raphero · **Severity:** infra · **Status:** fixed (unreleased until the Raphero/Gunnail RBF rebuild lands — see below)
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

## Gunnail

### NMK-6 · Audio band correlation not re-measured since the sequencer fix
- **Severity:** gap · **Status:** fixed (measured 2026-09-10)
- **Ref:** "OKI still ~8-13 dB too quiet" (table) and "Fourth pass…"
- Last `tools/audio_compare.py` figure on hardware was 0.849 (90 s,
  +2.4 dB) *before* the TLCS-90 fixes; post-fix verification had been
  YM-write activity only. Re-measured on the board with the shipped
  `Gunnail.rbf` (attract from boot, MAME `-wavwrite` 100 s vs board 110 s,
  `--offset-search 20`): **0.919 mean band corr / 0.951 envelope over
  100 s, −1.1 dB**; **0.968 / 0.997 over the first 60 s, −1.3 dB** — the
  same range as Thunder Dragon 2 on hardware (0.987). The 100 s figure
  is pulled down by NMK-7 (demo diverges after ~1 min), not by audio.

### NMK-20 · ssmissin BG "corruption": two missing driver behaviours
- **Severity:** bug · **Status:** **FIXED and confirmed on hardware
  2026-09-14**; the original "hardware-only" diagnosis was a
  misdiagnosis
- **Ref:** `/home/vboxuser/archive_e6e7074/FINDINGS.md` (superseded on
  this point), "Restoring ssmissin onto Gunnail.rbf" in
  `docs/hw-bringup.md`
- S.S. Mission's highway/field scenes rendered with dense 1-pixel
  vertical striping. This was recorded as corruption appearing **only on
  real hardware** — the reason the set was withdrawn from `master`. That
  premise was wrong: the cause was `decode_ssmissin()`, a graphics ROM
  decode the port never implemented, which affected every path equally.

**Confirmed fixed on the DE10-Nano (2026-09-14)** with the rebuilt
`Arcade-Gunnail_20260913.rbf` (md5 `536a6426…`, 0 timing violations,
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
- **Ref:** "GunNail (the "Gunnail" rbf)"
- RNG / non-cycle-exact timing; only static scenes are pixel-comparable
  on the board. Not a gameplay bug. Use `sim/rtl/video_state` (MAME RAM
  dump rendered through the video module) for pixel-exact checks of
  later scenes.

## Macross2 (tdragon2 / macross2 / powerins)

### NMK-18 · powerins is drawn with an 8 MHz pixel clock, not the board's 7 MHz
- **Cores:** Macross2 (powerins only) · **Severity:** limitation · **Status:** fixed (2026-09-11) — see "Video output at the board's pixel clock" in hw-bringup
- **Ref:** "Power Instinct on the Macross2 rbf"
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
- **Cores:** Macross2 · **Severity:** gap · **Status:** fixed (2026-09-11)
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
  unused when autofire is off. Documented as such in `Macross2.sv` and
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

## Raphero

### NMK-10 · Raphero build is at the edge of timing/utilization
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
  | Raphero | 34,179 (82 %) → 20,365 (49 %) | 46,135 → 28,694 | 520 (94 %) → 442 (80 %) | +0.296 → +0.533 ns |
  | Macross2 | 29,548 (71 %) → 15,793 (38 %) | 39,114 → 21,504 | 517 (93 %) → 439 (79 %) | +0.135 → +0.320 ns |
  | Gunnail | 27,023 (64 %) → 21,244 (51 %) | 36,924 → 25,485 | 407 (74 %) → 375 (68 %) | +0.403 → +0.535 ns |

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
- Verified now on tdragon2 (Macross2.rbf), gunnail and raphero, both
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
- **Cores:** Raphero, Macross2 (both have NMK112) · **Severity:** gap (sim-observed residual) · **Status:** fixed (2026-09-10; all three RBFs rebuilt, deployed and board-checked)
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
  (jt6295's phrase-start address load is cen4-aligned). Gunnail has no
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
- **Cores:** Macross2 (tdragon2 measured) · **Severity:** limitation (0.15% of the frame) · **Status:** closed — boot-phase software timing, not the video path (2026-09-10)
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
