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
- **Cores:** Macross2, Raphero, Gunnail · **Severity:** limitation · **Status:** open
- **Ref:** "Lines through moving sprites, and flicker"
- The core draws a whole sprite plane per frame (most of a frame's
  time); the board and MAME render per-scanline from the table copied
  at scanline 242. Moving sprites therefore sit one motion step behind
  tilemaps/HUD — the sim matches MAME on ~94.7% of pixels on
  sprite-heavy frames purely from this lag (tilemaps/HUD/text identical).
- **Fix needs:** a scanline (line-buffer) sprite renderer — a redesign,
  not a tweak. Blocked in practice by NMK-9 (Raphero has no ALM/M10K
  room for it as-is).

### NMK-2 · HSync/VSync placement is an untuned placeholder
- **Cores:** all three · **Severity:** limitation · **Status:** open
- **Ref:** "Status" (and `Macross2.sv`'s header)
- Scaler locks and reports 384x224 @ 56.2 Hz; sync *position* has never
  been tuned against a reference (real board sync timing isn't
  documented anywhere this project has sourced). Cosmetic on HDMI;
  matters more for direct/analog video users.

### NMK-3 · Residual TLCS-90 register divergence vs MAME (NMI phase)
- **Cores:** Gunnail, Raphero (shared `tlcs90.sv`) · **Severity:** gap · **Status:** open
- **Ref:** "Fourth pass: register-state tracing built, root cause found and fixed"
- After the XCF and SET/RES fixes the register-trace match against the
  MAME oracle runs 4,086+ instructions from the 14.60 s anchor, then
  stops on a port-toggle byte one NMI-firing out of phase. Assessed as
  the same benign "scheduler-arbitrary NMI timing" class already
  accepted for mustang, but not chased to a proof. Real-world YM write
  activity matches MAME within ~0.1%, so no known audible consequence.

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

## Macross2 (tdragon2 / macross2)

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

### NMK-9 · tdragon2 heavy-sprite slowdown fixed with thin margin
- **Severity:** limitation · **Status:** open (monitor)
- **Ref:** "Slowdown in play: 68000 wait states and the sprite pass"
- Board now holds 56.2 plane-swaps/s in all 45 measured windows (was
  44-50 in busy play), but MAME's own CPU is already near the frame
  budget in explosion-heavy scenes, so this is "keeps up", not
  headroom. Any added ROM-bus latency would reappear as slowdown here
  first.

## Raphero

### NMK-10 · Raphero build is at the edge of timing/utilization
- **Severity:** infra · **Status:** open
- **Ref:** "Rapid Hero / Arcadia", "OKI still…", "Flip screen option"
- ~82% ALM / 94% M10K. `SEED` has churned 7 → 19 → 23 across recent
  commits; the Flip-screen change alone pushed SEED 19 to −0.065 ns
  setup slack. Expect seed retries on any Raphero change and verify
  `Worst-case setup slack` is positive (a "successful" fitter alone is
  not a pass). Also the practical blocker for NMK-1.

## Verification gaps (works, not proven)

### NMK-11 · macross2 autofire verified via OSD only
- **Severity:** gap · **Status:** fixed (2026-09-10 — confirmed by the user in manual play on the board)
- The setting had only been seen to take hold in the OSD; no gameplay
  firing-rate capture was made for macross2 specifically (mechanism is
  tdragon2's already-proven path with the `& ~game_macross2` gate
  removed). Manual testing on the DE10-Nano confirmed autofire fires
  in macross2 gameplay, closing the gap.

### NMK-12 · New Orientation/Flip options not re-verified for settings persistence
- **Cores:** all three · **Severity:** gap · **Status:** open
- Vert 270 / Vert 90 / Flip screen were each verified by HDMI capture.
  "Save settings → reload core → option still set" was only verified
  for the original single-choice Orientation on tdragon2.

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

## Not shipped (for completeness)

### NMK-14 · `gunnailb_core.sv` (sim-only) still has the unqualified Z80 read mux
- **Severity:** bug (sim-only, no RBF) · **Status:** open
- **Ref:** "The second bug the first one exposed: the Z80 read mux"
- The three hardware cores qualify every memory select with
  `z80_mem_re`; the bootleg's core does not. Fix before any Family E
  hardware build.
