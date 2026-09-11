# Known issues and areas for improvement — released cores

Tracked list for the three RBFs shipped in `releases/` (`Macross2`,
`Raphero`, `Gunnail`). One entry per issue with a stable ID; update the
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
- **Cores:** all three · **Severity:** limitation · **Status:** in progress (trims shipped 2026-09-10; baseline awaits CRT measurement)
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
  original placement is exactly `V Shift +20`. Next step is on real
  CRT equipment: find the settings that centre the picture, then fold
  them into the constants so 0 becomes the measured baseline.

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
- **Cores:** Macross2 · **Severity:** gap · **Status:** open
- `powerinspu` / `powerinspj` use a different board layout in MAME —
  `ROM_LOAD16_BYTE` sprite pairs and split BG/OKI files — so their
  `.mra` needs `<interleave>` parts whose byte order has not been
  checked against the core's parity-based word rebuild; `powerins` and
  `powerinsj` (same files, one maincpu ROM differs) ship. The bootlegs
  `powerinsa`/`powerinsb`/`powerinsc` are different sound hardware
  (`powerinsa`: no Z80; `powerinsc` not working in MAME either).

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
