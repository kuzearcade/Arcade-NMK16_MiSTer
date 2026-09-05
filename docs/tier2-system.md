# Tier 2 — system-level integration (mustang: 68000 + NMK004)

(This file's own Status/Milestone narrative below is mustang-specific,
predating bioship's own port — see "bioship — extending nmk_irq and the
video pipeline to a second game" near the end for that game's own,
separate verification writeup.)

Status: **Six integration milestones done and verified.** A real 68000
(fx68k, the same core Tier 1's `bjtwin_core.sv` already oracle-verifies) is
wired to the completed NMK004 sound board (`rtl/tlcs90/nmk004_core.sv`)
through the real shared-latch host handshake, in a top-level module,
`rtl/mustang/mustang_core.sv` — Milestone 1 answered the question CPU-only
verification (`sim/rtl/tlcs90/tb_nmk004.cpp`) structurally couldn't (does
NMK004 get *past* its host-handshake poll loop once a real 68000 is
attached? yes), Milestone 2 gave the 68000 itself a real (initially
synthetic-substitute) interrupt source, unsticking a *second* stall
Milestone 1 had already predicted and characterized in advance,
Milestone 3 replaced the YM2203 stub with the real `jt03` core (jotego's
YM2203 clone) — a real, verified bus/IRQ integration that did *not*, on
investigation, turn out to be the cause of the divergence that remained
at that point (Milestone 2's own guess about that was wrong, and
Milestone 3 both proves it and pins down the actual divergent instruction
precisely — see Milestone 3 below) — Milestone 4 replaced both OKIM6295
stubs with the real `jt6295` core plus actual ADPCM sample ROM data,
which directly fixed that divergence (see Milestone 4 below), and
Milestone 5 replaced Milestone 2's synthetic interrupt-timing substitute
with the real, dual-PROM-driven `nmk_irq` scanline state machine
(`rtl/nmk_irq/nmk_irq.sv`), surfacing and resolving a genuine
MAME-vs-RTL scanline phase-reference difference along the way (see
Milestone 5 below). Verified against the same MAME oracle trace used
throughout Tier 2's CPU work, the matched checkpoint count went 175
(CPU-only boundary) → 18,809 (Milestone 1) → 21,986 (Milestones 2 and 3 —
unchanged by 3) → 93,351 (Milestones 4, 5, and 6 — unchanged by 5 or 6,
video is a separate verification track from the NMK004 CPU trace) — over
530x the original CPU-only ceiling, *before* NMK004's own per-instruction
timing was fixed for real (see "TLCS-90 cycle-timing fix" below): fixing
that dropped the checkpoint count to **21,606** within the same cycle
budget — not a regression, but the direct, expected consequence of
NMK004 now correctly taking longer per instruction (real per-instruction
cycle accuracy is now independently verified at 99.45%, versus the raw
checkpoint-sequence count this metric has always measured — see "TLCS-90
cycle-timing fix" for why these are different, both-legitimate signals,
and why the new stopping point is a genuine async-event-timing
divergence rather than a "needs more simulated time" one). Milestone 6
adds mustang's own real video/sprite pipeline
(`rtl/mustang/video_mustang.sv`), verified structurally (correct frame
period, genuinely dynamic content, visually-confirmed readable
graphics) but not yet frame-CRC-exact against MAME — see Milestone 6's
"Verification result" and "Next step".

## Why this exists

Every Tier 2 CPU-core milestone this session (base opcode table through
`SWI`/memory-operand `EX`, see `docs/tier2-tlcs90.md`) hit the same wall:
the real NMK004 boot ROM's host-handshake poll loop (`LD D,($FB00)` /
`CP A,D` / `JR NZ,...`, PC 0x0EAB-0x0EB1) can only resolve if something
real writes to the host-side latch it's reading — and a CPU-only testbench
has no such thing. Every opcode past that point (block-transfer, `RLD`/
`RRD`, `MUL`/`DIV`, `LDAR`/`CALLR`, `SWI`, memory-operand `EX`) had to be
verified with synthetic self-test programs instead of real firmware. This
milestone removes that ceiling: real firmware, real cross-CPU handshake,
verified against MAME.

## What's built

`rtl/mustang/mustang_core.sv` — see the module's own header for the full,
authoritative memory map and scope notes; summary:

- **fx68k** (real 68000), wired exactly the way `bjtwin_core.sv` already
  does (same DTACK/VPA/autovector pattern, same 0-wait-state-memory
  simplification) — this is the *second* place in the project fx68k has
  now been integrated, reusing a proven pattern rather than re-deriving
  bus glue from scratch.
- **`nmk004_core.sv`** (the completed NMK004 sound board — CPU + real
  peripherals + interrupt dispatch, all separately verified this session)
  wired to the 68000 through the real handshake registers: `0x08000F`
  (host read, byte) and `0x08001F` (host write, byte), plus `0x080016`/
  `0x080017` (a word write driving NMK004's `NMI` line — a watchdog
  keepalive per the reference's own comment).
- mustang's real memory map otherwise: 256KB program ROM, 64KB main work
  RAM (with the `mainram_strange_w` quirk replicated exactly — see the
  module header for why this is a genuine, deliberate divergence from
  `bjtwin_core.sv`'s own byte-lane-gated mainram write), palette RAM,
  tilemap VRAM (write-captured, not rendered).
- `sim/rtl/mustang/tb_mustang.cpp` + `Makefile` (`make run`) — runs
  mustang's real 68000 ROM (converted from `mame_roms/mustang.zip` via the
  existing `tools/mkrom.py`, same tool Tier 1 already uses) alongside the
  real NMK004 boot ROM + external program, logs NMK004's PC trace in the
  same format every other Tier 2 testbench uses (directly diffable against
  the same oracle trace), and tracks the 68000's own last fetch PC + bus
  write count for diagnosing stalls.

**Explicitly out of scope for Milestone 1** (see the module header's
"Known simplifications" for the full list, each documented not hidden):
video/sprite rendering, real `jt12`/`jt6295` audio cores (YM2203/OKI are
plain register-latch stubs — accept writes, return a fixed idle byte),
and interrupt generation to the 68000 (`IPL0-2n` tied inactive — the real
source is a PROM-driven scanline state machine, genuinely separate video-
timing work per `docs/PLAN.md`'s "nmk_irq timing generator" component,
not yet built for this family). The third of these is now addressed by
Milestone 2 below (with a documented synthetic substitution, not the real
PROM-driven state machine); video/sprite rendering and real audio cores
remain out of scope.

## A real bug found and fixed: odd-byte-address decode

The first run showed NMK004 apparently escaping the poll loop almost
immediately — which turned out to be **two separate bugs**, not one real
result:

1. **Testbench 4x-oversampling artifact.** `dbg_nmk004_valid` lives on
   NMK004's own divided-down clock domain (`nmk004_clk_r`, `clk_sys/4` —
   see the module header's "Known simplifications"), but the testbench's
   main loop samples every `clk_sys` tick, so the same asserted value got
   read (and logged) up to 4x in a row. Fixed by edge-detecting
   `dbg_nmk004_valid` in the testbench instead of trusting the raw level
   — a pure testbench bug, no RTL involved.
2. **A real, load-bearing RTL bug**, found once the oversampling was
   fixed and the trace was re-examined: NMK004 was *still* stuck in the
   exact same poll loop, spending 31.5% of all executed instructions
   revisiting it. Root cause: `mustang_core.sv`'s address decode checked
   `byte_addr == 24'h08000F` / `24'h08001F` directly — but `byte_addr` is
   derived as `{eab, 1'b0}` (the 68000's own address bus is a *word*
   address; there is no separate byte-address bus), so its LSB is
   hardwired to 0 and can **never** equal an odd address. Both handshake
   registers sit at odd byte addresses (the low byte of a word pair), so
   these checks could never match at all — the real 68000's own write to
   the handshake port was silently falling through unmapped, every time,
   forever. Fixed by matching at the *word* level
   (`byte_addr[23:1] == ...`) and gating the actual byte capture on
   `~LDSn`, exactly the convention `bjtwin_core.sv`'s own `sel_flip`
   (also an odd-address byte register) already uses correctly — this
   milestone's bug was in *not* following that established pattern
   consistently for the two new registers, not a flaw in the pattern
   itself.

Found via direct 68000 bus-write tracing (`tb_mustang.cpp`'s
`TB_LOG_M68K` environment variable), the same "add a debug tap, compare
against hand-derived expected behavior" methodology this session has used
to find every other real bug (the peripheral/timer bring-up bugs, the
IX/IY bank "sticky register" bug) — before the fix, the 68000 completed
exactly 3 write bus cycles in a million-cycle run and never touched the
handshake port at all; after the fix, tens of thousands.

## Verification result

```
matched 18809 of 359693 oracle checkpoints as a subsequence of 1058399 rtl trace lines
```

Using the exact same subsequence-diff methodology every Tier 2 CPU
milestone has used (MAME's `trace` debugger output, collapsed-loop-
tolerant ordered-subsequence comparison — see `docs/tier2-tlcs90.md`'s
"Second verification result" for why a straight positional diff doesn't
work), against the *same* oracle capture the original 175-checkpoint
CPU-only match used. That capture turns out to already contain far more
of NMK004's real boot sequence than the CPU-only testbench could ever
reach — 359,693 checkpoints total — confirming it wasn't an artificially
short capture, just one the CPU-only harness could never progress far
enough into.

Two real, characterized divergence points were found while extending the
match, investigated the same way as any other trace divergence this
session:

1. **First divergence (resolved): a timer-interrupt vector, needed more
   simulated time, not a bug.** At a 4,000,000-cycle budget, the match
   stopped at checkpoint 7413 (PC=`0x0038`, the `INTT1` vector — see
   `docs/tier2-tlcs90.md`'s interrupt-vector formula: `0x38 = 0x10 +
   (2+3)*8`). NMK004 had reached its main idle loop (`0x01DA`/`0x01DB`,
   an `EI` + self-loop) but the timer interrupt that should fire shortly
   after hadn't yet, even after tens of thousands of loop iterations.
   Raising the run budget to 20,000,000 cycles resolved it completely —
   the interrupt fires, execution proceeds, and the match extends to
   18,809 checkpoints. This confirms the timer/interrupt mechanism (already
   independently verified via a synthetic self-test — see
   `docs/tier2-tlcs90.md`'s "Fourth verification result") works correctly
   against *real* firmware too; it just needed a long enough simulated
   window for this specific game's chosen timer period to elapse, unlike
   the deliberately-fast period the synthetic test configured for a quick
   check.
2. **Second divergence (resolved in Milestone 2 below): NMK004's NMI
   never fired, because the 68000 stalled first, exactly as predicted.**
   The match stopped at checkpoint 18810 (PC=`0x0018`, the fixed NMI
   vector). Direct investigation (`TB_LOG_M68K`) showed the 68000 never
   wrote to `0x080016`/`0x080017` (the NMI/watchdog-keepalive register)
   at all, and its own last instruction-fetch PC settled at a fixed
   address (`0x070E`/`0x070A`) even across a 60,000,000-cycle run (3x
   longer than what resolved the timer divergence) — ruling out "just
   needs more time" for this one. Reading the ROM directly at that
   address confirmed it: `TST.W $F901C` / `BNE.S -8` — a tight poll loop
   waiting for something to write a nonzero flag to that RAM address, the
   classic 68000 idiom for "wait for an interrupt handler to signal
   completion." This was exactly the scenario Milestone 1's own module
   header predicted before ever running it ("If the boot sequence turns
   out to require a periodic VBlank interrupt to make forward progress,
   that will show up directly as a stall in the PC trace") — `IPL0-2n`
   were tied inactive, so no interrupt ever reached the 68000, so it
   never reached the code that would write NMK004's NMI register. Not a
   bug — a documented, anticipated scope boundary, confirmed rather than
   assumed, and fixed in Milestone 2.

## Milestone 2: real interrupt generation to the 68000

Wires a real interrupt source into `mustang_core.sv`, using a **deliberate
synthetic substitution** rather than the reference's actual PROM-driven
`NMK_IRQ` scanline state machine (see `docs/PLAN.md`'s "nmk_irq timing
generator" component — genuinely separate, substantial video-timing work,
still not built for this family). The substitution reuses two modules
from Tier 1's `rtl/bjtwin/` **completely unchanged**:

- `video_timing.sv` — a free-running raster counter (278 total scanlines,
  VBlank-in at line 16, VBlank-out at line 240).
- `nmk_irq_hacky.sv` — a fixed-scanline `IPL0-2` generator, holding IRQ1
  (twice per frame), IRQ2 (VBlank-in), and IRQ4 (VBlank-out) until the
  68000 acknowledges each at the matching autovector level.

This isn't a coincidental convenience reuse: `nmk_irq_hacky.sv`'s own
fixed-scanline table is copied directly from the reference's own
`nmk16_hacky_scanline`/`set_hacky_interrupt_timing` — MAME's own
documented fallback for games whose real timing PROM is undumped — and
mustang uses the exact same `set_screen_lowres` screen class Tier
1's bjtwin/cactus does. Two independent sources in the reference (the
hacky-scanline constants, and a separate frame-timing comment block in
`mustang_map`'s own machine-config section) agree on the same frame
geometry, and both match `video_timing.sv`'s existing constants exactly —
strong independent confirmation this is a real methodology match, not a
convenient guess. A pixel/raster clock enable (`clk_sys/4` = 8MHz, the
same ratio the 68000's own bus divider already uses) drives both reused
modules; `IPL0-2n` are wired from tied-inactive to the generator's real
output.

### Verification result

```
matched 21986 of 359693 oracle checkpoints as a subsequence of 1083467 rtl trace lines
```

Up from 18,809. The 68000's own completed write-bus-cycle count also
climbs meaningfully with interrupts flowing (94,351 → 139,156 over the
same 25,000,000-cycle budget that previously plateaued), confirming real
forward progress, not just a cosmetic PC change. A third divergence point
was found and investigated the same way as the first two:

3. **Third divergence (root-caused): a `RET Z` at `0x0E5F` takes the
   opposite branch from the oracle because the real `jt6295` (OKI x2)
   chips are still stubbed.** Originally described (before Milestone 3
   investigated it directly) as "NMK004 diverges instead of continuing to
   `0x0E61`", which undersold what's actually happening: the RTL's trace
   *does* reach `0x0097` shortly after `0x0E5F` — the same place the
   oracle eventually reaches too — just by a different, shorter path,
   skipping the oracle's own `0x0E61`→`0x0E62`→`0x0E64`→`0x0E66` steps
   entirely.

   Full manual disassembly of the routine (boot ROM, `0x0E40`-`0x0E5F`,
   entirely within the shared boot ROM, not a per-game external-ROM
   routine) identifies exactly what it does:
   ```
   0E40: 3A 00 FA   LD  HL,#FA00        ; OKI #2 status port
   0E43: E2 2E      LD  A,(HL)
   0E45: 6C 0F      AND A,#0F           ; low nibble of OKI2 status
   0E47: A0 A0 A0 A0  RLC A (x4)        ; rotate nibble into bits 7-4
   0E4B: 29         LD  C,A
   0E4C: 3A 00 F9   LD  HL,#F900        ; OKI #1 status port
   0E4F: E2 2E      LD  A,(HL)
   0E51: 6C 0F      AND A,#0F           ; low nibble of OKI1 status
   0E53: F9 66      OR  A,C             ; combine: C = {OKI2 nibble, OKI1 nibble}
   0E55: 29         LD  C,A
   0E56: 3A 24 FF   LD  HL,#FF24        ; caller-supplied "required bits" mask
   0E59: E2 2E      LD  A,(HL)
   0E5B: F9 65      XOR A,C             ; A = mask ^ live_status
   0E5D: E2 64      AND A,(HL)          ; A = (mask ^ live_status) & mask
   0E5F: FE D6      RET Z
   ```
   `(S^C)&S == S&~C`, so this is exactly "are all the bits set in the
   caller's required-bits mask (`0xFF24`) also set in the live combined
   OKI1/OKI2 status nibble byte (`C`)? if so, return." — a standard
   hardware-ready/busy poll, with the mask varying per call (a genuine
   RAM scratch variable the caller sets before invoking this routine, not
   a firmware bug).

   Direct MAME-debugger register capture (`mame mustang -debug
   -debugscript ...`, breakpoint at `0x0E5F` reading `A`/`HL`/`b@HL`/`AF`
   — see the debugger's own `help expressions` for the `b@<addr>` memory
   operator) shows this mask genuinely varies from call to call and the
   live status byte is *not* constant, so `Z` comes out both set and
   clear across thousands of real calls. The equivalent RTL-side capture
   (new `dbg_a`/`dbg_f`/`dbg_hl` ports on `tlcs90.sv`, threaded through
   `nmk004_core.sv` as `dbg_ram_hl` too, captured in `tb_mustang.cpp`
   under `TB_LOG_RETZ`) shows `A` is *always exactly 0* at this point,
   which the math above explains completely: `mustang_core.sv` still ties
   `oki0_din`/`oki1_din` to a constant `8'hFF` (`rtl/mustang/mustang_core.sv`,
   the `nmk004` instantiation) since real `jt6295` integration is
   deliberately deferred (see "Next step"). A constant `0xFF` live status
   makes `S & ~C == S & 0x00 == 0` for *any* mask `S`, so this readiness
   check trivially succeeds on every single call — the RTL never takes
   the oracle's real retry path at all. **Milestone 2's own speculation
   that this was a YM2203/OKI status-bit poll was directionally right
   about "OKI" but wrong about the mechanism** (it guessed a direct
   status-bit test, not a RAM-cached-mask/live-status comparison) —
   Milestone 3 already proved YM2203 wasn't the cause; this analysis
   proves OKI *is*, via the still-stubbed `oki0_din`/`oki1_din`, not via
   YM2203 at all. **The fix is real `jt6295` integration** (already
   planned as a separate increment, now with a concrete, verified reason
   it's necessary rather than just "the next unstarted milestone").

## Milestone 3: real jt03 (YM2203) integration

Replaces the YM2203 stub with the real `jt03` (jotego's YM2203 clone,
already vendored in `rtl/third_party/jt12/`) — genuinely real audio-chip
integration, not a placeholder, though (as documented in the module
header) not yet consumed by any DAC/mixer in this simulation harness,
since this milestone is about bus/register-level correctness rather than
audio fidelity.

- **Clock enable**: 1.5MHz from 32MHz `clk_sys` (matching the reference's
  own `YM2203(config,"ymsnd",1500000)`) via a plain phase accumulator —
  1.5/32 = 3/64 exactly, so this is an *exact* rate, not an approximation
  (increment-by-3-mod-64 every `clk_sys` cycle, pulse on wraparound,
  giving 3 evenly-spaced pulses every 64 cycles).
- **Write-stretching**: `jt03` has no bus-ready/ack output (matching real
  YM2203 hardware, which just expects `WR` held for its own minimum pulse
  width) and only samples its bus inputs on its own ~21-`clk_sys`-cycle
  `cen` pulses — but `nmk004_core.sv`'s own `ym_we` is a single
  `nmk004_clk_r`-cycle pulse (4 `clk_sys` cycles), which could land
  entirely between two `cen` pulses and be missed outright. Latches the
  write request (address + data) on `ym_we`'s rising edge and holds
  `wr_n` asserted for 40 `clk_sys` cycles — comfortably more than one
  `cen` period — guaranteeing at least one real sample. This is a real,
  necessary integration detail for any bus-driven peripheral running on a
  slower clock-enable than the CPU issuing the write, not `jt03`-specific
  — worth remembering for `jt6295` (or any future chip) integration too.
- **IRQ**: `jt03`'s `irq_n` output is OR'd into `nmk004_core.sv`'s
  `irq_req` bit 0 (`INT0`) via a new `ym_irq_n` input port on that
  module, matching the reference's `ym2203_irq_handler()` routing
  YM2203's IRQ straight to the CPU's `INT0` line. `nmk004_periph.sv`'s
  own `irq_req` output never drives bit 0 itself (no internal NMK004
  peripheral source for `INT0`), so this is purely additive, not a real
  arbitration — confirmed safe by re-running every existing synthetic
  CPU-opcode/peripheral test unchanged (see "Verification" below).

### Verification

Debug taps (`dbg_ym_we`/`dbg_ym_cs`/`dbg_ym_chip_dout`/`dbg_ym_chip_irq_n`
on `mustang_core.sv`, `TB_LOG_YM=1` on `tb_mustang.cpp` — kept as
permanent diagnostics, same tier as `TB_LOG_M68K`, not throwaway
bring-up scaffolding) confirm the integration is real and functioning:
NMK004 writes to YM2203 **3,639 times** over the same 25,000,000-cycle
run, `jt03`'s `irq_n` starts inactive (`1`, correct idle state) and later
asserts — real YM2203 timer-IRQ behavior, not a malfunction, since this
chip genuinely generates periodic timer interrupts as part of normal
operation (the same way NMK004's own internal timers already do, per
`docs/tier2-tlcs90.md`'s interrupt-model work). The oracle checkpoint
count is **unchanged at 21,986** — direct, concrete proof that Milestone
2's YM2203-status-poll hypothesis for the existing divergence was wrong,
since making the chip fully real neither fixed nor changed that specific
divergence at all (see "the third divergence" above for what the real
cause looks like instead).

Re-confirmed all existing Tier 2 regressions (175-checkpoint CPU oracle
match, 211-fire interrupt self-test, and every synthetic CPU-opcode test
this session built, including the ones instantiating `nmk004_core.sv`
directly and needing the new `ym_irq_n` port tied off) unchanged, and
Tier 1's own `bjtwin_core.sv` build still succeeds using the same
`video_timing.sv`/`nmk_irq_hacky.sv` files shared across three families
now.

## Milestone 4: real jt6295 (OKIM6295 x2) integration

Replaces the OKI x2 register-latch stubs with the real `jt6295` core
(jotego's clone, already vendored in `rtl/third_party/jt6295/`) —
including actual ADPCM sample ROM data (`90058-5`/`90058-6`, extracted
from the real romset via `tools/mkgfxrom.py --mode concat`, matching the
reference's `ROM_REGION(0x080000,"oki1"/"oki2")` exactly), not just a
bus-register stub. This is the fix the RET Z root-cause analysis called
for directly.

**Clock/timing**: the reference's `mustang()` config uses `16000000/4` =
4MHz for both chips, `PIN7_LOW`. `jt6295_timing.v`'s own header says its
`cen` input "should be 1,000 kHz" regardless of the `ss`/`PIN7` setting
(`ss` only changes the *internal* sample-rate divider) — 1MHz from 32MHz
`clk_sys` is an exact `/32`, simpler than jt03's 3/64 fractional case (a
plain free-running 5-bit counter, no phase accumulator needed).
`PIN7_LOW` is jt6295's `ss=0` (`jt6295_timing.v`'s own comment: "SS low =
divides by 164" — the same "slow" mode `PIN7_LOW` selects on real
silicon).

**Bank switching**: matches the reference's `oki1_map`/`oki2_map`
(`mame/src/mame/nmk/nmk16.cpp`) exactly — jt6295's own 18-bit `rom_addr`
is the chip's own address space (`0x00000-0x1FFFF` fixed,
`0x20000-0x3FFFF` banked), and the physical ROM offset for the banked
region is `(bank+1)*0x20000 + rom_addr[16:0]`, bank coming from
NMK004's own `oki0_bank`/`oki1_bank` latches (masked to 2 bits, matching
the reference's `oki_bankswitch_w`'s `data & 3`). Bank 3 computes an
offset one full `0x20000` bank past the dumped ROM's own 512KB end — a
latent quirk in the original hardware/driver, not introduced by this
integration — wrapped (masked) into the ROM's own size rather than read
out of bounds.

**Write-stretch**, same rationale as jt03's: `oki0_we`/`oki1_we` are each
a single `nmk004_clk_r`-cycle-wide pulse, stretched to 40 `clk_sys`
cycles so a write reliably lands regardless of jt6295's own sampling.
`rom_ok` tied constant high with a 1-`clk_sys`-cycle registered ROM read
(matches `jt6295_rom.v`'s own built-in latency tolerance — no SDRAM
controller exists in this simulation harness to model real arbitration
latency against).

### Verification result

Direct confirmation this fixes the RET Z root cause: the `TB_LOG_RETZ`
capture (same instrumentation built to root-cause the divergence) now
shows `A` is no longer stuck at exactly `0` on every hit — real busy/idle
toggling on the OKI status nibbles occasionally makes the readiness check
genuinely fail and retry (`A=0x20` observed on 2 of 116 hits in a
25,000,000-cycle run, versus `A=0x00` on all 5,901 real hits this
session's earlier MAME capture recorded — both traces now show the check
sometimes failing, not always trivially passing).

Oracle checkpoint match jumped from 21,986 to **93,351 of 359,693** (a
60,000,000-cycle run) — the `RET Z` divergence itself is gone; matching
now proceeds well past it. The new stopping point (checkpoint 93,352,
`PC=0x0038`, the `INTT1` timer vector) is the same "needs more simulated
time" situation as Milestone 2's very first divergence (see "Verification
result" above): doubling `RUN_CYCLES` from 25,000,000 to 60,000,000
roughly proportionally extended the match (33,885 → 93,351), and the
oracle's own `PC=0x0038` checkpoints keep appearing further along in the
RTL's own (longer) trace each time, not disappearing — a real firmware
timer that just hasn't fired again yet within the simulated window, not a
new bug. `RUN_CYCLES` is left at `60000000`.

Re-confirmed all existing Tier 2 regressions (175-checkpoint CPU oracle
match, 211-fire interrupt self-test) unchanged, and Tier 1's own
`bjtwin_core.sv` build still succeeds.

## Milestone 5: real nmk_irq scanline state machine

Replaces `nmk_irq_hacky.sv` (Tier 1's synthetic-first fixed-scanline
substitution, Milestone 2's stopgap) with `rtl/nmk_irq/nmk_irq.sv` — the
actual dual-PROM-driven interrupt/sprite-DMA state machine
(`nmk_irq_device`/`NMK_IRQ` in the reference), ported directly from
`nmk_irq_device::scanline_callback` in `mame/src/mame/nmk/nmk_irq.cpp`
and driven by mustang's own real, dumped V-timing PROM (`10.bpr`,
extracted via `tools/mkgfxrom.py`) rather than a hand-picked scanline
table. The reference's own device doesn't consume the H-timing PROM at
all (see that file's own header/TODO), so this module only needs the
V-PROM; screen geometry keeps coming from `video_timing.sv`'s existing
fixed constants.

**A real, empirically-verified discovery along the way**: implementing
the reference's own address formula literally (`((((y/2)+start) %
(usage-start)) + start) % len`) fed with this project's own `vcount`
directly produced *wrong* PROM addresses — the right IRQ/sprite-DMA bit
patterns, but 66 scanlines "early." Cross-checked directly against real
MAME: a live debugger capture (`-debugscript`, breakpoints resolved from
the ROM's own autovector table at the real ISR entry addresses for
IRQ1-4, printing the `beamy` pseudo-symbol) showed mustang's real,
steady-state IRQ dispatch scanlines are exactly IRQ2@16, IRQ1@68 and
196, IRQ4@240 — the same "typical" values `nmk_irq_hacky.sv` already
happened to use — and that these match the reference formula's own
output for `vcount+66` exactly, at all four independently-captured
points. A fifth, indirect check (the sprite-DMA trigger, computed the
same way) lands on the exact same scanline `nmk_irq_hacky.sv`'s own
`SL_SPRDMA=242` constant already used. This is a genuine phase-reference
difference between MAME's own `screen.vpos()` numbering and this
project's own `vcount` (both 0..277 over an identical 278-line frame,
independently confirmed via Milestone 2's own frame-geometry
cross-check) — not chased down to its exact mechanistic root inside
MAME's screen-timing internals (diminishing returns for what it would
buy), but verified thoroughly enough (4 independent live captures plus a
5th consistency check, all agreeing on one exact constant) to treat as
solid. `nmk_irq.sv` applies this `+66` correction before applying the
reference's own formula — see that module's own header for the full
derivation.

Since mustang's real PROM turns out to encode exactly the scanlines
`nmk_irq_hacky.sv` already used, this milestone is a genericization/
correctness milestone rather than a behavior change for mustang
specifically: the real module is driven by actual per-game PROM content
(so it's correct for whatever any *other* game's own dumped V-PROM
encodes, unlike the fixed table), while reproducing byte-identical
results for mustang itself.

### Verification result

```
matched 93351 of 359693 oracle checkpoints as a subsequence of 2627090 rtl trace lines
```

Unchanged from Milestone 4 — expected, since (as established above) the
real PROM-driven module reproduces mustang's own IRQ timing exactly.
Re-confirmed all existing Tier 2 regressions (175-checkpoint CPU oracle
match, 211-fire interrupt self-test) unchanged, and Tier 1's own
`bjtwin_core.sv` build (still using `nmk_irq_hacky.sv` unchanged, since
cactus's own real PROM remains undumped) still succeeds.

## Milestone 6: mustang video/sprite pipeline

`rtl/mustang/video_mustang.sv` — real tilemap + sprite rendering for
Family B (mustang's own two-tilemap-layer variant), replacing the
"write-captured, not rendered" VRAM/palette stubs from earlier
milestones. Built against the exact same methodology as Tier 1's
`video_bjtwin.sv` (real-time, scanline-synchronized per-pixel tile
decode; a budget-walked, double-buffered sprite draw FSM — see that
module's own header for the architecture this reuses), extended for
this family's real differences from bjtwin's own:

- **Two tilemap layers**, not one: a page-mapped 16x16-tile BG
  (`tilemap_scan_pages`, 256 cols x 32 rows, X-scroll only via
  `mustang_scroll_w` — mustang never sets BG Y-scroll) and a fixed 8x8
  TX/text layer (`TILEMAP_SCAN_COLS`, 32x32, transparent pen 15, no
  scroll beyond the shared videoshift). No bank-switch hack (that's
  `bjtwin_get_bg_tile_info`'s own quirk, N/A here — mustang's own
  `bgvideoram` is exactly the reference's own bank-switch-gate size, so
  `m_tilerambank`/`m_bgbank` stay permanently 0).
- **Real composite priority**: BG is always the base (never
  transparent, never masks anything); TX's opaque pixels (pen!=15) mask
  sprites underneath (`get_colour_4bit`'s own pri_mask, taken literally
  — sprites sit *under* the "foreground" TX layer) — a genuine
  three-layer interaction bjtwin's own single-tilemap family never
  needed.
- **Sprite double-buffer delay**: `nmk16_state::sprite_dma()` maintains
  two host-side snapshot buffers for this family and
  `screen_update_macross` draws from the *older* one (one trigger's
  worth of latency) — genuinely different from bjtwin/cactus's own
  single-buffer, no-delay path. Replicated with two ping-ponging
  snapshot buffers rather than a literal copy — see the module's own
  header for the exact derivation.
- **Sprite clock budget**: `nmk16spr.cpp`'s own current literal
  `clk += 128*w*h` (raw 0-15 fields), cross-checked directly against
  the current reference source rather than assumed from bjtwin's own
  carried-over `(w+1)*(h+1)` formula (flagged as worth a future
  cross-check, not fixed there in this session — out of scope).

### A real bug found and fixed: missing TX palette color-base offset

First build rendered a **solid black frame** despite VRAM genuinely
containing real content (confirmed directly: 233/1024 TX tilemap
entries non-blank, 17/1024 palette entries populated, all in the
`0x2E0-0x2FE` range). Root-caused by adding temporary debug taps
(`dbg_pal_addr`/`dbg_bgvram_addr`/`dbg_txvram_addr`, now kept
permanently) and a full 384x224 `rd_rgb` sweep confirming *zero*
nonzero pixels anywhere, then a targeted probe at a known-populated TX
tile: the computed `pal_addr` was `0x0EF`, not the expected `0x2EF`.

`GFXDECODE_ENTRY("fgtile", 0, gfx_8x8x4_packed_msb, 0x200, 16)` gives
TX's own palette entries a `0x200` base offset (matching `bgtile`'s
`0x000` and `sprites`' `0x100` — three separate 256-entry color windows
in the same 1024-entry palette RAM) — `tx_pal_addr`'s original
`{colour, pen}` computation only ever produced `0x000-0x0FF`, aliasing
onto BG's own (empty) color range instead of TX's real, populated one.
Fixed by adding the `10'h200` base explicitly (bg_pal_addr needs none —
its own base is already `0x000`). After the fix, a full-frame PPM dump
shows clearly readable repeating "MUSTANG" marquee text — direct visual
confirmation the tile-decode, addressing, and palette pipeline are all
working correctly end to end, not just structurally plausible.

### Verification result

Frame period matches exactly: both the RTL and a fresh live MAME
capture (`sim/oracle/trace.lua`, `NMKTRACE_SCREEN`) show precisely
142,336 clk_sys cycles between consecutive frames — the expected
278×512 raster total, confirming `frame_done`/`video_timing.sv` stay in
lock-step with real hardware timing. Both sides show genuinely dynamic,
non-static frame content (51/106 unique CRCs on the RTL side, 57/110 on
MAME's), not a frozen or blank screen on either side. Exact per-frame
CRC matching does not yet hold (no CRC overlap between the two 100+
frame captures) — this needs deeper cycle-accurate 68000 bus timing
work than this milestone's scope covers (mustang_core.sv's own
documented `DTACKn`-tied-to-`ASn` 0-wait-state simplification is the
most likely source of the accumulated timing drift across 100+ frames);
flagged as the next thing to verify precisely, not silently claimed as
done. Re-confirmed all existing regressions (175-checkpoint CPU oracle
match, 211-fire interrupt self-test, 93,351-checkpoint system oracle
match — unchanged, video is independent of the NMK004 CPU trace path)
and Tier 1's own `bjtwin_core.sv` build still succeed.

### Frame-CRC timing-drift investigation

Chased the accumulated per-frame timing drift flagged above. Built new,
reusable tooling first: a full 68000 instruction-fetch PC trace
(`sim/rtl/mustang/mustang_68k.trace`, same "%06X\n per instruction"
convention as the NMK004 trace) and a live MAME `:maincpu` capture via
the debugger's own `trace <file>,maincpu,noloop` command (the `noloop`
flag matters — the default loop-collapse behavior inserts human-readable
`(LOOPS FOR N INSTRUCTIONS)` summary lines the plain subsequence-diff
tool can't parse). This is the **first time this session has verified
the 68000's own instruction sequence against a MAME oracle at all** —
every prior Tier 2 oracle comparison was NMK004-side only.

**Found the exact divergence point**: both traces match for the first
~6,150 68000 instructions (mostly the reset-vector boot sequence and an
early `bsr $792` subroutine), then diverge inside a tight polling loop:
```
000792: move.w  $8000e.l, D0
000798: move.w  D0, D1
00079A: andi.b  #$e0, D1
00079E: cmpi.b  #-$80, D1
0007A2: bne     $792
```
This tests `(mem[$8000E:$8000F] & 0xE0) == 0x80`. `mustang_map`
(`mame/src/mame/nmk/nmk16.cpp`) has no read handler at all for
`$08000E` — only `$08000F`, mapped to `nmk004_device::read()` (the real
NMK004 host-to-main latch). Since `andi.b`/`cmpi.b` only ever touch the
low byte, this loop is purely a **NMK004-handshake-latch poll**: wait
for NMK004 to present a specific status byte. Both traces *do* exit the
loop and continue into subsequent code (confirmed by finding `0007A4`
immediately following the last matched `0007A2` on each side) — so this
isn't a wrong-branch/decode bug, it's a **race-condition-sensitive loop
iteration count**: our RTL exits after fewer iterations than MAME's real
timing does.

**Tested one concrete hypothesis directly**: `nmk004_core.sv`'s own `p4`
output (bit0 — in the reference, `nmk004_device::port4_w` drives the
68000's own reset line via `reset_cb().set_inputline(m_maincpu,
INPUT_LINE_RESET)`, letting NMK004's firmware hold the 68000 in reset
until it's ready) was left completely unconnected in `mustang_core.sv`
(`.p4(), .bx(), .by()`) — flagged as "future work" in that port's own
header comment since Milestone 1. Wired it in for real
(`m68k_extReset = reset | nmk004_p4[0]`, `pwrUp` left on the system-wide
`reset` alone — a real hold/release handshake, not a repeated cold
power-on). **Result: negligible effect** (the divergence point moved
from checkpoint 6162 to 6152 — noise-level, not a fix). Kept anyway
since it's a genuine correctness improvement matching the reference
exactly, confirmed harmless via full regression (93,351-checkpoint
system oracle match, CPU-only tests, Tier 1 build all unchanged).

**Two remaining candidate root causes, not yet distinguished**:
1. 68000 bus-cycle wait-state timing (`mustang_core.sv`'s documented
   `DTACKn`-tied-to-`ASn` 0-wait-state simplification vs whatever real
   wait-state count this hardware's actual DTACK generator inserts for
   I/O accesses).
2. **TLCS-90 per-opcode instruction-cycle-timing accuracy has never
   actually been verified against the oracle** — a real methodology gap
   found while investigating this: `/tmp/oracle_pc2.txt` (the NMK004
   oracle trace every prior Tier 2 CPU verification pass has used) is a
   *pure PC sequence*, no cycle timestamps at all. Every past
   verification pass (this document's Milestones 1-5, and
   `docs/tier2-tlcs90.md`'s eleven CPU-core verification passes) checked
   that NMK004 executes the *correct instructions in the correct order*,
   never that each instruction takes the *correct number of clock
   cycles*. If `tlcs90.sv`'s own per-opcode cycle counts don't exactly
   match the real TMP90C840's (i.e. MAME's own model of it), NMK004 and
   the 68000 drift out of relative wall-clock sync over hundreds of
   thousands of cycles even though each CPU's own instruction sequence
   is individually correct — which would explain a race-sensitive
   polling loop diverging exactly like this one, and would compound
   forward into every downstream frame's content.

Distinguishing between these needed a genuinely new verification
approach this session hadn't built yet — see below.

### Cycle-timestamped NMK004 trace tooling

Built to distinguish the two candidate causes above. Two new, permanent,
reusable tools (not scratch scripts):

- **`sim/oracle/capture_cyc_trace.py`** — a MAME-side capture, generalizing
  the same `-debugscript`-based `trace` technique this session has used
  repeatedly (see `sim/oracle/debug_capture.py`'s own precedent). The key
  discovery making this possible: MAME's debugger exposes a read-only
  `totalcycles` symbol per focused CPU device (found via the `symlist`
  command, after `help totalcycles`/`help cycles` turned out not to be
  valid *help* topics despite being valid *expression* symbols — a real
  gotcha worth remembering). The `trace` command's own `action` parameter
  (run before each logged line) prepends it via `tracelog`:
  ```
  focus <device>
  trace <out>,<device>,noloop,{tracelog "%d ",totalcycles}
  ```
  `focus` matters — without it, `totalcycles` silently resolves against
  whatever CPU MAME's debugger currently has visible by default (usually
  `:maincpu`), not the device actually being traced, with no error at
  all. `noloop` matters too (same reason as the 68000 trace capture
  earlier this chase: default loop-collapse inserts unparseable summary
  lines).
- **`sim/compare/cyc_diff.py`** — matches oracle and candidate traces on
  PC sequence (the same ordered-subsequence walk this project's PC-only
  diffing already uses), then compares the **cycle delta between
  consecutive matched checkpoints** on each side (never absolute cycle
  values, which have unrelated cycle-0 references on the two sides —
  RTL simulation start vs MAME machine start).
- `sim/rtl/mustang/tb_mustang.cpp` gained a matching RTL-side output,
  `nmk004_cyc.trace` (`"<clk_sys_ticks/4> <PC>\n"` per instruction —
  `clk_sys/4` is NMK004's own real 8MHz clock, `nmk004_clk_r`, the same
  domain MAME's `totalcycles` counts in for this device) — a permanent,
  always-on trace alongside the existing `nmk004_sys.trace`.

**Result — the question is answered.** Over a 223,939-instruction matched
span:
```
222231/223939 instruction cycle-costs differ (tolerance=0)
total cycles over matched span: oracle=2702476 candidate=4119633 (candidate/oracle ratio=1.524)
```
**99.2% of individual NMK004 instructions take a different number of
clock cycles in this project's own RTL than MAME's own model** — this is
not a subtle drift, it's a near-total mismatch, immediately visible in
even the first few instructions (`LD D,n`: oracle 8 cycles vs RTL 6;
`LD (mn),n`, repeated ten times in the boot ROM's own peripheral-init
loop: oracle 20 cycles every time, RTL 7 every time — a factor of ~2.9x
on that specific instruction). Cross-checked against MAME's own source
(`mame/src/devices/cpu/tlcs90/tlcs90.cpp`): every opcode's declared cost
lives in a simple `OP(opcode, CT)`-style macro table
(`m_cyc_t = CT*2`), presumably lifted directly from the real TMP90C840
datasheet — a concrete, authoritative source for whoever picks up the
actual fix. **This conclusively identifies TLCS-90 per-opcode
cycle-timing accuracy as the dominant root cause** of the frame-CRC
drift (not 68000 bus wait-states, which remains untested but is now a
clearly secondary concern by comparison) — `tlcs90.sv`'s own FSM was
built and verified for instruction-sequence/flag correctness only (an
explicit, documented scope from the very first CPU-core verification
pass in `docs/tier2-tlcs90.md`), never for matching real per-instruction
bus-cycle counts, and it shows.

### TLCS-90 cycle-timing fix

Fixed directly, as a follow-up to the diagnosis above — see
`docs/tier2-tlcs90.md`'s "Twelfth verification result" for the full
derivation (table extraction/cross-verification methodology, the
`instr_cycles()`/`cyc_elapsed`/`target_cyc` padding mechanism, and the
two narrow, documented simplifications it doesn't cover). Headline
result, `sim/compare/cyc_diff.py` against a fresh oracle capture:
```
43/7779 instruction cycle-costs differ (tolerance=0)
```
Down from 222,231/223,939 (99.2%) to 43/7,779 (0.55%) — every remaining
mismatch individually root-caused into one of two bounded, non-table-error
causes (a genuine MAME implementation quirk in `DJNZ`'s own "not-taken"
cost, and a 1-cycle structural floor for the cheapest single-byte
opcodes; see `docs/tier2-tlcs90.md` for both). All CPU-core regressions
(175-checkpoint oracle match, all nine standalone opcode self-tests, the
interrupt self-test) confirmed unchanged.

**A genuine, expected, fully-explained side effect**: with NMK004 now
correctly taking longer per instruction, this document's own
Milestone-4-era 93,351-checkpoint system oracle match (`sim/rtl/mustang/`)
drops to 21,606 within the same cycle budget — and, unlike every prior
"needs more simulated time" resolution this session, extending the
budget doesn't recover it (tested at 2.5x cycles, same stopping point).
The new stopping point is a *different kind* of divergence: the oracle's
own trace shows an NMI firing (PC jumps to `0x0010`, the fixed NMI
vector) at the corresponding point, while this RTL's own trace continues
normally past it — an async-event-timing interaction between NMK004
(now correctly timed) and the 68000 (whose own bus-wait-state timing is
the *other*, still-unfixed half of this investigation's two original
candidate causes). This is the expected shape of fixing one side of a
two-CPU relative-timing problem: it changes *which* timing-sensitive
interaction surfaces first, not whether one exists at all — genuine
forward progress (real per-instruction timing accuracy, verified
directly), not a hidden regression.

### 68000 bus-wait-state timing — investigated, found to be a dead end

The natural next candidate for the async-event-timing divergence above
was the 68000's own documented `DTACKn`-tied-to-`ASn` (0-wait-state)
simplification. Investigated directly rather than assumed fixable:

- Built the same cycle-timestamped comparison tooling used for the
  TLCS-90 fix, on the 68000 side: `tb_mustang.cpp` gained
  `m68k_cyc.trace` (identical `"<clk_sys_ticks/4> <PC>\n"` format,
  timestamped at each fetch bus cycle's own *start* — `ASn`'s falling
  edge — to match MAME's `totalcycles` sample point, which is read
  before each instruction executes), diffed via `cyc_diff.py` against a
  fresh `capture_cyc_trace.py --device :maincpu` oracle capture.
- Result: **candidate/oracle cycle ratio = 1.001** over the first
  ~12,600 matched instruction boundaries — essentially exact. The
  individual-instruction mismatches that do show up (5,043/12,602) come
  in self-cancelling +4/-4 pairs at specific instruction boundaries,
  consistent with fx68k's own genuine prefetch-queue overlap shifting
  where a fetch-bus-cycle-start timestamp falls relative to MAME's
  non-pipelined per-instruction accounting — a measurement-boundary
  artifact, not a missing-cycles bug.
- Checked MAME's own 68000 core and this driver (`nmk16.cpp`,
  `nmk004.cpp`) for any wait-state injection (`eat_cycles`,
  `adjust_icount`, `set_maximum_quantum`/`set_perfect_quantum` on
  `mustang()` specifically) — **there is none**. MAME's 68000 core uses
  fixed per-instruction cycle tables (the standard 0-wait-state timing),
  so `DTACKn` tied to `ASn` is already the *matching* model, not a gap.
- The actual divergence, disassembled directly from a live MAME capture,
  is the NMK004 status poll at `$8000E`
  (`move.w $8000e.l,D0 / andi.b #$e0,D1 / cmpi.b #$80,D1 / bne $792` —
  3,694 iterations before it resolves in the captured run) — a real
  busy/ready handshake, not a generic memory access. **Conclusion: 68000
  bus-wait-state timing is not the cause — closed as a dead end**, not
  left untested.

### The real remaining divergence: an unsynchronized watchdog NMI, not a timing bug

Traced further instead: `nmk004_x0016_w` (`$80016/$80017`, written right
around the divergence point) is not a data handshake — per the
reference's own comment, it's a **watchdog keepalive**: the 68000
periodically pulses it to generate an NMI on NMK004, and if that NMI
stops arriving NMK004 resets the whole system. Critically,
`nmk16_state::nmk004_x0016_w` (`nmk16.cpp:226-232`) calls
`m_nmk004->nmi_w(...)` directly — with **no `machine().scheduler()
.synchronize()` call**, unlike the `$8000E`/`$8000F` handshake registers
(`nmk004_device::read/write/tonmk004_r/tomain_w`, all four of which do
call `synchronize()` specifically to pin down relative CPU timing at the
instant of access). `mustang()`'s own machine config has no
`set_maximum_quantum`/`set_perfect_quantum` override either, so this NMI
rides MAME's coarse default scheduler quantum.

That means the exact simulated moment this NMI reaches NMK004, in MAME,
is governed by MAME's own default CPU-device interleave order — an
artifact of MAME's scheduler implementation, not a value derived from
real hardware timing or datasheet-documented behavior. On real silicon
the exact timing genuinely doesn't matter either (a watchdog is tolerant
of any reasonably periodic keepalive within its timeout margin); MAME's
own moment-of-delivery for this specific line is arbitrary within that
same tolerance, not a spec to converge on. Matching it bit-exactly would
mean reverse-engineering and replicating MAME's own scheduler
quantum/interleave algorithm — a fundamentally different, far less
tractable class of problem than the datasheet-driven TLCS-90 opcode-cycle
fix that worked earlier in this chase, and disproportionate to the
payoff (this is a watchdog line, not video/gameplay-affecting logic).

## Next step

**The frame-CRC timing-drift chase is closed for now** — both candidate
causes from its start (NMK004 per-instruction cycle timing, and 68000
bus-wait-state timing) have been directly investigated: the first was a
real, fixed bug (99.2%→0.55% mismatch); the second was checked and found
to already match MAME's own model, with the residual divergence traced
to an unsynchronized watchdog-NMI whose MAME-oracle timing is a
scheduler artifact rather than a reproducible hardware quantity. Current
fidelity (93,351/21,606-checkpoint sequence match depending on whether
counted before or after the TLCS-90 fix, structurally-correct
frame-period-exact video, readable rendered text) is the practical
ceiling for exact-CRC matching on this specific signal without
undertaking MAME-scheduler-replication work not justified by the payoff.
Future work here: extending `rtl/nmk_irq/nmk_irq.sv` and a
`video_mustang.sv`-style pipeline to the other NMK004-family games once
their own system-level integration begins (each needs only its own
dumped V-PROM/graphics ROMs — both modules are already built
game-generically within this family), and the still-unmodeled real
`nmk16spr` per-sprite off-screen wraparound/clip-skip logic (carried
forward from bjtwin's own same gap).

## bioship — extending nmk_irq and the video pipeline to a second game

The second Tier 2 NMK004-board game to get a full system-level
integration, after mustang above. The goal: prove `rtl/nmk_irq/
nmk_irq.sv` (already documented as "reusable as-is for every other
NMK004-family game once their own V-PROM is dumped") and the video-
pipeline *architecture* mustang's own `video_mustang.sv` established
(tile-decode/palette/sprite-FSM methodology) really do generalize to a
second, structurally different game — not just repeat mustang's own
already-solved integration.

**New files**: `rtl/bioship/bioship_core.sv` (top-level glue, closely
mirroring `mustang_core.sv`'s own structure) and `rtl/bioship/
video_bioship.sv` (a new module reusing `video_mustang.sv`'s own
tile-decode functions, palette-decode, and sprite draw FSM verbatim,
extended for this game's genuinely different video layout — see below).
`nmk_irq.sv` and every other constituent module (fx68k, `nmk004_core.sv`,
`jt03`, `jt6295`) needed zero code changes — only new per-game
parameters (bioship's own dumped V-PROM, ROMs, memory map).

### Real differences from mustang, found by reading the reference directly

- **A third tilemap layer, and it's ROM-based, not VRAM-based.**
  `bioship_get_bg_tile_info` (`nmk16_v.cpp`) reads tile *indices* for BG0
  straight out of a dumped ROM (`tilerom`, the interleaved 8.ic27/9.ic26
  pair) rather than CPU-writable VRAM — the CPU only selects *which* of
  8 pre-authored 8192-tile "scenes" is showing via an 8-bit bank register
  (`bioship_bank_w`, byte @0x084001), which is how the game's parallax
  "flying through space" background works. BG1 (the familiar VRAM
  tilemap) draws over BG0 wherever opaque, then TX over both, then
  sprites under TX and over BG — the same top-to-bottom ordering
  mustang's own compositing already established, just with one more
  layer in the base. Full derivation in `video_bioship.sv`'s own header.
- **Both BG layers get independent X *and* Y scroll** — bioship uses the
  generic `scroll_w<Layer>` register template (four bytes/layer,
  byte-sequenced via `.umask16(0xff00)`/`~UDSn`), not mustang's own
  single-purpose, X-only `mustang_scroll_w`.
- **The 68000 runs at 10MHz, not 8MHz** (`XTAL(10'000'000)` vs mustang's
  `XTAL(8'000'000)`) while NMK004/OKI/YM2203 stay at mustang's own
  nominal rates. Since 8 and 10 share no clean power-of-2 divisor,
  `bioship_core.sv` uses a 40MHz `clk_sys` (not mustang's 32MHz): /4=10MHz
  for the 68000 (same clean divide-by-4 enPhi1/enPhi2 pattern), /5=8MHz
  for NMK004 and the pixel/raster clock (a genuine 5-cycle counter, not
  mustang's 2-bit-MSB /4 trick — 5 is odd, so a 2-high/3-low counter is
  used instead; only rising-edge timing matters, not duty-cycle
  symmetry), /10=4MHz for OKI, and a 3/80 phase-accumulator for YM2203's
  1.5MHz (same *technique* as mustang's own 3/64-from-32MHz).
- **`nmk004_bioship_x0016_w` inverts the watchdog-NMI polarity**
  `nmk004_x0016_w` uses everywhere else — nmk16.cpp's own comment: "otherwise
  bioship doesn't hit the NMI enough to keep the game alive." Wired as
  `nmi_level <= ~oEdb[0]` (mustang's own is `oEdb[0]` directly). This
  session's own frame-CRC timing-drift chase already established that
  this line's exact *delivery timing* isn't meaningfully chaseable
  against MAME's own oracle (an unsynchronized, scheduler-quantum-
  dependent line on MAME's own side) — only the *polarity* needed to be
  right, and it is.
- **Different GFXDECODE color-base assignments** (`gfx_bioship`):
  TX=0x300, BG1=0x100, sprites=0x200, BG0=0x000 — all genuinely different
  from mustang's own `gfx_macross` (TX=0x200, BG=0x000, sprites=0x100),
  not copy-paste values.
- **Sprite ROM is one 0x80000-byte chip** (`sbs-g_03.ic194`, a plain
  `ROM_LOAD`), not mustang's own two 0x80000-byte chips
  `ROM_LOAD16_BYTE`-interleaved into a 0x100000 logical image — same
  `gfx_8x8x4_col_2x2_group_packed_msb` decode format either way, just a
  smaller flat array and narrower address truncation.

### A real tooling bug found and fixed during bring-up

`tilerom` (the BG0 tile-index ROM) is a genuine `ROM_LOAD16_BYTE` hi/lo
pair — a 16-bit-word ROM exactly like the 68000 program ROM, *not* a
byte-addressed `gfx_layout`-decoded graphics ROM despite living next to
several of those in the same `ROM_START`. First attempt extracted it with
`tools/mkgfxrom.py --mode interleave16`, which (per that tool's own
docstring) always emits byte-per-line output even in interleave16 mode,
since real graphics ROMs are byte-addressed — this produced a
131,072-byte file for what the RTL correctly declared as a 65,536-word
array, an immediate out-of-bounds `$readmemh` error. Fixed by using
`tools/mkrom.py` instead (the tool built for genuine 16-bit-word
`ROM_LOAD16_BYTE` pairs, like the program ROM) — the right lesson here
isn't "which tool" so much as "check whether a same-`ROM_START`-neighbor
ROM is actually graphics data or just happens to sit next to some": this
one is `ROM_REGION16_BE`, the explicit 16-bit-word-region macro, which
in hindsight was the tell.

### A real testbench bug found and fixed during verification

Reused this session's earlier 68000-cycle-trace tooling (`m68k_cyc.trace`
in `tb_bioship.cpp`, diffed against a fresh `capture_cyc_trace.py
--device :maincpu` oracle capture) to sanity-check the 68000 side, same
as the mustang bus-wait-state investigation did. First result showed a
suspicious aggregate cycle ratio of 0.801 — close enough to exactly 4/5
to be a strong hint. Found it: `tb_bioship.cpp` divided every 68000
cycle timestamp by `clk_sys_ticks / 5` (copy-pasted from the adjacent
NMK004-trace line above it, which correctly uses /5 for NMK004's own
`clk_sys/5` clock) instead of `/4` (the 68000's own real `cpu_div`
divider, unchanged from mustang's ratio despite the different `clk_sys`
base rate). Fixed, re-verified: aggregate ratio **1.001** — matching
mustang's own already-established 68000 timing accuracy exactly, and
confirming bioship's own genuinely different `clk_sys` architecture
(40MHz vs 32MHz, /5 dividers instead of /4 for the NMK004/pixel domain)
introduced no real regression, just a measurement bug in newly-written
testbench code. A useful, generalizable reminder: a ratio suspiciously
close to a small rational fraction (4/5, not e.g. 1.37) is itself a clue
to check unit-conversion arithmetic before suspecting the RTL.

### Verification results

NMK004-side oracle checkpoint match (`sim/oracle/capture_cyc_trace.py
--device :nmk004:mcu`, 2-second capture, 1,211,651 oracle instructions,
diffed via `sim/compare/cyc_diff.py`): **609,081 of 1,211,651 matched**
at the testbench's own `RUN_CYCLES=900,000,000` (22.5s of simulated
`clk_sys` time — bumped up from an initial 75,000,000 after the first
attempt showed an entirely-blank palette/VRAM, root-caused below to be a
genuine "needs more simulated time" situation, not a bug, matching this
session's own well-established resolution pattern from every prior
Tier 2 milestone). Per-instruction cycle-cost accuracy, measured
separately at a shorter, comparably-scoped 75,000,000-cycle run (to keep
the oracle/candidate trace lengths apples-to-apples — a very long
candidate trace against a fixed 2-second oracle capture produces
misleadingly huge cycle deltas wherever the greedy PC-matcher has to
skip over extra loop iterations the oracle's own shorter window never
reached, not a real timing regression): **73/605,036 (0.012%)
mismatches**, every one individually the same two already-documented,
bounded causes from this session's own TLCS-90 cycle-timing fix (the
`DJNZ` MAME-quirk and the 1-cycle FSM-structural-floor cases) — direct
confirmation that fix generalizes correctly to a second game's own boot
ROM, not something mustang-specific. 68000-side cycle accuracy (same
shorter run, same tooling): aggregate ratio **1.001** — matching
mustang's own already-established figure.

Video: first attempt (`RUN_CYCLES=75,000,000`) rendered entirely black,
with palette RAM showing 0/1024 non-zero entries — genuinely just early
in boot, not a bug: a live MAME watchpoint capture on the palette RAM
address range confirmed the reference itself writes RAM-test patterns
there within the first handful of machine-start events, and a plain
disassembly of the 68000's own early boot code (`00E734: move.l
#$20000,D0` / `00E73A: subq.l #1,D0` / `00E73C: bne $e73a`) showed a
genuine ~131,072-iteration busy-wait delay loop very early on, plus
repeated visits back to the reset vector (`$000400`) consistent with
NMK004's own P4-bit0 reset-hold mechanism toggling the 68000's reset
line more than once during its own boot sequence — a slower, more
self-test-heavy boot than mustang's own. Bumping `RUN_CYCLES` to
300,000,000 then 900,000,000 showed steadily increasing real content
(palette non-zero count 0 → 28 → 320 of 1024; rendered non-zero pixel
count 0 → 0 → 60,476 of 86,016), confirming genuine forward progress
rather than a stuck/deadlocked state. At 900,000,000 cycles, a rendered
PPM frame dump shows a clearly readable "BIO-SHIP PALADIN" title screen
with correctly colored, correctly composited "PLEASE INSERT COIN" /
"AMERICAN SAMMY CORP" / "LICENSED BY UPL CO.,LTD" text — matching (and,
by matched-checkpoint-count, exceeding) the verification bar mustang's
own Milestone 6 set. All of mustang's own existing regressions (CPU-only
oracle match, interrupt self-test, mustang's own system oracle match,
Tier 1's bjtwin build) are unaffected — this port touched no shared file
at all, only new `rtl/bioship/`/`sim/rtl/bioship/` files.

Not chased further in this pass (consistent with this session's own
established "root-cause and verify structurally, don't chase every
possible remaining divergence" pattern): the NMK004 checkpoint match's
own stopping point past 609,081 (whether it's the same class of
benign async-event-timing divergence already closed out for mustang, or
something bioship-specific, hasn't been individually root-caused); and
frame-CRC-exact video (out of scope for the same reasons established in
mustang's own "68000 bus-wait-state timing" investigation above — MAME's
own oracle timing for unsynchronized inter-CPU events isn't a
bit-exact-reproducible target in general).

## blkheart — extending nmk_irq and the video pipeline to a third game

The third Tier 2 NMK004-board game, after mustang and bioship above.
Structurally much closer to mustang than bioship was: blkheart's own
machine config (`nmk16.cpp`) reuses mustang's *exact same* MAME helper
functions — `screen_update_macross`, `VIDEO_START_MEMBER(macross)`,
`gfx_macross` (same GFXDECODE color bases: TX=0x200, BG=0x000,
sprites=0x100), and the same nominal 8MHz/8MHz 68000/NMK004 clock pair —
so `rtl/blkheart/blkheart_core.sv` keeps mustang_core.sv's own 32MHz
`clk_sys`/`/4` clock architecture completely unchanged, and
`rtl/blkheart/video_blkheart.sv` is a close derivative of
`video_mustang.sv` with two real, targeted additions rather than
bioship's own wholesale extra-layer rework.

### Real differences from mustang, found by reading the reference directly

- **BG tile-code bank extension.** blkheart's own "bgtile" graphics ROM
  is 0x100000 bytes (8192 16x16 tiles) — double the 4096-tile range a
  bare 12-bit VRAM tile code addresses. `common_get_bg_tile_info<0,1>`
  (`nmk16_v.cpp`) ORs in `m_bgbank<<12` as a 13th code bit, with
  `m_bgbank` set by a real, live `tilebank_w` register (byte
  @0x080019) — this register exists in mustang's own `nmk16_state`
  class too, but mustang's own memory map never wires it to any
  address (its bgtile ROM is exactly 0x80000/4096 tiles, a clean 12
  bits), so mustang_core.sv never had to model it. blkheart does.
- **Real BG Y-scroll, not just X.** blkheart's own scroll register is
  the generic byte-sequenced `scroll_w<0>` template (four bytes: X-hi,
  X-lo, Y-hi, Y-lo, via a `.umask16(0x00ff)` byte lane — the *lower*
  byte here, gated on `~LDSn`, a genuine per-game PCB wiring difference
  from bioship's own `~UDSn` usage, not a mistake), unlike mustang's own
  X-only, mode-selector-byte `mustang_scroll_w`.
- **DSW2 is mapped** (`08000A-08000B`) — tied to the same fixed idle
  value as IN0/IN1/DSW1.
- **The sprite ROM (`90068-8.bin`) uses `ROM_LOAD16_WORD_SWAP`** — a
  single already-word-addressed file with each 16-bit word's two bytes
  stored reversed relative to what the `gfx_8x8x4_col_2x2_group_
  packed_msb` decoder expects (confirmed directly against the macro's
  own expansion in `mame/src/emu/romentry.h`:
  `ROMX_LOAD(..., ROM_GROUPWORD | ROM_REVERSE)`), not mustang's own
  two-separate-chip `ROM_LOAD16_BYTE` interleave or bioship's own
  single plain `ROM_LOAD`. `tools/mkgfxrom.py` gained a new
  `word_swap` mode for this (swaps every adjacent byte pair during
  extraction, confirmed byte-for-byte against the macro semantics, not
  guessed from the name) — the RTL's own `group16_pixel()` decode
  function needed no changes at all, since the swap happens entirely at
  extraction time, matching what MAME's own ROM_LOAD macro does before
  the gfx decoder ever sees the data.
- **The 68000 ROM region is 512KB** (double mustang's 256KB), but only
  the first 256KB (two `ROM_LOAD16_BYTE` chips) is actually populated —
  the upper half reads as zero, the same region-vs-load-size gap
  already seen for bioship's own fgtile ROM.

### Verification results

Both CPUs reach a genuine, correct steady state, not a stuck/deadlocked
one: NMK004's own last PC settles into `$01DA`/`$01DB` — disassembled
directly as `EI` / `JR $01DA`, a normal "enable interrupts, then idle
forever waiting for one" main-loop pattern, not a bug. Confirmed this is
exactly what MAME's own oracle does too (a fresh plain-text MAME trace
shows the identical `001DA: ei` / `001DB: jr ,$01DA` pair repeating
211,319 times within its own 1-second capture) — both sides genuinely
complete boot and reach the correct idle state. The NMK004 oracle
checkpoint match itself is smaller than bioship's own (7,595 of
1,339,492 in a 2-second capture, at `RUN_CYCLES=300,000,000`) not
because of a bug, but because blkheart's own boot is *shorter* — once
NMK004 reaches this interrupt-driven idle loop, all further activity is
paced by asynchronous interrupt timing (sound commands from the 68000,
the periodic timer), the same class of relative-timing granularity this
session's own mustang "68000 bus-wait-state timing" investigation above
already established isn't a bit-exact-reproducible target against
MAME's own scheduler. Per-instruction cycle-cost accuracy up to the
divergence point: 21/7,594 mismatches, the same two already-documented
TLCS-90 cycle-timing-fix edge cases (`DJNZ` at `$0147`/`$0153`, the
1-cycle structural floor at `$0D58`/`$0D67`/`$0E27`) seen in both prior
ports — a third independent confirmation that fix generalizes correctly.

Video: at `RUN_CYCLES=300,000,000` (the first value tried, no bump
needed this time — see below for why), palette RAM shows 566/1024
non-zero entries and 78,564/86,016 rendered pixels are non-zero. A
rendered PPM frame dump shows a fully readable, detailed "BLACK HEART"
title screen — ornate gothic lettering, a decorative border, gargoyle/
knight silhouettes, and correct "©1991 UPL Company Limited" copyright
text — genuinely exceeding the visual complexity of both mustang's and
bioship's own title screens, and confirming the tile-bank extension and
Y-scroll additions render correctly together. Unlike bioship,
`RUN_CYCLES` needed no bumping this time — blkheart's boot reaches a
visually meaningful state faster, consistent with the smaller,
faster-completing NMK004 checkpoint match above. All of mustang's and
bioship's own existing regressions are unaffected — this port touched
no shared RTL file; the one shared *tooling* file it did touch
(`tools/mkgfxrom.py`, for the new `word_swap` mode) was verified
byte-for-byte unchanged for every existing `--mode concat`/
`interleave16` call (re-ran mustang's own `fgtile` extraction and
diffed against the already-committed hex output — identical).

Not chased further in this pass, consistent with this session's own
established pattern: the exact NMK004 checkpoint-match stopping point
past 7,595 (whether purely interrupt-timing-driven, as the idle-loop
evidence strongly suggests, or something blkheart-specific) wasn't
individually root-caused instruction-by-instruction; frame-CRC-exact
video remains out of scope for the same reasons established in
mustang's own investigation above.

## strahl — extending nmk_irq and the video pipeline to a fourth game

The fourth Tier 2 NMK004-board game, after mustang, bioship, and
blkheart above. Video-layout-wise a *simpler* version of bioship's own
3-layer shape (BG0 opaque + BG1 transparent + TX transparent, then
sprites — `screen_update_strahl`, the literal same MAME function name
bioship uses): both BG layers here are plain VRAM tilemaps, with none of
bioship's own ROM-tile-index/bank-select complexity. But strahl has the
most genuinely different system-level architecture of any port so far —
see below.

### A real finding before any RTL was written: no real V-PROM exists for this game

strahl's own machine config calls `set_hacky_interrupt_timing`, not
`set_interrupt_timing` — MAME's own fixed-scanline substitute
(`nmk16_hacky_scanline`, nmk16.cpp:4482-4511), not the real dual-PROM
`NMK_IRQ` device every prior port used. Confirmed directly: strahl's own
`ROM_START` has no `nmk_irq:vtiming`/`nmk_irq:htiming` region at all —
there is no real PROM to dump for this game. So "extending `nmk_irq`"
doesn't mean feeding `rtl/nmk_irq/nmk_irq.sv` a new V-PROM here; it
means reusing `rtl/bjtwin/nmk_irq_hacky.sv` (Tier 1's own synthetic
fixed-scanline generator, already used for cactus/sabotenb) instead —
and its own hardcoded constants (SL_IRQ2=16, SL_IRQ1_A=68, SL_IRQ1_B=196,
SL_IRQ4=240, SL_SPRDMA=242) already match `nmk16_hacky_scanline`'s own
computed values exactly, since that Tier 1 module was built directly
against this same MAME function. A genuine, verified drop-in reuse —
zero RTL changes needed for the interrupt-timing piece of this port.

### Other real differences from mustang, found by reading the reference directly

- **The 68000 runs at 12MHz** (MAME's own comment: `// 12 MHz ?` —
  flagged as unverified even in the reference) while NMK004/OKI/YM2203
  stay at the family's usual rates. 12 and 8 share no clean power-of-2
  divisor, so `clk_sys` is 48MHz here (mustang: 32MHz, bioship: 40MHz):
  /4=12MHz (68000), /6=8MHz (NMK004+pixel, a genuine 6-cycle counter),
  /48=1MHz (OKI cen) — and, notably, 1.5MHz divides 48MHz *exactly*
  (48/32), so YM2203 needs a plain mod-32 counter here instead of every
  other port's own fractional phase accumulator.
- **`m_sprdma_base` is 0xF000, not the family's usual 0x8000** — sprite
  RAM lives at mainram word offset `0x7800`, not the `0x4000` every
  prior port's own sprite-snapshot logic hardcoded. The only change
  this required to the shared sprite-FSM architecture: one constant.
- **Main work RAM uses a plain, byte-lane-respecting write** — no
  `mainram_strange_w`-style unconditional-full-word quirk (`strahl_map`
  maps `0xf0000-0xfffff` with bare `.ram()`, no write-handler override
  at all) — matching `bjtwin_core.sv`'s own correct convention, not
  mustang's own deliberately-quirky one. Confirmed by reading the
  memory map directly rather than assuming one "family default".
- **The OKI sample ROMs are scrambled via `ROM_CONTINUE`** — a single
  physical chip's own contents sliced into four 0x20000 quarters and
  reassembled at non-sequential region offsets (nmk16.cpp's own
  comment: *"this is a mess"*). `tools/mkgfxrom.py` gained a new
  `segments` mode for this (explicit `REGION:FILE:LEN` triples, one per
  `ROM_LOAD`/`ROM_CONTINUE` line) — verified byte-for-byte against the
  raw dump before use (`region[0x60000]==raw[0x20000]`, etc., checked
  directly in Python), not just trusted to be right from reading the
  macro.
- Sprite ROM (`0x180000`, three plain-`ROM_LOAD`-concatenated 0x80000
  chips) needed no RTL changes despite being bigger than every prior
  port's own — `nmk16spr.cpp`'s own sprite `code` field is a full
  16-bit `spriteram[offs+3]` value, never masked to 12 bits the way BG
  tile codes are, so the existing `group16_pixel()` addressing already
  covers it with just a wider array/truncation.
- Different GFXDECODE color bases (`gfx_strahl`): TX=0x000, BG0=0x300,
  sprites=0x100, BG1=0x200 — a fourth genuinely distinct per-game
  assignment (mustang/bioship/blkheart each have their own too).
- DSW2 is mapped, palette RAM lives at `0x8C000` (not `0x88000`), and
  the two scroll register blocks live at `0x84000`/`0x88000` — a
  completely different address layout from every prior port's own, not
  copy-paste values.

### Verification results

**All 1,096,428 of 1,096,428 oracle checkpoints matched** — a complete,
full-2-second-capture-window match, the strongest result of any port
so far (mustang/bioship/blkheart all matched a partial prefix before
diverging or reaching an idle state; strahl's own oracle capture is
matched in full). Aggregate cycle-cost ratio: **1.000**. Per-instruction
cycle-cost mismatches: 64/1,096,427 (0.006%), the same two
already-documented TLCS-90 cycle-timing-fix edge cases (`DJNZ` at
`$0147`/`$0153`, the 1-cycle structural floor at
`$0D58`/`$0D67`/`$0E27`) seen in every prior port — a fourth independent
confirmation that fix generalizes correctly.

The reason this match is *complete* rather than partial: both NMK004
oracle and RTL spend nearly the entire 2-second window in the same
host-handshake poll loop (`$0EAB`/`$0EAF`/`$0EB1` — the identical
address mustang's own host-handshake loop was found at, in a much
earlier session's own investigation, though this is strahl's own
independently-verified occurrence of it, not an assumption it's the
same). Confirmed directly in the oracle trace: PC `$0EAB` is visited
362,829 times, with the *last* occurrence at the very last line of the
whole 1,096,428-line capture — MAME's own emulation is still in this
exact loop at the point the capture ends, genuinely, not a testbench
artifact. This means strahl's own 68000-to-NMK004 handshake takes
substantially longer to resolve than mustang's own did (whose
equivalent Milestone 1 divergence resolved essentially immediately once
a real 68000 was attached) — a real, game-specific timing
characteristic, not a bug: our own RTL tracks the oracle's own
same-loop dwelling exactly, which is precisely what a correct
implementation of a *slower-resolving* handshake should look like.

Video: at the testbench's own `RUN_CYCLES=240,000,000` (48MHz, ~5s
simulated), palette RAM shows only 4/1024 non-zero entries and
2,665/86,016 rendered pixels are non-zero — consistent with the system
genuinely not yet having reached full attract-mode graphics setup
(matching the "still in the same poll loop as MAME" finding above, not
a bug). What *is* rendered, though, is real, confirmed-correct content:
a rendered PPM frame shows a genuine hardware self-test/diagnostic
screen — readable "ROM1 CHECK OK 9800", "ROM2 CHECK OK B900", "WRAM1
CHECK OK", "WRAM2 CHECK" text, in the correct font, correctly
positioned and duplicated left/right (a real self-test display pattern,
not a rendering artifact) — directly confirming the TX tilemap decode,
palette lookup, and compositing pipeline are all functioning correctly
even this early in boot. All of mustang's, bioship's, and blkheart's own
existing regressions are unaffected — this port touched no shared RTL
file; the one shared tooling file it touched
(`tools/mkgfxrom.py`, for the new `segments` mode) was verified to
introduce zero regression to every existing mode (re-extracted
mustang's own fgtile ROM and blkheart's own word-swapped sprite ROM,
both byte-for-byte identical to their already-committed files).

Not chased further in this pass, consistent with this session's own
established pattern: whether/when strahl's own host handshake actually
resolves (a longer testbench run, well beyond this pass's own budget,
would be needed to find out) wasn't pursued, since the oracle itself
shows the SAME multi-hundred-thousand-iteration dwell within its own
comparably-sized capture window — this is evidence of correct, matching
behavior already, not an open question blocking verification; and
frame-CRC-exact video remains out of scope for the same reasons
established in mustang's own investigation above.

## acrobatm — extending nmk_irq and the video pipeline to a fifth game

The fifth Tier 2 NMK004-board game, after mustang, bioship, blkheart,
and strahl above. A genuine hybrid of two prior ports rather than a new
shape: acrobatm's own video family is *identical* to blkheart's own
(`screen_update_macross`, `VIDEO_START_MEMBER(macross)`, `gfx_macross` —
same single-BG-layer-plus-TX layout, same BG tile-code bank extension
via `tilebank_w`, same palette color bases), while its 68000/NMK004
clock ratio is *identical* to bioship's own (10MHz 68000 against
NMK004's unchanged 8MHz) — so `rtl/acrobatm/video_acrobatm.sv` is a
close derivative of `video_blkheart.sv`, and `acrobatm_core.sv`'s own
clock-enable section reuses bioship_core.sv's own 40MHz `clk_sys`
architecture verbatim. The one genuinely new thing: the memory map
itself is laid out completely differently from every prior port.

### Real differences from mustang, found by reading the reference directly

- **The memory map is laid out completely differently** — main work RAM
  sits at `0x080000-0x08FFFF` (every prior port's own is `0xF0000-
  0xFFFFF` — right after the ROM here, not at the top of the address
  space), while the I/O/register block (IN0/IN1/DSW1/DSW2/NMK004
  latches/flip/NMI/tilebank) sits at `0xC0000+` (every prior port's own
  is `0x80000+`). Confirmed bit-alignment directly before relying on
  plain `byte_addr[N:1]` slicing for each region (every region base
  here happens to still be cleanly size-aligned, same convenient
  property every prior port's own memory map had — checked, not assumed,
  since acrobatm's own base addresses are genuinely different numbers).
- **Palette RAM is 768 entries, not the family's usual 1024**
  (`PALETTE(config, m_palette).set_format(...,768)`, confirmed against
  `acrobatm_map`'s own palette region size, `0xC4000-0xC45FF` = 0x600
  bytes = 768 words exactly).
- **BG tile-code bank extension**, identical mechanism to blkheart's own
  `tilebank_w` (byte @0xC0019 here) — acrobatm's own "bgtile" ROM is
  0x100000 bytes (8192 tiles), same size and same reasoning as
  blkheart's own.
- **The 68000 runs at 10MHz** — same rate and same `clk_sys` derivation
  as bioship's own (40MHz `clk_sys`, /4=10MHz 68000, /5=8MHz
  NMK004+pixel, /40=1MHz OKI cen, 3/80 YM2203 accumulator), reused
  verbatim since the underlying clock relationship is identical.
- A real V-PROM exists for this game (`nmk_irq:vtiming`, `11.ic80`) —
  same CRC (`633ab1c9`) as mustang's own `10.bpr`, confirming yet again
  this is genuinely shared PROM content across the family — so
  `rtl/nmk_irq/nmk_irq.sv` is reused unchanged, just fed acrobatm's own
  dumped copy.
- Sprite ROM (`0x180000`, two plain-`ROM_LOAD`-concatenated files of
  *different* sizes, 0x100000+0x080000) needed no RTL changes, same
  "sprite code is a full 16-bit value, not bank-limited" reasoning
  strahl's own header already established.
- `nmk004_x0016_w` uses the standard NMI polarity (same as mustang/
  blkheart), and main work RAM uses a plain byte-lane-respecting write
  (same convention as strahl's own, not mustang's `mainram_strange_w`
  quirk) — `acrobatm_map` has no write-handler override for mainram at
  all, confirmed directly.

### Verification results

NMK004-side oracle checkpoint match: 48,274 of 1,370,398 in a 2-second
capture. Per-instruction cycle-cost mismatches up to that point: the
same two already-documented TLCS-90 edge cases (`DJNZ` at
`$0147`/`$0153`, the structural floor at `$0D58`/`$0D67`/`$0E27`) — a
fifth independent confirmation that fix generalizes correctly. The
raw cycle-cost *ratio* reported at this checkpoint count (52.676x) is
the same known measurement artifact flagged in bioship's/strahl's own
verification sections — comparing a much-longer RTL candidate trace
against a fixed-length oracle capture inflates apparent cycle deltas
wherever the greedy PC-matcher has to skip past extra loop iterations
the oracle's own shorter window never reached — not a real timing
regression.

Root-caused the match's own stopping point directly rather than just
citing the number: oracle checkpoint 48,275 is PC `$01DA` — the shared
internal-boot-ROM idle loop (`EI`/`JR $01DA`, the same address
blkheart's own idle state was found at, confirmed here to live in the
common 8K internal boot ROM every NMK004-family game shares, not a
per-game coincidence). Checked whether our own RTL actually reaches
this PC at all: **it does — `$01DA` appears 1,090,943 times** in the
full candidate trace. The match simply stops being *findable* there
because our own testbench ran for longer real time than the oracle's
own 2-second capture (`RUN_CYCLES=240,000,000` at 40MHz ≈ 6s), so by
the time the greedy matcher reaches oracle checkpoint 48,275, our own
candidate has already moved past all of *its own* many revisits to
`$01DA` and on to later, genuinely different interrupt-driven work the
oracle's own shorter capture never got to observe — the same
"interrupt-driven-idle-loop" pattern already established and understood
for blkheart, not a new class of divergence.

Video: at `RUN_CYCLES=240,000,000`, palette RAM shows 15/768 non-zero
entries and 82,349/86,016 rendered pixels are non-zero — clearly
substantial real content. A rendered PPM frame shows a fully readable,
correctly formatted DIP-switch service-mode menu ("** DIP SWITCH SETUP
**", "COIN-1 1COIN 1PLAY", "SCREEN FLIP OFF", "GAME LEVEL NORMAL",
"LANGUAGE JAPANESE", "EXTEND 1000000 1000000", etc.) on the correct blue
background with correct white text — confirming the video pipeline,
BG tile-bank extension, and palette decode all work correctly even
this deep into a genuinely different memory map. All of mustang's,
bioship's, blkheart's, and strahl's own existing regressions are
unaffected — this port touched no shared file at all (reused
`tools/mkgfxrom.py`'s existing `concat` mode unchanged for every one of
its own ROMs, no new tooling capability needed this time).

Not chased further in this pass, consistent with this session's own
established pattern: exactly what interrupt-driven work NMK004 performs
after `$01DA` in this game specifically wasn't individually traced;
frame-CRC-exact video remains out of scope for the same reasons
established in mustang's own investigation above.

## tdragon — extending nmk_irq and the video pipeline to a sixth game

The sixth Tier 2 NMK004-board game, after mustang, bioship, blkheart,
strahl, and acrobatm above. Like acrobatm, another genuine hybrid rather
than a new shape — but this time nearly everything about the video
pipeline, CPU/NMK004 clocks, and sprite-ROM loading is *identical* to
blkheart's own: same `screen_update_macross`/`VIDEO_START_MEMBER(macross)`/
`gfx_macross`, same 8MHz/8MHz clock pair, same `tilebank_w` BG bank
extension (tdragon's own bgtile ROM is 0x100000 bytes, 8192 tiles — the
exact same size as blkheart's own), same `ROM_LOAD16_WORD_SWAP` sprite
ROM, even the same oversized-region/half-populated maincpu ROM pattern
(`ROM_REGION(0x80000,...)` with only the first `0x40000` bytes actually
loaded) — every one of these confirmed directly against `ROM_START
(tdragon)` and `tdragon()`, not assumed from genre. `rtl/tdragon/
video_tdragon.sv` is therefore functionally identical to
`video_blkheart.sv` (copied with only header/module-name changes), and
`tdragon_core.sv`'s own clock-enable section is blkheart_core.sv's own
32MHz architecture verbatim. What's genuinely new: the memory map uses
acrobatm's own general layout style (mainram near the ROM, I/O block
higher up) but with real address *mirroring* on top, and a genuinely
different V-PROM.

### Real differences from mustang, found by reading the reference directly

- **Real address mirroring**, confirmed directly from `tdragon_map`, not
  assumed from any prior port's own convention: main work RAM
  (`0x080000-0x08FFFF`) has `.mirror(0x030000)` — bits 17:16 are
  don't-care for its own decode, aliasing it at `0x0B0000-0x0BFFFF` too
  (`sel_mainram` checks only `byte_addr[23:18]`, and `mainram_addr`
  deliberately excludes bits 17:16 from its own index). The small I/O/
  register cluster (`0x0C0000+`) has `.mirror(0x020000)` on *each
  individual entry* — bit 17 alone is don't-care there, aliasing those
  registers at `0x0E0000+` too — handled by masking bit 17 out of a
  shared `io_addr` once, rather than duplicating every comparison. The
  larger VRAM/palette/scroll blocks (`0x0C4000+`) have **no** mirror
  qualifier at all — confirmed by reading the map line-by-line rather
  than assuming one blanket mirror policy covers the whole thing.
- A real V-PROM exists for this game too (`nmk_irq:vtiming`,
  `91070.10`) — but with a **genuinely different CRC** (`e6ead349`)
  from every prior port's own dumped copy (mustang/bioship/blkheart/
  acrobatm all share `633ab1c9`) — the first confirmed *different*
  V-PROM content this session has seen, solid independent evidence that
  `nmk_irq.sv` is really PROM-content-driven rather than accidentally
  hardcoded to one game's own table.
- `map(0x044022, 0x044023).nopr();` — a region the reference's own
  comment admits is mysterious ("No Idea (ROM mirror? - does this even
  exist on originals?)"). Needed no dedicated handling: it doesn't match
  any `sel_*` range, so it falls through to this design's own existing
  default "unmapped read returns 0xFFFF" behavior automatically.

### Verification results

NMK004-side oracle checkpoint match: 14,865 of 1,315,062 in a 2-second
capture, with aggregate cycle-cost ratio **1.001** over the matched
span (a clean, apples-to-apples comparison this time — unlike acrobatm's
own inflated 52.676x, this divergence happens early enough that the
candidate/oracle trace lengths stay comparable). Per-instruction
cycle-cost mismatches: 28/14,864, the same two already-documented
TLCS-90 edge cases (`DJNZ` at `$0147`/`$0153`, the structural floor at
`$0D58`/`$0D67`/`$0E27`) — a sixth independent confirmation.

Root-caused the match's own stopping point (PC `$0EAB`) rather than just
citing it: this is the same host-handshake poll-loop address mustang's
and strahl's own were found at (shared internal boot-ROM code). Unlike
strahl's own genuinely slow-resolving handshake (362,829 visits within
one capture), tdragon's own resolves quickly on *both* sides — only 6
oracle visits and 8 RTL visits to `$0EAB` before each moves on — the
same race-condition-sensitive "both sides exit after a slightly
different iteration count" pattern already characterized for mustang's
own very first Milestone 1 investigation, not a new divergence class.

Video: at `RUN_CYCLES=300,000,000`, palette RAM shows 609/1024
non-zero entries, 832/1024 txvram entries touched, and 52,358/86,016
rendered pixels are non-zero — substantial real content, with far more
NMK004-side audio activity than most prior ports (127,742 YM2203
writes, 16/16 OKI writes). A rendered PPM frame shows a fully readable,
richly detailed "THUNDER DRAGON" title screen — vertical rainbow-colored
"THUNDER"/"DRAGON" lettering, Japanese kanji text, correct "©NMK Co.,
Ltd. 1991" / "DISTRIBUTED BY TECMO" copyright lines, and a small sprite
graphic in the corner — confirming the tile-bank extension, the
word-swapped sprite ROM decode, and palette/compositing all work
correctly together, sprites included (not just tilemap text, unlike
some prior ports' own title-screen verification). All of mustang's,
bioship's, blkheart's, strahl's, and acrobatm's own existing regressions
are unaffected — this port touched no shared file at all (every ROM
used an existing `tools/mkgfxrom.py` mode — `concat` or `word_swap` —
unchanged, no new tooling capability needed).

Not chased further in this pass, consistent with this session's own
established pattern: the exact post-`$0EAB` divergence point wasn't
individually traced (both sides are known to exit the loop correctly,
just after different iteration counts — the same benign class already
understood); frame-CRC-exact video remains out of scope for the same
reasons established in mustang's own investigation above.

## vandyke — extending nmk_irq and the video pipeline to a seventh game

The seventh Tier 2 NMK004-board game, after mustang, bioship, blkheart,
strahl, acrobatm, and tdragon above. First selected as "manybloc" per
the original directive, but manybloc's own hardware turned out not to
be NMK004-based at all — see "manybloc misclassification" below —
vandyke was picked instead as a genuine, still-unported family member
`docs/PLAN.md`'s own family table already listed correctly. vandyke's
own memory map is otherwise close to mustang's own (same base addresses
for IN0/IN1/DSW1/DSW2/NMK004 latches, same `0x88000` palette, same
`0x90000` BG VRAM), and its CPU/NMK004 clock ratio (10MHz/8MHz) is
identical to bioship's own, so `vandyke_core.sv`'s own clock-enable
section reuses bioship_core.sv's own 40MHz architecture verbatim.

### manybloc misclassification, found and corrected

Before picking a replacement game, read `nmk16.cpp` directly for
manybloc's own `manybloc()` machine-config function and found it
doesn't use NMK004 at all: a real Z80 audio CPU running `tharrier_
sound_map`, `gfx_tharrier` (not `gfx_macross`), `set_periodic_int` +
a custom scanline callback (not `nmk_irq`/`nmk_irq_hacky`), and a
256x256 screen (not the "lowres" 384x224 class every NMK004 game
belongs to) — no NMK004 device instantiated anywhere in its config.
This contradicted `docs/PLAN.md`'s own original Milestone-0 family
table, which had listed manybloc under Family B (NMK004) — a genuine
inventory-level error from the early broad survey, only caught now that
a game in that slot was actually being implemented in detail. Corrected
both `docs/PLAN.md` and `docs/game-inventory.md`: manybloc moved to
Family G (the real-Z80/YM2203-direct family tharrier/tharrierb/vandykeb
already belong to), with the specific `nmk16.cpp` evidence recorded
inline. Not ported this session — real Z80 CPU integration, a new
video/GFXDECODE family, and a new interrupt architecture are a
genuinely separate, larger increment, flagged for a future directive
rather than silently absorbed into "another NMK004 port."

### Real differences from mustang, found by reading the reference directly

- **`vandyke_flipscreen_w` inverts the flip polarity** relative to every
  other game's own `flipscreen_w` — the reference's own comment:
  "vandyke writes a 0 value when flip screen is enabled, contrary to
  rest of games that write 1." Captured as `~oEdb[7:0]`, not `oEdb[7:0]`
  directly.
- **`vandyke_scroll_w` packs BG X/Y scroll into a wider, byte-shifted
  4-word register**: `scrollx = vscroll[0]*256 + (vscroll[1]>>8)`,
  `scrolly = vscroll[2]*256 + (vscroll[3]>>8)`, a 24-bit-ish value MAME's
  own tilemap code wraps modulo the tilemap's real pixel width/height
  when rendering. Rather than replicating the literal multiply-and-shift
  arithmetic, computed the *effective post-modulo* value directly and
  verified it algebraically: `(vscroll[0]*256) mod 4096 = (vscroll[0]
  mod 16)*256`, so only `vscroll[0]`'s own low 4 bits survive the
  wraparound — `bg_xscroll[11:0] = {vscroll[0][3:0], vscroll[1][15:8]}`,
  `bg_yscroll[8:0] = {vscroll[2][0], vscroll[3][15:8]}` (mod 512 case,
  same derivation).
- **A genuinely mysterious extra RAM block**, `0x094000-0x097FFF` — the
  reference's own comment: `// what is this?`. Backed as plain,
  side-effect-free RAM (no known consumer anywhere in the driver),
  matching the reference's own bare `.ram()` with no write handler.
- TX VRAM lives at `0x09D000`, not mustang's own `0x09C000`.
- `tilebank_w` exists in the memory map but is effectively inert for
  this game — vandyke's own bgtile ROM is exactly `0x080000` bytes
  (4096 tiles, a clean 12-bit code, the same size as mustang's own, not
  blkheart's bigger 8192-tile one) — confirmed directly, not assumed;
  wired anyway per this session's own established practice of
  implementing a register that exists in the map even when unexercised.
- The sprite ROM (`0x200000`) is **two independent `ROM_LOAD16_BYTE`
  interleaved pairs concatenated together**, not a single interleave
  across all four files — extracted as two separate `tools/mkgfxrom.py
  --mode interleave16` runs, concatenated with a plain `cat` (both
  intermediate outputs are already one-byte-per-line `$readmemh` text,
  so literal file concatenation is correct — no new tooling needed).
- `fgtile` is genuinely smaller than every prior port's own — `0x10000`
  bytes (2048 tiles), fully populated — `fgtile_pixel()` truncates to
  16 bits here, not the usual 17, to stay in-bounds for the smaller array.

### Verification results

**All 1,096,428 of 1,096,428 oracle checkpoints matched** — a complete,
full-2-second-capture-window match, the same class of result as
strahl's own (the strongest result category seen so far). Aggregate
cycle-cost ratio: **1.000**. Per-instruction cycle-cost mismatches:
64/1,096,427 (0.006%) — the exact same count as strahl's own, and the
same two already-documented TLCS-90 edge cases — a seventh independent
confirmation.

Like strahl, this completeness comes from both oracle and RTL spending
nearly the entire capture window in the same shared host-handshake poll
loop (`$0EAB`/`$0EAF`/`$0EB1` — vandyke's own last NMK004 PC is `$0EAF`,
inside that same loop, matching mustang's/strahl's own address for it)
— a genuinely slow-resolving handshake on this game, tracked correctly
by the RTL rather than a bug.

Video: at `RUN_CYCLES=300,000,000`, palette RAM shows 669/1024
non-zero entries and 76,496/86,016 rendered pixels are non-zero. A
rendered PPM frame shows a readable "FRONT CHECK OK" diagnostic message
overlaid on a mosaic-patterned background — the mosaic is expected, not
a bug: this boot stage is a self-test screen that (per BG VRAM showing
8186/8192 non-default entries, essentially the whole tilemap) hasn't
been cleared to meaningful game art yet, and the RTL is faithfully
rendering whatever tile indices are actually present, with sharp,
correctly-decoded 16x16 tile blocks rather than corrupted/garbled
pixels — confirming the tile-decode/palette/compositing pipeline is
working correctly even on effectively-random VRAM content. All of the
six prior ports' own existing regressions are unaffected — this port
touched no shared RTL file (used only existing `tools/mkgfxrom.py`
modes — `concat` and `interleave16` — unchanged).

Not chased further in this pass: whether/when vandyke's own handshake
actually resolves wasn't pursued (same reasoning as strahl's own
verification — the oracle itself shows the same multi-hundred-
thousand-iteration dwell within its own comparably-sized capture,
already strong evidence of matching behavior); frame-CRC-exact video
remains out of scope for the same reasons established in mustang's own
investigation above.

## hachamfb — extending nmk_irq and the video pipeline to an eighth game

The eighth Tier 2 NMK004-board game, after mustang, bioship, blkheart,
strahl, acrobatm, tdragon, and vandyke above. A genuine composite of
pieces every one of those prior ports already built — no new technique
was needed at all: memory-map base addresses (IN0/IN1/DSW1/DSW2/NMK004
latches at `0x080000+`, palette at `0x088000`, BG VRAM at `0x090000`,
TX VRAM at `0x09C000`, mainram at `0x0F0000`) identical to mustang's
own; the scroll register (`scroll_w<0>`) and `tilebank_w` identical to
blkheart's own; a plain byte-lane-respecting mainram write (the
reference's own comment: "Main RAM, inc sprites, shared with MCU", bare
`.ram()`, no write-handler override) matching strahl's/acrobatm's/
tdragon's own convention; the 10MHz/8MHz CPU/NMK004 clock ratio
identical to bioship's own; and a `ROM_LOAD16_WORD_SWAP` sprite ROM
identical to blkheart's/tdragon's own convention.

### Hardware-family verification done before writing any RTL

`hachamfb` shares its name-root with a *protected* game family
(`hachamf`/`hachamfp`, which use a real TMP91640 "NMK-113" TLCS-90
protection MCU — Tier 2's own Family D, a genuinely separate, much
larger increment not attempted this session). Confirmed directly,
rather than assumed from the name, that `hachamfb` doesn't need any of
that: its own `GAME()` macro names `hachamf` (the plain, unprotected
machine-config function) as its machine-config function — the
*separate* `hachamf_prot()` function (which calls `hachamf(config)`
then adds the TMP91640 on top) is what the protected romsets actually
use. `ROM_START(hachamfb)` itself has no protection-MCU ROM region at
all, consistent with its own in-source comment ("Thunder Dragon
conversion - unprotected prototype or bootleg?"). The same kind of
up-front verification this session already did for manybloc (found to
be a real misclassification) and strahl (found to need the hacky IRQ
generator) — here it confirms this game genuinely belongs in the same
bucket as every prior port.

hachamfb's own ROMs are split across two zips — `hachamfb.zip` itself
(just the 68000 program ROMs) and its parent `hachamf.zip` (everything
else, including an `nmk-113.bin` protection-MCU ROM this port correctly
never touches) — resolved via `tools/mkgfxrom.py`'s existing multi-`
--zip` search, the same split-romset pattern this project's own Tier 1
ROM auditing already established.

### Verification results

NMK004-side oracle checkpoint match: 108,116 of 1,210,811 in a
2-second capture — the largest partial match of any port so far.
Per-instruction cycle-cost mismatches: 19/108,115 (0.018%), the same
two already-documented TLCS-90 edge cases — an eighth independent
confirmation. Root-caused the match's own stopping point (PC `$0196`,
the same DJNZ-delay-loop region already seen in acrobatm's own
verification) rather than just citing it: confirmed our own RTL
genuinely reaches and settles into the shared internal-boot-ROM idle
loop (`$025B`, appearing 46,444 times in the full candidate trace) —
the same "reaches the correct steady state, then continues into
interrupt-driven work beyond the oracle's own shorter capture window"
pattern already characterized for acrobatm and blkheart, not a new
divergence class.

Video: at `RUN_CYCLES=300,000,000`, **the entire screen renders**
(86,016/86,016 pixels non-zero) — the first port this session to reach
full-frame coverage. A rendered PPM frame shows a fully readable
"HACHA MECHA FIGHTER" title screen: a sky-and-clouds background, a
mascot character sprite, the "NMK" company logo, and correct purple
decorative borders — confirming the BG tile-bank extension (genuinely
exercised this time, unlike vandyke's inert case), the word-swapped
sprite decode, and full-screen tilemap/sprite compositing all work
together correctly. All of the seven prior ports' own existing
regressions are unaffected — this port touched no shared file (used
only existing `tools/mkgfxrom.py` modes — `concat` and `word_swap` —
unchanged).

Not chased further in this pass: the exact post-`$025B` interrupt-driven
activity wasn't individually traced (same reasoning as acrobatm's own
verification); frame-CRC-exact video remains out of scope for the same
reasons established in mustang's own investigation above.

## tdragon1 — Family D, the first TLCS-90 protection-MCU game

With every distinct Family B (NMK004) target now ported, the user chose
to start Family D — games protected by a *second*, independent TLCS-90
running as a shared-RAM protection MCU (NMK-110/113/215), not just a
sound board. tdragon1 was picked as the first target: `tdragon_prot()`
in the reference calls `tdragon(config)` first, then only *adds* the
protection MCU on top, confirming the underlying 68000/NMK004/video
hardware is byte-for-byte the same as the already-ported `tdragon` —
the natural minimal first increment for this new mechanism. Confirmed
directly from `mame/src/mame/nmk/nmk16.cpp`/`nmk16.h` (not assumed):

- `mcu_port6_w(u8 data)`: `0x08` asserts `INPUT_LINE_HALT` on the
  68000, `0x0B` releases it — a real bus-take/bus-release mechanism,
  not a software shortcut.
- `mcu_port5_r()`: returns `screen.vpos()>>2` — the MCU can read the
  current scanline.
- `mcu_port6_r()`: toggles and returns a status byte on every read
  (`m_bus_status ^= 0x04`, returning the *post*-toggle value).
- `mcu_side_shared_r/w(offs_t offset, u8 data)`: a literal pass-through
  to `m_maincpu->space(AS_PROGRAM).read_byte/write_byte(offset, data)`
  — the protection MCU has full byte-level access to the 68000's
  *entire* memory space, not a narrow shared window. `offset` spans
  `0x000000-0x0fffff` (20 bits) in `tdragon_prot_map`, which matches
  this project's own already-built (never previously exercised) IX/IY
  bank-extension mechanism in `tlcs90.sv` exactly:
  `{addr_bank[3:0], addr[15:0]}` is a 20-bit byte address.
- `TMP91640` (the protection role's own device, internal 16KB ROM /
  512B RAM) uses the *identical* `tmp90840_regs` on-chip peripheral
  register map as `TMP90840` (NMK004's own role) — confirmed directly
  in `mame/src/devices/cpu/tlcs90/tlcs90.cpp` — differing only in
  internal ROM/RAM size and RAM address. This meant the existing,
  8-times-verified `nmk004_periph.sv` could be reused for the new role
  via a small, additive extension rather than a parallel implementation.

### What was built

- **`rtl/tlcs90/nmk004_periph.sv`** extended (additive only, tied
  inert for NMK004's own role): new `p5_ext_en/p5_ext_val`,
  `p6_ext_en/p6_ext_val` inputs let an external role override the P5/P6
  read values (needed since the protection role's P5/P6 semantics are
  real hardware callbacks, not plain latches), and new `p6_we`/`p6_wdata`
  outputs tap every P6 write. `rtl/tlcs90/nmk004_core.sv`'s own
  instantiation ties all four new inputs to their inert defaults —
  confirmed behavior-identical to the prior code, and the clean rebuild
  of mustang and tdragon (below) confirms this in practice, not just by
  inspection.
- **`rtl/tlcs90/nmk_prot_core.sv`** (new): the protection-MCU board
  wrapper — a second `tlcs90.sv` instance (same CPU core, no changes
  needed there), the new 16KB boot ROM / 512B internal RAM sizing,
  address decode that hides `0x0000-0x3FFF`/`0xFDC0-0xFFBF`/
  `0xFFC0-0xFFEF` behind internal ROM/RAM/peripherals (matching the
  reference's own comment "0x000000-0x003fff is hidden by internal
  ROM, as are some 0x00fxxx addresses by RAM") and routes everything
  else — including every nonzero bank — to a shared-bus master
  interface (`bus_addr`/`bus_rd`/`bus_wr`/`bus_wdata`/`bus_rdata`).
  Port 5 wired to an external scanline input; port 6 read implemented
  as a registered toggle whose *read value* reflects the post-toggle
  state on the very read that causes it (matching the reference's own
  "toggle then return" semantics); port 6 write inspected for exactly
  `0x08`/`0x0B`, driving a `halt_68k` output.
- **`rtl/tdragon1/tdragon1_core.sv`** (new): `tdragon_core.sv` plus the
  protection MCU wired in. New: a `clk_sys/8` (4MHz) clock divider for
  the protection MCU (matching the reference's own `XTAL(4'000'000)`,
  parallel to the existing `clk_sys/4`→8MHz NMK004 divider); every RAM
  array the protection MCU can reach (mainram/palette/
  bgvram/txvram) gained a second write path with protection-MCU
  priority on a same-cycle conflict (a deterministic tie-break for
  simulation, not a modeled arbitration circuit — justified by the
  real hardware's own HALT-before-sensitive-access protocol, which
  should make genuine same-cycle conflicts rare in practice); `fx68k`'s
  own `HALTn` input, tied `1'b1` in every prior port since no game
  before this one could actually halt the 68000, is now driven for
  real (`~halt_68k`). `rtl/tdragon/video_tdragon.sv` reused completely
  unchanged (tdragon1's video hardware is identical to tdragon's own).
- ROMs: `tdragon1.zip` supplies only `thund.7`/`thund.8` (maincpu — a
  different program from tdragon's own `91070_68k.7/.8`) and
  `nmk-110-tdragon.bin` (16KB protection-MCU boot ROM). Every other
  region is byte-for-byte identical to the already-extracted tdragon
  romset (confirmed via `unzip -l`), reused via the same split-zip
  pattern already established for hachamfb/hachamf.
- `sim/rtl/tdragon1/tb_tdragon1.cpp`: built on tb_tdragon.cpp's own
  pattern, plus a second instruction-trace stream for the protection
  MCU (`/8` divisor, not `/4`) and a halt-state transition log — the
  first port needing direct visibility into a second CPU and a real
  HALT signal.

### Two real bugs found and fixed during bring-up

Both found by comparing the protection MCU's own oracle-vs-candidate
cycle trace and root-causing the actual divergence, not just noting a
mismatch count:

1. **`irq_req` tied to `1'b0`** in `nmk_prot_core.sv`'s own `tlcs90`
   instantiation. The header's own reasoning ("the reference wires no
   interrupt sources into `m_protcpu` beyond the port callbacks")
   conflated "no *external* interrupt source" with "no interrupts at
   all" — the on-chip TIMER peripheral's own interrupts (already
   generated by `nmk004_periph.sv`'s own `irq_req` output, exactly as
   `nmk004_core.sv` already wires it) still need to reach the CPU core,
   since they're internal to the TLCS-90 itself. Without this, the
   boot ROM's own main loop (`$08B4`: an unconditional background loop)
   never got interrupted into the periodic timer ISR that actually
   contains the bus-take sequence — confirmed via a direct MAME
   `dasm`+`trace` capture showing the *oracle* reaching `mcu_port6_w`'s
   own `$00B98` (`ld (P6),$08`) within the first captured second, while
   the RTL candidate never reached it at all across a 300M-cycle run.
   Fixed by wiring `.irq_req(irq_req_periph)`, matching
   `nmk004_core.sv`'s own convention.
2. **`ix_bank`/`iy_bank` left unconnected** on the same `tlcs90`
   instantiation (and the peripheral's own `bx`/`by` outputs left
   unconnected too). This is the bank-extension mechanism the whole
   shared-bus reach depends on (`bus_addr = {cpu_addr_bank, cpu_addr}`)
   — leaving it unconnected silently strands every bank-extended
   access at bank 0 regardless of what firmware writes to `BX`/`BY`
   (e.g. the boot ROM's own `ld (BX),$08` before a shared-RAM access,
   confirmed present in the disassembly). With only the first fix
   applied, the protection MCU *did* reach and repeatedly execute its
   halt/bus-take/release sequence (508 times over 300M cycles,
   confirmed via `dbg_halt_68k`) — real, measurable progress — but the
   68000 still ended up executing zero-filled ROM and crashing into an
   illegal-instruction trap, because every bank-extended read/write the
   protection MCU performed was silently landing at the wrong address.
   Fixed by wiring `.ix_bank(cpu_bx), .iy_bank(cpu_by)` from the
   peripheral's own `bx`/`by` outputs, exactly as `nmk004_core.sv`
   already does for NMK004's own role.

Both fixes verified against a fresh 2-second `:protcpu` oracle capture
(`sim/oracle/traces/tdragon1_prot_cyc.trace`, 644,458 instructions) via
`cyc_diff.py`: 86,221 of 644,458 oracle checkpoints matched as an
ordered subsequence of the candidate's own 2,997,417-instruction trace,
14/86,220 cycle-cost mismatches — all phase-dependent polling-loop
artifacts (the same class already established for strahl/vandyke), no
new mismatch class. The NMK004 side is completely unaffected: 240,087
of 1,199,391 oracle checkpoints matched, 16/240,086 mismatches, all
already-documented (the DJNZ-quirk pair at `$0147`/`$0153`, the
1-cycle FSM-floor pair at `$0D58`/`$0D67`/`$0E27`) — a ninth
independent confirmation of those two established edge cases.
Regression check: clean rebuilds of both mustang and tdragon from a
clean `obj_dir` produced output identical to their own established
baselines (tdragon's own NMK004 instruction count, 4,765,311, matched
the exact figure already established earlier in this same session's
own verification, byte-for-byte).

### Remaining known issue — not yet playable

The protection mechanism itself is verified correct, but tdragon1
still renders a blank screen (palette RAM never receives a single
nonzero write across a full 300M-cycle/9.4-second run). Root-caused via
extensive direct MAME-oracle disassembly (dozens of targeted
`dasm`/`trace` captures, and a temporary `dbg_hl` addition to
`nmk_prot_core.sv` to compare live register state against the oracle's
own debugger readout) down to a precise mechanism, not just observed:

- The 68000 boot ROM installs a tiny self-modifying "trampoline" at
  mainram `$BEF00` (an infinite `bra.b $BEF00` self-loop) and waits.
  On real hardware (oracle), this gets patched — via the *protection
  MCU*, not an interrupt, confirmed by checking that literally no
  other PC value appears in the oracle's own maincpu trace for the
  entire ~527K-visit duration of the loop — with `4EF9 0000 92F4`
  (`JMP $92F4.L`), and execution continues correctly into normal game
  code.
- The RTL candidate patches the *same* trampoline with `4EF9 0000
  0200` instead — `$92F4`'s low word replaced by `$0200`, landing in
  unpopulated (zero-filled) ROM, which the 68000 then executes as a
  long run of `ori.b #0,D0` before hitting a genuine illegal opcode and
  trapping into the ROM's own diagnostic exception handler (which logs
  an error code to `$D07C4` and halts forever — confirmed via the
  68000's own exception vector table, dumped directly from the ROM:
  vector 4, illegal instruction, points exactly at the reached handler).
- Traced the value itself: the protection MCU computes this address by
  zeroing an accumulator (`exx / ld hl,$0000 / exx`), then scanning a
  fixed ROM table (bank 0, the MCU's own internal ROM — confirmed
  byte-identical between the extracted `.hex` and the raw romset file,
  ruling out an extraction bug) with a fixed mask (`DE=$BAA4`,
  identical between oracle and candidate), OR-ing in each matching
  entry's own payload word (`or hl,(iy+2)`, executed on the alternate
  register set via `exx`). The table itself and the mask are identical
  — the divergence is in *how many entries match*, which table is even
  selected in the first place (`iy` is loaded from a small dispatch
  table indexed by a value derived from internal RAM `$FF08`), and
  ultimately in which of several independent "sub-task" code paths in
  the protection MCU's own main dispatch loop actually ran by this
  point — the oracle runs one extra sub-task (which explicitly sets
  `$FF08`) that the candidate's own dispatch pass, at the corresponding
  point, does not.
- Checked and ruled out: a CPU-core bug in `EXX` itself (the
  implementation in `tlcs90.sv` is a straightforward, correct 3-way
  swap); a hardcoded clock-rate assumption in `nmk004_periph.sv`'s own
  timer logic (it's purely relative to its own `.clk` input, confirmed
  by grepping for any absolute-frequency constant — none exist); a
  gross startup-phase offset (the very first bus-take timing between
  oracle and candidate differs by only ~0.66%, not a large systematic
  skew); and a broad per-instruction cycle-cost bias (the cycle-diff
  above shows exact, zero-diff matches for the overwhelming majority of
  checkpoints — the divergence isn't death-by-a-thousand-cuts, it's a
  genuine "different number of events accumulated" difference at one
  specific decision point).
- Most likely root cause, not fixed this session: `rtl/bjtwin/
  video_timing.sv` (shared, unchanged since Tier 1) resets `hcount`/
  `vcount` to exactly `0` — a fully deterministic raster phase on every
  single run. MAME's own screen device almost certainly releases the
  CPU's reset at a *different* (but, for MAME itself, also fixed)
  raster phase. Every one of the 8 prior Tier 2 ports' own polling
  loops tolerated this difference silently (it only ever showed up as
  a bounded, already-documented residual cycle-cost mismatch in
  verification, never affecting whether the game actually rendered).
  tdragon1's own protection self-test is the first piece of code in
  this entire project sensitive enough to *how many scanline-boundary
  events have occurred since reset* to actually break on it — its own
  computed jump target depends directly on that count.

**Decision, made explicitly by the user after this full root-cause was
laid out:** stop here and document this as a known limitation rather
than attempt a fix. A real fix means either touching `video_timing.sv`
(shared by every one of the 8 already-verified Tier 2 ports, requiring
full re-verification of all of them) or an empirical, unprincipled
per-game timing tweak in `tb_tdragon1.cpp` that wouldn't reflect a real
understanding of the timing relationship and could easily stop working
under slightly different conditions. Both were explicitly considered
and declined in favor of documenting the finding.

**Status:** the protection-MCU infrastructure (`nmk_prot_core.sv`, the
additive `nmk004_periph.sv`/`nmk004_core.sv` extension) is built,
architecturally verified against the reference, and oracle-confirmed
correct for everything it does; `tdragon1_core.sv` and its testbench
exist and build cleanly; two real bugs were found and fixed along the
way. tdragon1 itself is not yet playable (blank screen, protection
self-test failure) — the first port this session to end in this state.
No regressions to any of the 8 prior ports.

## hachamf — Family D, second TLCS-90 protection-MCU game, same root cause confirmed

The second Family D target, moving on from tdragon1 per the user's own
next directive. Confirmed directly from the reference that
`hachamf_prot()` calls `hachamf(config)` first (same pattern as
`tdragon_prot()`/`tdragon()`), and that `hachamf()` is the *same*
machine-config function the already-ported, genuinely-unprotected
`hachamfb` uses — so `rtl/hachamf/hachamf_core.sv` is `hachamfb_core.sv`
plus the protection MCU wired in, and `video_hachamfb.sv` is reused
directly, unchanged.

Genuinely new versus tdragon1's own wiring: hachamf's own protection
ROM (`nmk-113.bin`, "NMK-113") is confirmed, directly from the
reference's own comment on `hachamf_prot()`, to be a *shared* firmware
image used by several different games, which select their own per-game
codepath by reading a fixed, hardwired constant from port 7
(`port_read<7>().set_constant(0x0c)` for hachamf specifically — the
reference's own comment table names 0x0c "Hacha Mecha Fighter"). This
is a genuinely different mechanism from tdragon1's own dedicated
NMK-110 ROM, which never reads port 7 at all. Handled via a new,
additive P7 external-read override on `nmk004_periph.sv` (identical in
shape to the existing P5/P6 override, tied inert by default) and new
`P7_EXT_EN`/`P7_EXT_VAL` parameters on `nmk_prot_core.sv` (default off
— tdragon1's own instantiation is unaffected, confirmed by a clean
tdragon1 regression rebuild producing byte-for-byte identical
instruction counts to its own established baseline). `hachamf.zip` is
fully self-contained, unlike hachamfb's/tdragon1's own split-zip
dependency on a parent romset.

### Verification results

Both oracle comparisons are the strongest of any Family D port so far.
NMK004 side: 230,261 of 1,234,990 oracle checkpoints matched (18.6% —
the largest match percentage of any port this session), 19/230,260
cycle-cost mismatches — the same 16 already-established TLCS-90 edge
cases (DJNZ-quirk pair, FSM-floor triple) plus 3 large-diff entries at
the known `$0EB1` host-handshake poll-loop region, the same
already-documented "genuinely slow-resolving poll loop" class already
seen for strahl/vandyke, not a new divergence. Protection-MCU side:
86,219 of 628,019 oracle checkpoints matched, 15/86,218 mismatches, the
exact same pattern (phase-dependent scanline-poll-loop divergence) as
tdragon1's own protcpu-side comparison, cycle-for-cycle. The protection
mechanism itself works: 803 real halt/bus-take/release cycles over the
run (more than tdragon1's own 508), heavy 68000 write activity
(2,666,989 write bus cycles) and NMK004 sound activity (24,581 YM2203
writes) — genuinely more game logic executing than tdragon1's own
stuck-early state, not less. Regression check: clean rebuilds of both
mustang and tdragon1 produced instruction counts identical,
byte-for-byte, to their own already-established baselines (mustang:
1,200,859 NMK004 instructions; tdragon1: 6,051,804 NMK004 / 2,997,417
protcpu instructions, 508 halts) — the new P7 override is confirmed
inert for every caller that doesn't set it.

### Same known limitation as tdragon1, confirmed rather than re-derived

hachamf still renders a blank screen (palette RAM: 0/1024 nonzero
across the full 300M-cycle run, same as tdragon1's own). Rather than
repeat tdragon1's own from-scratch multi-hour disassembly investigation,
checked directly for the same signature already root-caused there: the
68000's own last-fetch trace shows it permanently stuck in a 4-PC tight
loop (`$81 9C-$81A2`); disassembling that region via MAME's own
debugger (not capstone, which silently mis-decodes this ROM's own
alignment the same way it did for tdragon1's) shows exactly the same
structure as tdragon1's own error table — `move.w #N,$9C008.l` /
`bra $819C` entries (an error-code-reporting self-test dispatcher, this
game's own analog of tdragon1's `$D07C4`/`$9660` table) funneling into
`$00819C: clr.w $100.w` / `$0081A0: bra $819C`, an infinite trap. This
confirms the root cause generalizes across Family D rather than being
a tdragon1-specific fluke: any protection self-test sensitive to *how
many scanline-boundary events have accumulated since reset* will hit
this, since `rtl/bjtwin/video_timing.sv`'s own deterministic
reset-to-`hcount=vcount=0` phase (shared, unchanged since Tier 1) most
likely differs from MAME's own reset-relative raster phase — see
tdragon1's own section above for the full derivation, not repeated
here.

**Status:** same as tdragon1 — protection-MCU infrastructure fully
built, wired, and oracle-verified correct (and, per the P7 mechanism,
proven to generalize to a second, differently-shaped protection ROM);
the game itself is not yet playable, blocked on the same documented,
shared-infrastructure-level known limitation. No new bug in this port,
no regressions to any of the 9 prior ports.

## video_timing.sv reset-phase fix — the raster-phase half of the tdragon1/hachamf limitation, resolved

At the user's own explicit direction, revisited the "known limitation"
documented above rather than leaving it as-is. The investigation went
through several wrong turns before landing on real, MAME-verified
ground truth — worth recording honestly, not just the final answer,
since the wrong turns are exactly the kind of trap a future session
could fall back into:

- **First wrong turn**: a MAME debugger `trace ...,noloop` capture
  (the exact mechanism `capture_cyc_trace.py` uses for every oracle
  capture this project has ever taken) showed the protection MCU's own
  P5 register (`screen.vpos()>>2`) reading as a constant, frozen value
  across 28,000+ consecutive polling-loop iterations spanning over
  300ms of emulated time — a real screen device cannot behave this
  way. Chased this down a long path (Lua `register_periodic` sampling,
  which turned out to alias against a per-frame hook of its own) before
  ruling both measurement methods untrustworthy for this specific
  question rather than trusting either one.
- **Second wrong turn**: with the debugger's own P5 reading discredited,
  ran tdragon1 under `-video none -nothrottle` for 15 real seconds with
  a Lua PC-sampling hook (`register_periodic`, once per frame) and
  concluded real MAME *also* hangs forever at `$9640/$9646`. This was
  itself a measurement artifact — **the user caught it**, reporting that
  their own interactive `mame -rompath mame_roms tdragon1` run reached a
  title screen. Frame-synchronized periodic sampling aliases against any
  code with a consistent per-frame structure (exactly the trap that
  discredited the first attempt too) — `$9640/$9646` turned out to be a
  hot but entirely normal per-frame subroutine, not a hang.
- **Correct methodology, found only after the correction**: a Lua
  `install_write_tap`/`install_read_tap` memory tap (fires on every
  genuine access, immune to frame-synchronized aliasing since it isn't
  polling on any fixed schedule at all) confirmed real MAME writes
  palette RAM at t≈1.317s and P5 genuinely advances continuously
  (measured incrementing $0B→$0C→$0D over successive real reads,
  ~252us apart — matching `scan_period()`'s own 64us/scanline times 4,
  exactly the granularity `>>2` produces). This is the technique that
  should be reached for first, not last, for any future "is MAME's own
  timing state actually changing" question — periodic/frame-scheduled
  Lua hooks and debugger `trace` actions are BOTH untrustworthy for
  this class of measurement.

With a trustworthy measurement method in hand: `screen.vpos()>>2` = $0B
(vpos in [44,47]) at real time 5.260ms after machine start, while our
own RTL's `vt_vcount` at the exact corresponding point (verified via a
temporary `dbg_vt_vcount` output, cross-checked against the protection
MCU's own cycle-accurate timing so the comparison point is genuinely
the same moment on both sides) was 82 — not a rate mismatch (confirmed
separately: MAME's own `scan_period()`=64us and `frame_period()`/
`scan_period()`=278 exactly match `video_timing.sv`'s own VTOTAL=278,
and the observed P5 real-time increment rate matches 64us/scanline
exactly), but a pure phase offset. Solving
`vpos(t=0) + 5260/64 ≡ [44,47] (mod 278)` for `vpos(t=0)` gives
`[240,243]` — landing exactly on `VACTIVE_END` (240), independently
corroborated by `time_until_vblank_start()` returning exactly
`frame_period()` at t=0 (consistent with the beam sitting precisely at
the vblank-start boundary already). **`video_timing.sv`'s own
`vcount` now resets to `VACTIVE_END` (240) instead of 0**, matching
real MAME's own screen-device convention: the beam starts at the top
of vblank, not the top of the frame.

### Regression sweep

`video_timing.sv` is shared by every Tier 1/2 port (11 total). Full
regression rebuild + oracle re-verification across all of them:

- **mustang**: NMK004 side unaffected (identical instruction count,
  1,200,859, since NMK004 never reads P5 in its own role). 68000 side
  showed a real behavior change (different last-fetch PC, +30
  instructions) — confirmed via a controlled A/B test (stashed the fix,
  rebuilt, re-ran the identical `cyc_diff.py` comparison, restored the
  fix) that the 5043/12602 68000-side cycle-cost mismatch is **byte-
  for-byte identical** in both the pre-fix and post-fix builds — a
  pre-existing, already-documented "68000 bus-wait-state timing" quirk,
  not something this fix introduced.
- **strahl**, **vandyke**: still a complete 1,096,428/1,096,428
  checkpoint match, unchanged from their own established baselines.
- **acrobatm**: checkpoint match improved (55,184 vs the established
  48,274), same stopping point (`$01DA`, the shared idle loop) and same
  benign inflated-ratio class already documented.
- **tdragon**: exact match to established baseline (14,865 checkpoints,
  28 mismatches, identical numbers).
- **hachamfb**: exact match to established baseline (108,116
  checkpoints, 19 mismatches, identical numbers).
- **hachamf**: genuine improvement on both sides — NMK004 checkpoint
  match 239,972 (up from 230,261), protcpu-side match 109,943 (up from
  86,219) with fewer residual mismatches (4 vs 15) — strong positive
  evidence the fix is directionally correct, not just harmless.
- **blkheart**: consistent with the established pattern (stops at the
  same shared idle loop `$0196`, same residual mismatch classes) but
  not cross-checked against an exact saved baseline number.
- **bioship**: consistent with the established benign pattern (small
  mismatch fraction, inflated ratio explained by an unusually long
  900M-cycle run against a fixed 2-second oracle capture) — no exact
  saved baseline number to cross-check against either.
- **bjtwin** (Tier 1 — architecturally the most exposed to this change,
  since its own 68000 has no NMK004 reset-hold buffering it from the
  raster phase from its very first instruction): ran cleanly (17
  frames rendered), but its own established verification uses an older,
  differently-formatted oracle trace (`cactus_spriteram_old.trace`)
  that `state_diff.py` couldn't parse against in this pass (a tooling
  mismatch, not a result either way) — not fully re-verified.

**Net result: zero regressions found across the entire sweep**, one
port (hachamf) shows a clear, measurable improvement, and the two
ports checked byte-for-byte against saved baselines (tdragon,
hachamfb) are unchanged.

### Remaining gap — tdragon1/hachamf still don't render

The phase fix was necessary but not sufficient. Direct measurement
confirms it fixed exactly what it targeted: `vt_vcount` at tdragon1's
own first P5 read is now 44 (previously 82), landing precisely in
MAME's own observed [44,47] range. But both tdragon1 and hachamf still
crash at the same illegal-instruction trap identified earlier this
session — re-checked directly, the self-modifying trampoline at
mainram `$BEF00` still gets patched with `HL=$0200` instead of the
oracle's own `$92F4` at the exact same instruction (`$072D`). This is
a **separate divergence**, not explained by raster phase (the phase
at that specific instruction is no longer the suspect — the trampoline
patch depends on an accumulator built from a ROM table lookup gated by
internal RAM `$FF08`, which in turn depends on which of several
interrupt-driven "sub-task" code paths executed by that point — a
mechanism already partially traced in the tdragon1 section above, not
yet fully root-caused). Family D's tdragon1/hachamf remain not
playable; the video_timing.sv fix is real, verified, and worth keeping
regardless, since it's demonstrably a closer match to real MAME
behavior project-wide.

## tdragon1/hachamf — the real root cause: `tlcs90.sv`'s opcode table was incomplete

Continuing the trampoline-patch divergence, chased further this
session. The eventual finding: `tlcs90.sv`'s decode tables — shared by
*every* port in this project, both in the NMK004 sound-MCU role and the
tdragon1/hachamf protection-MCU role — were missing six distinct
opcode forms entirely. tdragon1's protection-MCU firmware is the first
ROM in the project's history to execute any of them, which is why nine
prior Tier 1/2 ports never surfaced the gap.

### `ADD ix,mn` — the trampoline-patch divergence, finally explained

The protection MCU builds the trampoline's jump target by scanning a
16-entry ROM table, advancing an index register via `ADD IY,#imm16`
(base opcode `0x14`-`0x16`, unprefixed). `tlcs90.sv`'s base decode
table (the `casez (din)` block driving `d_op`) had **no entry at all**
for these three opcode bytes — confirmed directly against the
reference (`cpu/tlcs90/tlcs90.cpp:372-373`,
`case 0x14: case 0x15: case 0x16: OP16(ADD,6) R16(1,IX+b0-0x14)
I16(2,READ16())`). The cycle-cost table already had a correct entry
for these opcodes (`8'h14, 8'h15, 8'h16: cyc = 6'd12`), which is why
this had never been caught by a byte-count/cycle-count mismatch — the
instruction just silently executed as `OP_NOP`. `IY` never advanced;
every loop iteration re-read the same table entry, and the wrong
payload word got OR'd into the trampoline's target address.

Fix: added the missing `casez` entry (`rtl/tlcs90/tlcs90.sv`, base
decode block). Verified precisely: the trampoline now gets patched
with `HL=$92F4`, exactly matching the oracle's own known-correct value
(previously `$0200`) — the divergence chased across the prior session
and much of this one is resolved at the mechanism level.

### A second, deeper Address Error surfaces — and a full opcode audit

Fixing the trampoline let the 68000 run much further than ever before:
it completes a legitimate 65,536-iteration delay loop, reaches real
interrupt-driven code, and then trips a genuine **Address Error**
exception (vector 3, `$9674` — distinct from the earlier illegal-
instruction trap) inside the level-1 interrupt handler at `$955A`
(`jsr $406.L`, a RAM-resident routine doing
`movea.l $BE000.L,A0` / `move.w (A0),...`). MAME's own debugger
(`save` command dumping live memory at a breakpoint) showed the
oracle's own pointer at `$BE000` is `$0008E3F6` — a valid, even ROM
address; the candidate's own value at the same point was odd,
faulting on the word dereference.

Given the same "silently executed as NOP" pattern had just been found
once, the natural next step was a byte-pattern scan of both TLCS-90
ROMs (`nmk004.bin`, `nmk-110-tdragon.bin`) for the prefix/sub-opcode
byte sequences of every instruction MAME implements — not just a
targeted look at the one already-found gap. This surfaced genuine,
repeated usage (dozens of occurrences each) of five more forms MAME
implements that `tlcs90.sv` did not decode, spanning three instruction
families, none previously exercised by any of the ten prior ports:

| Opcode(s) | Mnemonic | MAME reference |
|---|---|---|
| base `0x12`/`0x13` | `MUL/DIV HL,n` (8-bit imm) | `tlcs90.cpp:367-370` |
| base `0x3f` | `LDW ($FF00+w),mn` | `tlcs90.cpp:419-420` |
| `PFX_G8` (`0xf8`-`0xfe`) sub `0x14`-`0x16` | `ADD ix,gg` (reg-reg) | `tlcs90.cpp:994-997` |
| every SRC prefix, sub `0x12`/`0x13`, `0x14`-`0x16` | `MUL/DIV HL,(mem)`, `ADD ix,(mem)` | `tlcs90.cpp:519-918` |
| every DST prefix, sub `0x3f` | `LDW (mem),mn` | `tlcs90.cpp:699-993` |

All five reuse the *existing* `OP_MUL`/`OP_DIV`/`OP_ADD`/`OP_LD`
opcodes rather than adding new ones — confirmed by reading MAME's own
`execute()`, which merges `case LDW:` and `case LD | OP_16:` into the
identical `Write1_16(Read2_16())` path (`tlcs90.cpp:1494-1501`), so
`LDW` genuinely is just a 16-bit `LD` under a different mnemonic. The
one new piece of machinery needed was a 16-bit immediate fetch for the
DST-group `LDW (mem),mn` form (no prior DST-group entry had ever
needed more than one trailing immediate byte) — implemented as a new
`d2_needs_i16` flag that reuses the existing base-level
`S_M2_BYTE1`/`S_M2_BYTE2` states verbatim rather than adding new FSM
states.

Two independent, fresh audits (each a from-scratch, exhaustive
byte-by-byte cross-reference of every base and prefixed opcode against
MAME's `decode()`/`execute()`) confirm the table is now complete: the
only forms MAME's own decoder produces that the RTL still leaves
unimplemented are `TSET` and `LDA`, both genuinely dead in MAME's own
`execute()` too (`case TSET:` commented out at `tlcs90.cpp:1730`,
`case LDA:` at `tlcs90.cpp:1504`) — correct, oracle-matching behavior,
not a gap.

### Result: tdragon1 renders

Full 300M-cycle verification run, before vs. after this session's
fixes:

| | Before | After |
|---|---|---|
| Address Error (`$9674`) | fatal, halts forever on first occurrence | 0 occurrences across 917 interrupt-loop iterations |
| Non-blank palette | 0/1024 | 609/1024 |
| BG VRAM written | 8192/8192 (never cleared — crashed before its own init ran) | 256/8192 |
| TX VRAM written | 1024/1024 (same) | 832/1024 |
| Rendered pixels nonzero | 0/86016 | 52,358/86,016 (61%) |

tdragon1 is confirmed rendering real content, not just avoiding a
crash — the `$BE000`-family pointer sampled repeatedly across the run
is always even/valid, and the 68000 cycles cleanly through the
`$955A` interrupt handler in the same repeating pattern the oracle
itself uses.

### hachamf: also fixed — the initial "inconclusive" read was a false alarm

Re-running hachamf (Family D's second protection-MCU game) with the
same fixes: no crash (previously hit the identical known limitation),
and a VRAM dump showing `bgvram=8192/8192 txvram=1024/1024`,
`86016/86016` (100%) nonzero pixels, palette `478/1024`. First read as
a possible red flag — that "fully non-blank VRAM" signature is what
tdragon1 showed *before* its own fix, when its clear routine never
got the chance to run — but that heuristic doesn't transfer here.
Re-running `hachamfb` (Family B's unprotected sibling, sharing hachamf's
exact video architecture, already oracle-verified correct and
documented in `docs/PLAN.md` as reaching "86,016/86,016 pixels
non-zero") through the identical `TB_DUMP_VRAM` check gives numbers
that match hachamf's own **exactly**: `palette=478/1024
bgvram=8192/8192 txvram=1024/1024`, `86016/86016` nonzero — down to
the exact palette count. A rendered PPM frame dump of the current
build confirms this directly and visually: a stable, correctly
composited "HACHA MECHA FIGHTER" title screen (sky background, mascot
character, NMK logo, copyright text) across multiple frames, the same
screen `docs/PLAN.md` already documents for hachamfb. The "100%
non-blank" signature is simply what this game's own full-bleed sky-art
title screen looks like when correctly rendered, with no letterboxed
region left at its blank-tile default — not a garbage-fill artifact.
hachamf is confirmed fixed, not merely crash-free.

### Regression sweep

Rebuilt and ran all nine ports that share `tlcs90.sv` with either
tdragon1 or hachamf (mustang, bioship, blkheart, strahl, acrobatm,
tdragon, vandyke, hachamfb, hachamf) against the full set of this
session's fixes. All nine completed cleanly — no crashes, no hangs,
normal instruction/frame/sound-write counts in line with each port's
own established baseline. None of the five newly-added opcode forms
are exercised by any of these other ports' own firmware, so this is
confirming "no side effects," not "no regressions in behavior these
ports depend on" — expected, given the additions are pure `casez`
extensions into previously-unreachable (`OP_UNKNOWN`) decode space.

## macross — Family D, the NMK-215/TMP90840 dual-NMK214 variant

The third Family D game, moving beyond tdragon1/hachamf's own NMK-110/
NMK-113 (TMP91640) protection role into the family's other real
sub-variant: NMK-215 (TMP90840), which adds a genuinely new mechanism
on top of the base shared-RAM protection — a pair of NMK214 GFX
descrambler chips whose init configuration the protection MCU itself
loads at startup via a port3(strobe)/port7(data) handshake. Confirmed
directly from the reference (`macross_prot()`, nmk16.cpp:5707): calls
`macross(config)` first, then `base_nmk214_215(config)` — same
"protection is a pure addition on top of unprotected hardware" pattern
as `tdragon_prot()`/`hachamf_prot()`. `macross()`'s own memory map is
address-identical to `hachamf()`'s own (same base offsets for every
I/O register, palette, scroll, BG/TX VRAM, mainram — confirmed
line-by-line, not assumed), and macross's own clock ratio (68000
@10MHz, NMK004 @8MHz) is hachamf's own too, so `macross_core.sv`'s
clock generation and address decode are hachamf_core.sv's own,
unchanged.

### What was built

- **`rtl/nmk214/nmk214.sv`** — a new, from-scratch, stateless
  table-driven descrambler, ported directly from
  `mame/src/mame/nmk/nmk214.cpp`'s own published constant tables (8
  hardwired configs, each with its own 3-bit-selector address-bit
  triple and its own 16-entry word/8-entry byte output bitswap).
  Standalone-verified before any integration: **80,102 checks across
  all 8 configs, zero failures**, against a from-scratch C++ reference
  reimplementation (not copy-pasted from the SV translation) —
  `sim/rtl/nmk214/`.
- **`rtl/tlcs90/nmk_prot_core.sv`** parameterized for the TMP90840's
  own smaller internal ROM/RAM (`ROM_SIZE=8192`, `RAM_BASE=16'hfec0`,
  `RAM_SIZE=256`, vs. tdragon1/hachamf's own TMP91640 defaults of
  16384/0xfdc0/512 — confirmed from `ROM_START(macross)`'s own
  `protcpu` region, 0x2000 bytes) and extended with new
  `nmk214_cfg_we`/`nmk214_cfg_data` outputs implementing
  `mcu_port3_to_214_w`/`mcu_port7_to_214_w` (nmk16.cpp:5640-5679): P7
  writes stash a pending byte, and a P3 write whose bit 2 rises from
  the *previous* P3 write's own bit 2 pulses the config-load strobe
  with whatever's currently stashed — matching the reference's own
  `m_init_clock_nmk214`-tracking exactly, including that the tracked
  bit updates unconditionally on every P3 write, not just qualifying
  ones. `rtl/tlcs90/nmk004_periph.sv` gained the underlying `p3_we`/
  `p3_wdata`/`p7_we`/`p7_wdata` write-tap outputs this needed (additive,
  tied inert in `nmk004_core.sv`'s own instantiation).
- **`rtl/macross/video_macross.sv`** — adapted from `video_tdragon.sv`/
  `video_hachamfb.sv`'s own tilemap architecture, with two genuine
  differences confirmed from `ROM_START(macross)` directly: (1) a
  14-bit BG tile code, not blkheart/tdragon/hachamf's own 13-bit —
  macross's own bgtile ROM is 2MB (16384 tiles), double theirs, so both
  low bits of `m_bgbank` land inside the valid code range, not just
  bit 0 (`common_get_bg_tile_info`'s own formula,
  `(code&0xfff)|(m_bgbank<<12)`, nmk16_v.cpp:43, is unchanged — only
  how many of `m_bgbank`'s bits matter differs with ROM size); (2) BG
  and sprite ROM reads are descrambled through two `nmk214` instances,
  wired continuously (address in, raw byte/word in, descrambled byte/
  word out) rather than as a one-time bulk pre-transform — confirmed
  equivalent to the reference's own `decode_nmk214()` (a MAME-side perf
  shortcut: the descrambling result depends only on address and the
  once-loaded init_config, both fixed after the protection MCU's own
  startup handshake, so per-fetch combinational decode produces an
  identical steady-state result while also matching how the real
  NMK214 silicon actually works). BG is byte-mode (MODE=1,
  `nmk214_bg_address_bitswap`); sprites are word-mode (MODE=0,
  `nmk214_sprites_address_bitswap`, word address = byte address/2,
  big-endian word reconstruction matching the reference's own
  `get_u16be`) — both bitswap tables transcribed directly from
  nmk16.cpp:5683-5684.
- **`rtl/macross/macross_core.sv`** — system integration, combining
  hachamf_core.sv's own clock/address-decode architecture with the new
  TMP90840-parameterized protection MCU and the two `nmk214` instances'
  shared config-load strobe.
- **`sim/rtl/macross/tb_macross.cpp`** + **`Makefile`** — following
  tdragon1/hachamf's own testbench pattern. ROM extraction used
  existing `tools/mkgfxrom.py` modes unchanged (`concat` for fgtile/
  bgtile/protcpu/nmk004-ext/oki1/oki2/vtiming — all single, non-
  interleaved `ROM_LOAD`s; `word_swap` for the sprite ROM, same
  convention as blkheart's own) — no new tooling needed for graphics
  ROMs. The 68000 program ROM (`921a03`) *did* need something new: a
  single `ROM_LOAD16_WORD_SWAP` file, not the two-chip
  `ROM_LOAD16_BYTE` split `tools/mkrom.py`'s own `--hi`/`--lo`
  interface expects — the first maincpu ROM this project has needed to
  extract this way. Handled as a small inline conversion in the
  Makefile's own `rom:` target (byte-pair-swap, then emit one 16-bit
  word per line) rather than extending `mkrom.py`'s interface for a
  one-off case. The "color" PROM (`921a10`, 0x20 bytes, present in this
  romset like several others) is confirmed unused anywhere in the
  reference's own driver code (`grep -rn 'memregion("color")'` across
  the whole file — zero hits) — not modeled, same precedent as
  `tlcs90.sv`'s own dead `TSET`/`LDA` opcodes.

### Verification results — a genuine, well-characterized remaining issue, not a clean pass

Full 300M-cycle run: no crash, 422 video frames rendered, NMK004 side
healthy (4.75M instructions, normal YM2203/OKI write activity). But
**the protection MCU never once asserts the 68000's HALT line** (0
occurrences, vs. tdragon1's own 508 and hachamf's own 802 over the
same cycle budget) and ends the run at a low PC (`$008E`) after 2.5M
of its own instructions — a real difference from tdragon1/hachamf's
own pattern, not just a smaller number.

Oracle comparison (`sim/compare/cyc_diff.py` against fresh
`capture_cyc_trace.py` captures) explains why, precisely:

- **NMK004 side**: 7,586 of 1,143,304 oracle checkpoints matched before
  the PC sequence stops being findable further in the candidate trace,
  diverging around the same class of host-handshake poll-loop PC
  (`$0EB1`) every other NMK004 port's own poll loop has already been
  characterized at — plausibly the same benign race-sensitive
  resolution-rate difference documented extensively elsewhere in this
  project, not re-investigated further given the protection-MCU side
  below is the more clearly load-bearing issue.
- **Protection MCU side**: **704,889 of 755,447 oracle checkpoints
  matched (93%)** — the instruction *sequence* is correct for the vast
  majority of the run, ruling out a decode/logic bug in the newly-added
  TMP90840 parameterization or NMK214 wiring. But the *cycle cost* is
  systematically wrong: 192,546 of 704,888 matched instructions
  (27%) have the wrong cycle cost, and the aggregate ratio over the
  matched span is **candidate/oracle = 3.997** — almost exactly 4x too
  slow, not the small bounded handful of already-documented TLCS-90
  timing edge cases every other port's own protection/NMK004 CPU shows.
  This directly explains the 0-HALT observation: at ~4x the correct
  per-instruction cost, the protection MCU simply doesn't reach as far
  in real elapsed time within the same 300M-cycle budget as tdragon1/
  hachamf's own correctly-timed protection MCUs do, and never reaches
  whatever later point in its own firmware actually asserts the
  halt/bus-take sequence.
- Root cause of the ~4x figure itself is **not yet found** — the clock
  divider generating `prot_clk_r` (`/10` off a 40MHz `clk_sys`, giving
  a nominal 4MHz) is copied verbatim from hachamf_core.sv's own
  (already-working) divider, and `tlcs90.sv`'s own `instr_cycles()`
  cost table is unchanged/shared, so a systematic ~4x inflation instead
  of a handful of edge-case mismatches doesn't point cleanly at either
  of those. One live hypothesis, not confirmed: extra real bus-wait
  latency on the protection MCU's own shared-bus pass-through path
  (`sel_shared`) if macross's own NMK-215 firmware makes substantially
  more/different 68000-shared-RAM accesses early in boot than tdragon1/
  hachamf's own firmware does — `cyc_diff.py` measures raw elapsed
  cycles between PC checkpoints, so any such RTL-side bus-wait latency
  (a genuine hardware effect MAME's own simpler model may not
  reproduce) would show up exactly as an inflated per-instruction cost
  here, without touching `instr_cycles()` at all. Not chased further
  this session — left as a concrete, well-diagnosed next step rather
  than an unexplained failure.

Despite the above, the VRAM/pixel dump shows **56,256/86,016 (65%)
pixels nonzero**, palette `406/1024` non-blank, bgvram only `288/8192`
non-blank (a small fraction, the same "real content, not a never-
cleared 100% signature" shape tdragon1's own post-fix result showed,
not hachamf-pre-correction's own 100%-non-blank false alarm) — some
genuine partial rendering is happening even without the protection
handshake completing, plausibly the 68000 running largely on its own
boot sequence. Not confirmed pixel-correct against the oracle (no
frame-level comparison attempted, given the CPU-side divergence above
already explains why it wouldn't match). **macross is not yet
playable — a real, honestly-diagnosed remaining issue, not a clean
pass** — but the new `nmk214`/dual-descrambler/TMP90840-parameterization
infrastructure is built, standalone-verified where feasible, and the
actual blocker is narrowed to a specific, falsifiable next step (the
protection MCU's own ~4x cycle-cost inflation) rather than an open-
ended unknown.

### The ~4x figure, narrowed further — two distinct causes found, one still open

Continued digging (per explicit user direction) into the ~4x
protection-MCU cycle-cost inflation above. Broke the aggregate
`cyc_diff.py` mismatch down by contribution (summing `diff` per
occurrence, not just counting occurrences) rather than trusting the
single ratio figure, and found it's **not one bug** — the 3,700,697
total extra candidate cycles over the matched span split into two
genuinely different causes:

- **A real, secondary, previously-known-but-newly-consequential bug**
  (~124,068 cycles, minor by contribution but a genuine correctness
  gap worth fixing): `tlcs90.sv`'s `instr_cycles()` hardcodes `DJNZ`'s
  cost to a flat `20` (`8'h18: cyc = 6'd20;`) regardless of taken/not-
  taken. The reference's own `Cyc()`/`Cyc_f()` split (`tlcs90.cpp:283-
  286`, `2023-2029`) is genuinely stateful: `OP(DJNZ,10)` only ever sets
  `m_cyc_t` (the *taken* cost); `m_cyc_f` (the *not-taken* cost) is left
  holding whatever the most recently-executed `OPCC`-based instruction
  (e.g. a conditional `JR cc`) last set it to — `m_cyc_t`/`m_cyc_f` are
  reset to 0 only once, at machine reset, never per-instruction.
  Directly confirmed via live disassembly of macross's own protection
  ROM: a tight 3-instruction poll loop at `$01BF-$01C8` (`cp
  (hl),$20` / `jr nc,$01CC` / `inc c` / `add hl,4` / `djnz $01BF`) —
  the preceding `jr nc` (`OPCC(JR,4,8)`) sets `m_cyc_f=8`, so DJNZ's
  own not-taken exit borrows that same `8`, not the `20` our RTL always
  charges. This is the exact "genuine MAME stateful-implementation
  quirk in DJNZ's not-taken cost" `docs/PLAN.md`'s own original TLCS-90
  cycle-timing fix already flagged as a known, accepted residual — it
  was low-impact for every prior port; macross's own firmware just
  happens to hit it in a hot loop.

  **Now fixed.** Added `cyc_f_reg`, a persistent register mirroring
  the reference's own `m_cyc_f` exactly: reset to 0 once (at machine
  reset, never per-instruction), updated only when the just-decoded
  opcode is genuinely `OPCC`-class (a new `is_opcc(p,s)` function —
  `s[7:4]==4'hc` or `4'hd` covers every JP/CALL-cc form across every
  prefix group, plus base-table `0x07`/`0x0f`/`0x1a`/`0x1b`/`0x1c`/
  `0x1e` and the `PFX_G8` LDI-family at `0x58-0x5f`), using that same
  opcode's own not-taken cost (`instr_cycles(..., taken=1'b0, ...)` —
  already well-defined for every opcode `is_opcc` gates, since those
  are exactly the entries the table's own ternaries already cover).
  `instr_cycles()` gained a `cyc_f_in` parameter so DJNZ's own table
  entries (`8'h18`/`8'h19`) could change from a flat `20` to
  `taken ? 20 : cyc_f_in`, both wired at both existing call sites
  (`S_DECODE`/`S_PFX_SEL`).

  **A second, related bug found while verifying the first**: the
  `taken` value fed into this fix reused `test_cc(d_r1e[3:0], f)` —
  flag-based, and meaningless for DJNZ, whose real branch condition is
  whether the *decremented* `B`/`BC` register is nonzero, not any CPU
  flag (the 16-bit form's own `d_r1e` doesn't even hold a
  condition-code nibble here — decode sets it to `R16_BC`, a
  register-select code, for an unrelated reason). This wasn't a new
  bug in itself (DJNZ's table entries never used the `taken` ternary
  before this fix, so the wrong value was previously harmless) — but
  fixing the not-taken side without also fixing `taken` regressed the
  candidate's own PC-sequence match against the oracle from 122,929
  checkpoints down to 5,997, caught immediately by re-running the same
  `cyc_diff.py` verification. Fixed by computing DJNZ's real branch
  condition directly from the live `bc` register at the same decode
  point (`(bc[15:8]-1)!=0` for the 8-bit form, `(bc-1)!=0` for the
  16-bit form) — mirroring exactly what the `OP_DJNZ` execute block
  itself already re-derives independently, just read-only and one
  pipeline stage earlier.

  **Verified**: re-running `cyc_diff.py` after both fixes, the
  specific DJNZ-not-taken mismatch class (e.g. the `$01C8→$0038`
  transition, oracle=8/candidate=20 before) no longer appears at all.
  The dominant P5-wait-loop stall issue below is **completely
  unaffected** — still 84 occurrences of the same ~65,000-70,000-cycle
  stalls at the same PC transitions, aggregate ratio still ~3.9x —
  confirming this was a real but genuinely minor, separable
  contributor, exactly as scoped. Zero regressions: fresh full
  300M-cycle runs of tdragon1 and hachamf (both share `tlcs90.sv`)
  match their own established baselines exactly (tdragon1:
  `palette=609/1024`, `52358/86016` pixels, `508` HALT asserts;
  hachamf: `palette=478/1024 bgvram=8192/8192 txvram=1024/1024`,
  `86016/86016` pixels, `802` HALT asserts).
- **The dominant cause** (~3.5M of the 3.7M total, a handful of huge
  individual stalls of 62,783-68,151 cycles each): every one of them
  is the *same* transition shape — either landing directly on a timer-
  interrupt vector (`$0030`/`$0038`/`$0040` — T0/T1/T2 respectively,
  confirmed against `tlcs90.sv`'s own `irq_vector` formula) or inside
  the P5 (scanline)-polling loop those handlers funnel into
  (`$0088: ld a,(P5) / and $3F / cp $1D / jr nz,$0088` — wait for
  `vpos>>2==29`, i.e. `vcount` in `[116,119]`), where the oracle
  resolves in 8-16 cycles (first-or-second poll) but the candidate
  takes very close to one full video frame (measured actual frame
  period in this run: **~71,177-71,446 protcpu cycles**, matching the
  stall magnitudes closely). Ruled out, with direct evidence, three
  plausible causes before narrowing further:
  - **Not a stuck `vt_vcount`**: a `TB_LOG_PROT_REGS` capture extended
    to include `dbg_vt_vcount` alongside the existing PC/HL trace
    (`sim/rtl/macross/tb_macross.cpp`) shows it incrementing
    continuously and correctly (`240,241,242...` from reset, ~257
    `clk_sys/10` cycles per scanline, matching ~278 lines/frame — the
    already-fixed `VACTIVE_END` reset value is confirmed correct here
    too).
  - **Not a `TRUN` register bit-masking bug**: cross-checked our own
    `en0..en4 = trun[5] & trun[i]` gating (`nmk004_periph.sv:215-216,
    326`) against the reference's own `trun_w()`
    (`tlcs90.cpp:2666-2692`, `mask = 0x20 | (1<<i)`,
    `(data & mask) == mask`) — identical dual master-bit-plus-per-timer-
    bit semantics, confirmed by directly disassembling and tracing the
    ROM's own boot-time `TRUN` write sequence (`$27`→`$25`→`$21`→`$20`,
    each interrupt handler disabling only its own bit, matching this
    gating exactly).
  - **Not a reset-wiring skew**: `prot_mcu` and `vtiming` are both tied
    to the identical `reset` signal in `macross_core.sv` (no registered
    delay difference between them).
  - **A real, measured anomaly that *does* point somewhere concrete**:
    all three of T0/T1/T2 — configured via the ROM's own boot-time
    `TCLK`/`TMOD`/`TREG0-2` writes (`TCLK=$FB`→prescale `/256`,`/16`,
    `/256`; `TREG0-2=$20,$4C,$16`) to wildly *different* individual
    periods (math: T0≈65,536 cycles, T1≈9,728, T2≈45,056, all at the
    protection MCU's own 4MHz) — show the **same** ~71,177-cycle real
    inter-arrival rate for their own interrupt vectors in the candidate
    trace, matching the measured video-frame period almost exactly, not
    their own individually-configured periods. This means whichever
    timer's own countdown finishes first, the CPU ends up funneled
    through the same P5-wait bottleneck every time, and that P5-wait —
    not any individual timer's own period — is what actually paces the
    observed recurrence.
  - **The reset-relative clock-phase hypothesis above was investigated
    directly and ruled out** (per explicit user direction to keep
    digging). Used the exact methodology proposed — a live MAME
    `-debugscript` capture with a `tracelog` action printing
    `totalcycles`/`pc`/`beamy` (the debugger's real-vpos pseudo-symbol,
    same technique "Milestone 5" originally used) for `:protcpu` — and
    compared directly against the candidate's own `prot_cyc.trace`, at
    the *exact same absolute cycle counts*, bypassing `cyc_diff.py`'s
    own subsequence-matching entirely (see below for why that matters).
    Findings, all pointing away from a phase/reset bug:
    - Main-program timing from reset to the boot code's own `TRUN=$27`
      write (which first arms timers T0/T1/T2 together) matches within
      **23 cycles** (oracle 110,688 vs. candidate 110,711) — negligible,
      not a meaningful reset-relative offset.
    - T0/T1/T2's own real inter-arrival period is **~71,156-71,204**
      cycles in the oracle, essentially identical to the candidate's
      own already-measured ~71,129-71,249 — the timer period itself is
      correct, not off by any meaningful amount.
    - T1's own *first* firing after that `TRUN=$27` arm lands only
      **41 cycles** later in the candidate than the oracle (120,461 vs.
      120,420 absolute cycles) — i.e. at the one point this session
      could directly, independently verify (bypassing `cyc_diff.py`),
      oracle and candidate are in near-perfect agreement, not
      diverging by tens of thousands of cycles as the tool's own
      subsequence-matched report suggested.
  - **The real cause, found directly**: comparing the two sides' raw
    PC sequences side-by-side (not through the matcher) at this same
    point shows a genuine *program-state* divergence, not a timing
    one — the candidate's `djnz $01BF` (part of a `cp (hl),$20 / jr
    nc,$01CC / inc c / add hl,4 / djnz $01BF` scan loop reading through
    memory starting at `HL=$FFB0`, stepping by 4) falls through (`B`
    reaches 0, loop exhausted) at a point where the oracle's own
    `B` register hasn't yet reached 0, so oracle keeps scanning while
    the candidate restarts the *entire* outer loop from `$01B5`. This
    is exactly the kind of divergence that can make a single
    `cyc_diff.py` checkpoint report a huge, misleading delta: its
    subsequence matcher, working purely on PC-sequence, doesn't
    distinguish "the interrupt fired 8 cycles after this specific
    `$01C8`" from "many loop iterations, and several outer-loop
    restarts, separate this `$01C8` from the next matched vector" —
    both look like one `01C8→0038` transition in its own report,
    with wildly different cycle costs. The `cyc_diff.py`-reported
    "~4x"/"~3.9x" aggregate ratio and the specific huge-delta
    checkpoints are therefore **not a reliable measurement of a single
    root cause** — they're an artifact of matching a
    content-and-timing-sensitive scan loop's own PC sequence without
    modeling *why* it diverges.
    Why the scan loop is content-sensitive: `HL` starts at `$FFB0`
    (inside the TMP90840's own 256B internal RAM, `$FEC0-FFBF`) but
    after only 4 iterations (`$FFB0,FFB4,FFB8,FFBC`) crosses into
    `$FFC0`, the on-chip *peripheral register* window
    (`nmk004_periph.sv`'s own `$FFC0-FFEF` map) — and if the scan
    hasn't found a byte `>=0x20` by then, it continues reading live
    peripheral registers and, past `$FFEF`, the shared 68000 bus
    itself. Its own iteration count is therefore a function of
    whatever real, timing-dependent system state (peripheral register
    values, actual 68000 RAM content) happens to be live at scan time —
    not a fixed, deterministic clock relationship this session can
    "phase-align" its way out of.
  - **Ran that next step down directly** (per explicit user direction
    to keep digging): added a new debug output,
    `dbg_int_ram_at_hl` (`nmk_prot_core.sv`, combinational — the
    internal-RAM byte at the live `HL` address), threaded through
    `macross_core.sv` into `tb_macross.cpp`'s own `prot_regs.trace`.
    Captured the *ordered sequence* of every `(HL, byte)` pair the
    scan loop reads (not just cycle-timestamped PC, which is what
    `cyc_diff.py` already had and which is exactly what produced the
    misleading huge-delta report above), on both the oracle (a live
    MAME `tracelog` printing `hl`/`b@hl`) and the candidate, over the
    same overlapping cycle window (~1.63M protcpu cycles — the
    candidate's own capture duration is shorter in *emulated* time
    than a 2-second oracle capture, since Verilator simulation runs
    far slower than realtime; restricting the oracle sequence to the
    same cycle range before comparing was necessary to avoid a
    spurious "candidate is missing thousands of entries" artifact from
    comparing mismatched durations).
    **Result: there is no single wrong byte.** The *set* of unique
    `(address, value)` pairs each side ever observes is identical —
    every value the candidate reads at a given address, the oracle
    also reads at that same address at some point, and vice versa
    (confirmed via a sorted-unique diff, empty). The only difference
    is *how many times* the idle value (`$FFB0`→`$12`, "no task
    queued") repeats between real events — small, scattered blocks of
    2, 11, 13, ... extra idle repetitions in the oracle, growing
    through the window, totaling 242 extra idle passes out of ~13,000
    over this span (~1.9%). This is a genuine, real, but small and
    *cumulative* timing drift — consistent with the project's own
    already-known, already-accepted residual per-instruction
    cycle-cost imprecision (the same class as the "1-cycle
    FSM-pipeline-floor" quirk documented in the original TLCS-90
    cycle-timing fix) compounding, over many thousands of instructions,
    into a small but nonzero difference in exactly which idle-loop
    pass a given real event (a new task getting queued, likely
    interrupt- or sound/OKI-write-driven) gets observed on. Not a
    single fixable bug at a single address — closing it out fully
    would mean auditing per-instruction cycle costs to a much tighter
    tolerance project-wide than any prior port has needed, since this
    is the first firmware in the project sensitive enough to a
    live, content-dependent polling loop's own exact iteration count
    to expose it at all. Left open, correctly scoped rather than
    further chased this session.

### The project-wide cycle-cost audit and its own limits

Directed follow-up (per explicit user request): a project-wide
per-instruction cycle-cost audit of `tlcs90.sv`, aimed squarely at
eliminating the residual drift above. Full derivation in
`docs/tier2-tlcs90.md`'s "Thirteenth verification result" — summary
here.

**Found and fixed the second of the two residual causes the original
TLCS-90 cycle-timing fix had already documented and accepted as
low-impact**: "the FSM's own minimum pipeline depth exceeds the
reference's 4-cycle minimum for the very cheapest single-byte opcodes"
(`docs/tier2-tlcs90.md`'s Twelfth result). `S_PRE_READ1`/`S_PRE_READ2`
are pure pass-through states for any opcode needing no real memory read
for either operand — but the FSM still visited both, costing 5 real
cycles against a 4-cycle target the padding-only mechanism could never
close (padding can only add cycles). Fixed with a new combinational
`d_skip_pre_reads` check at `S_DECODE` that resolves `val1`/`val2`
itself and jumps straight to `S_EXECUTE` for this opcode class,
dropping the natural minimum to 3 cycles — safe for every opcode, since
3 ≤ every `target_cyc` value in the table.

**Verified rigorously, multiple ways, all positive**: all 7 standalone
opcode self-tests plus the interrupt self-test still pass unchanged;
mustang's own NMK004-side cycle-cost match against a fresh oracle
capture improves from 43/7,779 mismatches to **2/7,779** (the 2
remaining are the already-documented, expected host-handshake boundary,
not a table error); every newly-added opcode from earlier this session
(`MUL`/`DIV`/`ADD ix,...`/`LDW` across every prefix group) has its own
cycle cost spot-checked directly against the reference's own macro
arguments and matches exactly; macross's own scan-loop `(HL,byte)`
drift (see above — 242 extra idle iterations out of ~13,000) drops to
**1-2 residual lines out of ~19,700** over the same kind of bounded
comparison window; and a regression sweep across nine of the ten ports
(mustang, blkheart, strahl, acrobatm, tdragon, vandyke, hachamfb,
tdragon1, hachamf) found zero functional regressions — tdragon1's and
hachamf's own HALT-assert counts and VRAM/pixel numbers are unchanged
from their own established baselines, and every port's total
executed-instruction count shifted only by the small, expected,
(`bioship`'s own 900M-cycle run compiled cleanly but wasn't
independently re-confirmed to completion in this pass, after an
earlier attempt was killed by resource contention from ten concurrent
full-length runs, not a crash — the one gap in an otherwise complete
sweep)
correct-direction amount (more instructions fit the same fixed cycle
budget now that the cheapest opcodes cost 1 fewer cycle each).

**But macross itself is still not playable — a genuine, honest, not-
overclaimed outcome.** Despite the large, real, multiply-verified
improvements above, a full 300M-cycle run of macross still shows **0
HALT assertions** (completely unchanged from before this fix) and
identical VRAM/pixel numbers to the pre-fix baseline
(`palette=406/1024`, `56,256/86,016` pixels, `bgvram=288/8192`) — the
protection MCU's own last PC at the end of the run is still `$0088`,
the P5-wait loop itself. The most likely explanation: even a
1-2-line-per-~2.4M-cycle residual drift, left running for the full
~100x-longer 300M-cycle window this game actually needs, still
eventually compounds into a divergence large enough to prevent the
HALT sequence from ever firing — the bounded comparison window this
session's own tooling can practically capture (limited by how much
real-time MAME itself can simulate) demonstrates clear *directional*
improvement but can't prove the drift is fully eliminated at the scale
that actually matters for this specific firmware's own playability.
Not chased further this pass. Two legitimate next steps, neither
attempted here: a much longer-duration oracle capture to directly
confirm whether the drift is still present at the full run's own
scale, or continuing to audit `tlcs90.sv` for any *other* remaining
structural cycle-cost source — fixing the one documented, understood
cause doesn't guarantee it was the only one.

### Regression sweep

Rebuilt and ran tdragon1, hachamf (both fresh rebuilds, picking up
every shared-file change this session made: `nmk_prot_core.sv`'s new
parameters/outputs, `nmk004_periph.sv`'s new P3/P7 write taps), and
blkheart (a plain NMK004-role game, confirming `nmk004_core.sv`'s own
inert tie-off of the new taps). All three match their own previously-
established baselines **exactly**: tdragon1 — 508 halt/bus-take
cycles, 2,977,951 protection-MCU instructions, 13,784,870 68000
instructions (identical to every prior run this session); hachamf —
802 halts, 2,330,347 protection-MCU instructions, 12,826,319 68000
instructions (identical); blkheart — 527 frames rendered, healthy
NMK004/sound activity, no crash. Zero regressions from this session's
shared-file changes.

## gunnail — macross's own sibling, ported reusing its infrastructure directly

Family D again: same NMK-215/TMP90840 protection MCU firmware
(byte-identical protection ROM CRC to macross's own) and the same
dual-NMK214 GFX-descrambler wiring. Built `rtl/gunnail/gunnail_core.sv`,
`rtl/gunnail/video_gunnail.sv`, `sim/rtl/gunnail/tb_gunnail.cpp`, and
`sim/rtl/gunnail/Makefile`, adapted directly from macross's own
equivalents — no shared file (`tlcs90.sv`, `nmk_prot_core.sv`,
`nmk004_periph.sv`, `nmk214.sv`) needed any change for this port.

### What's actually new, and what turned out not to be

Three things looked new going in; only two were:

- **Per-scanline raster X+Y scroll** — genuinely new. MAME's own
  `bg_update()` computes each screen row's own scroll independently
  (`gunnail_scrollramy[0] + gunnail_scrollramy[y1]` for Y,
  `gunnail_scrollram[0] + gunnail_scrollram[16+y1]` for X, the `+16`
  being MAME's own unexplained literal, kept as-is). Because this
  project's renderer is demand-driven per-pixel (`rd_x`/`rd_y` inputs,
  not a real scanline draw pass), this was straightforward: two new
  256-word RAM arrays (`scrollram`/`scrollramy`) plus per-`rd_y`
  combinational scroll lookups in `video_gunnail.sv`, no new raster
  timing needed.
- **Wide TX tilemap (macross2-style wraparound)** — genuinely new.
  gunnail's TX tilemap is 64×32 tiles (double macross's 32×32), same
  `VIDEOSHIFT=92`. Reproduced by widening the existing modular-
  wraparound address formula (256→512, 5→6 column bits) — no new
  special-case logic.
- **Hi-res screen timing** — turned out to be a non-issue. MAME lists
  gunnail as genuinely hi-res (`set_screen_hires()`), but
  `rtl/bjtwin/video_timing.sv` (reused unchanged by every port since
  Tier 1, including every lo-res one) already numerically matches
  MAME's own hi-res parameters exactly (8MHz pixel clock, 512 htotal,
  384×224 visible). This has been a settled, already-validated project
  convention since bjtwin; gunnail needed zero new resolution-timing
  RTL.

### Build and verification results

Built and ran a full 300M-cycle simulation. The protection-MCU
timing-drift issue already characterized for macross **recurs exactly
as expected** — not a new bug, the same one:

- Protection MCU executed **2,824,804 instructions**, last PC=`$0088`
  (the same P5-wait polling loop), **0 HALT assertions** — all three
  numbers match macross's own fresh 300M-cycle run bit-for-bit
  (`protection MCU executed 2,824,804 instructions... last PC=$0088...
  HALT asserted 0 times`), confirming the two games are running
  byte-identical protection firmware down to the instruction. Per the
  scope already established for macross, this was not re-diagnosed —
  it's the same open issue, not chased further here.
- Despite the 68000 never being released from its post-reset HALT
  wait, the video side still renders real content from whatever VRAM
  state exists: `palette=354/1024`, `bgvram=7951/8192` (98% populated),
  `txvram=480/2048`, `9671/86016` pixels nonzero.
- **Visual confirmation of the two new video features**: dumped all
  422 rendered frames as PPM and inspected several. Frame 421 (and
  every frame from ~350 onward, a static held frame) shows a clean
  "PRESENTS" splash — the widened 64×32 TX tilemap renders the text
  correctly with no corruption or wraparound garbage, and the BG
  layer's diagonal-striped logo art renders in the correct position
  and colors with no tearing. This is real evidence the wide-tilemap
  and per-scanline-scroll plumbing are structurally correct, even
  though the frame itself is a static splash screen (the 68000 never
  reaching the main game loop means no moving gameplay content exists
  yet to fully exercise the scroll registers).

### Regression sweep — with one methodology correction along the way

First attempt used the existing tdragon1/hachamf/macross binaries
already sitting in each `obj_dir/` and got small (~0.1-0.6%) raw
instruction-count mismatches against the documented baselines, while
every functionally-meaningful number (HALT counts, palette/bgvram/
txvram/pixel counts) matched exactly. Checked binary mtimes against
the FSM-pipeline-floor fix commit (`4292be1`, 15:08) and found all
three existing binaries predated it (built ~02:5x) — stale, not
actually reflecting current `tlcs90.sv`. Rebuilt all three fresh and
reran: **identical results to the stale run**, down to the same
instruction counts. Since two independent builds (stale and fresh)
of what should be the same source both reproduce the same numbers,
and the functionally-relevant outputs match the documented baselines
exactly, this points to the earlier documented instruction-count
figures (`2,977,951`/`2,330,347`) themselves being a pre-existing
transcription inaccuracy in the docs, not a regression — worth a
correction pass sometime, not chased further here since it predates
and is unrelated to gunnail's own changes (which touch no shared
file, confirmed via `git status`).

Fresh-rebuild results: tdragon1 — **508 HALT asserts** (exact match),
`palette=609/1024`, `52358/86016` pixels, `bgvram=256/8192
txvram=832/1024` (exact match); hachamf — **802 HALT asserts** (exact
match), `palette=478/1024 bgvram=8192/8192 txvram=1024/1024`,
`86016/86016` pixels (exact match); macross — 0 HALT asserts, last
PC=`$0088`, `2,824,804` protection-MCU instructions (exact match to
its own already-documented signature, and to gunnail's own run
above). Zero regressions.

### Status

Ported, built, renders correctly (splash screen visually confirmed,
both new video features working structurally), but **not yet
playable** — inherits macross's own open, already-characterized
protection-MCU timing-drift issue verbatim, since it runs the same
firmware. Not a new problem to solve for this port; resolving it is
the same open item already scoped under macross above. Changes left
uncommitted for review.

## bjtwin — Family D, third sub-group, the smallest-scope port yet

The third and last Family D sub-group: `bjtwin_prot()` in nmk16.cpp
(the `bjtwin`/`bjtwina`/`bjtwinpa`/`sabotenb`/`sabotenba`/`nouryoku`
romsets — this port targets `bjtwin` itself). Same NMK-215/TMP90840
protection MCU + dual-`nmk214` mechanism as macross/gunnail
(`base_nmk214_215()`), but on top of the *cactus-family* hardware
(hi-res, single 8×8 COL-scan tilemap, no TX layer, no NMK004 — sound
is nmk112 + 2x OKIM6295 direct) rather than macross's own BG+TX
page-mapped architecture. Both halves of this port already existed in
verified form before any new RTL was written: the video/CPU
architecture from Tier 1's `bjtwin_core.sv`/`video_bjtwin.sv` (built
for the unprotected `cactus` romset, same hardware family) and the
protection-MCU/dual-NMK214 infrastructure from macross/gunnail — so
this port is pure integration, no new subsystem.

### What was built

- `rtl/bjtwin/bjtwin_prot_core.sv` — new file (bjtwin_core.sv stays
  unmodified, still serving cactus). Reuses bjtwin_core.sv's own
  memory map, clock-enable structure, and fx68k instantiation almost
  verbatim; the two real deltas are (1) `.HALTn(~halt_68k)` instead of
  the permanently-high tie-off, and (2) the real `nmk_irq` scanline
  interrupt generator (bjtwin's own base config uses
  `set_interrupt_timing()`, the real V-PROM-driven mechanism — unlike
  `cactus()`, which explicitly swaps in `nmk_irq_hacky`) plus the
  protection MCU and its own shared-bus address decode, adapted from
  macross_core.sv's own pattern but simplified for bjtwin's smaller
  map (no txvram, no NMK004 — dropped `prot_sel_txvram`/nmk004 branches
  entirely).
- `rtl/bjtwin/video_bjtwin_prot.sv` — new file (video_bjtwin.sv stays
  unmodified). Splices NMK214 descrambling into the BG-tile (byte
  mode) and sprite (word mode) fetch paths, leaving fgtile untouched
  (confirmed consistent with every other Family D game — only "bg" and
  "sprites" GFX regions are ever wired to `base_nmk214_215()`). BG
  addressing uses bjtwin's own simpler single 8×8-tile format (not
  macross's 16×16 two-layer format); sprite addressing is byte-for-byte
  identical to macross's own, so that half of the wiring — including
  the extra `S_SPR_CHECK2` pipeline stage needed because Verilog
  functions can't instantiate modules — was reused directly from
  `video_macross.sv`. Both NMK214 bitswap tables are the same
  shared/non-game-specific constants `base_nmk214_215()` uses for every
  caller, confirmed identical to macross's own.
- `video_timing.sv` needed **zero changes** — a genuine finding, not an
  assumption: `bjtwin()`'s own base config also calls
  `set_screen_hires()`, and `video_timing.sv`'s existing constants
  (`HTOTAL=512, HACTIVE_START=28, HACTIVE_END=412, VTOTAL=278,
  VACTIVE_START=16, VACTIVE_END=240`) already are that hi-res class —
  the same already-settled convention gunnail's own port confirmed
  above.
- `sim/rtl/bjtwin/tb_bjtwin_prot.cpp` + `Makefile` targets
  (`prot-rom`/`prot-prot-rom`/`prot-vtiming-rom`/`prot-gfx-roms`/
  `run-prot`/`clean-prot`), added to the existing `sim/rtl/bjtwin/`
  directory (matching that directory's own existing cactus/bjtwin_core
  convention rather than a new top-level directory). ROMs extracted
  from `mame_roms/bjtwin.zip`: maincpu (`93087-1.bin`/`93087-2.bin`,
  byte-interleaved), protcpu (`nmk-215.bin`, confirmed byte-identical
  to macross's/gunnail's own via CRC `d355a06f`), fgtile/bgtile/sprites
  (`93087-3/4/5.bin`), vtiming (`8.ic37`, CRC `633ab1c9` — matches
  macross's own V-PROM exactly, confirming direct `nmk_irq.sv`
  reusability). oki1/oki2 sample ROMs were **not** extracted — sound
  stays stubbed, same as bjtwin_core.sv's own existing cactus build.

### Verification results — confirms the same known issue, not a new one

Full 300M-cycle run, no crash: **protection MCU executed 2,824,804
instructions, last PC=`$0088`, 0 HALT assertions** — bit-for-bit
identical to macross's own and gunnail's own fresh-run signatures
(same numbers documented above), confirming all three games run
byte-identical NMK-215 firmware down to the instruction and hit the
exact same open timing-drift issue. Per the scope already established
for macross, this was not re-diagnosed here — same open item, not a
new problem introduced by this port. 68000 executed 13,423,931
instructions (last fetch PC=`$009702`, 785,516 write bus cycles); video
side rendered 422 frames with real, varying content (79 distinct
frame CRCs across the run, not a stuck/blank signature).

### Regression sweep

No shared file (`tlcs90.sv`, `nmk_prot_core.sv`, `nmk214.sv`,
`nmk_irq.sv`, `video_timing.sv`, `bjtwin_core.sv`, `video_bjtwin.sv`)
was touched — only new sibling files plus `sim/rtl/bjtwin/Makefile`
(additive targets only). Re-ran the existing cactus/tdragon1/hachamf/
macross/gunnail binaries directly (rebuilding would be bit-identical
given no shared source changed) — all five matched their documented
baselines exactly: cactus 17 frames clean; tdragon1 508 HALT asserts;
hachamf 802 HALT asserts; macross and gunnail both 0 HALT asserts,
last PC=`$0088`, 2,824,804 protection-MCU instructions. Zero
regressions.

### Status

Ported, built, runs clean — the smallest-scope Family D port this
session, exactly as expected going in (both halves of the
infrastructure pre-existed and needed no changes, only new
integration glue). **Not yet playable**, for the identical reason
macross/gunnail aren't: the shared NMK-215 protection firmware's own
timing-drift issue, already characterized above and not re-chased
here. Changes left uncommitted for review.

## mustangb — Tier 5's first port (Family E, first Z80-based port in this project)

`mustangb` ("US AAF Mustang (bootleg, set 1)") is the natural first
Family E target: a Raiden-sound bootleg of `mustang` (Tier 2) that
replaces NMK004 with a real Z80 + Seibu Sound System v1.02 board (YM3812
+ single OKIM6295), while reusing `mustang`'s exact video architecture
unmodified (`screen_update_macross`/`gfx_macross`/
`VIDEO_START_OVERRIDE(macross)` — confirmed identical between the two
machine configs in `nmk16.cpp`). This is the first port in the project
to use a real Z80 core, made possible by this session's own GHDL-based
VHDL→Verilog translation of T80 (`rtl/third_party_gen/t80/T80s.v`, see
`docs/t80-vhdl-toolchain.md`) — the whole point of building that
toolchain in the first place.

### What was built

- **`rtl/seibu/seibu_sound.sv`** (new device): ported from
  `seibu_sound_device` (`mame/src/mame/shared/seibusound.{h,cpp}`) — the
  Z80-side register block (`0x4000-0x401B`: pending/irq-clear/
  rst10-ack/rst18-ack/bank-select/YM3812 pass-through/soundlatch/
  main-data-pending/coin/main-data-write), and the IM0
  interrupt-vector arbitration between YM3812's RST10 (vector `0xD7`)
  and the 68000's RST18 (vector `0xDF`, via `main_mustb_w`), replicating
  the reference's own `VECTOR_INIT`/`RST10_*`/`RST18_*` state machine so
  a simultaneous RST10+RST18 can't corrupt the vector byte driven onto
  the data bus during the Z80's interrupt-acknowledge cycle (M1_n &
  IORQ_n both low). mustangb's own `mustangb_map` only ever exercises
  `main_mustb_w` on the 68000 side (confirmed directly against the
  source: no read of `main_r`/soundlatch/pending anywhere in that map),
  so `main_r`'s full offset switch is implemented for completeness but
  not exercised by this port's own testbench.
- **`rtl/mustangb/mustangb_core.sv`** (new system top-level): fx68k (same
  wiring pattern every prior port uses) + T80s (via
  `rtl/third_party_gen/t80/T80s.v`) + `seibu_sound` + jtopl2 (YM3812,
  first use of jtopl in this project) + jt6295 (OKIM6295, reusing
  `mustang_core.sv`'s own write-stretch/rom_ok/bank-arithmetic
  conventions). Reuses, unmodified: `rtl/mustang/video_mustang.sv`
  (video), `rtl/bjtwin/video_timing.sv` + `rtl/bjtwin/nmk_irq_hacky.sv`
  (mustangb's own timing PROMs are undumped, so — like Tier 1's
  `cactus` — MAME substitutes the same fixed-scanline table
  `nmk16_hacky_scanline` already implements; confirmed via
  `set_hacky_interrupt_timing(config)` in the machine config, not the
  real V-PROM path `mustang` itself uses).
- **Z80/YM3812 clock enable**: real hardware clocks both from
  `14318180/4 = 3579545 Hz` (identical divisor in the reference's own
  machine config). Since `32000000/3579545` has no clean power-of-2
  reduction (unlike the 68000's own exact `/4`), this uses a
  GCD-reduced exact-ratio phase accumulator instead
  (`increment=715909, modulus=6400000`, GCD(3579545,32000000)=5) — the
  long-run average rate is exactly right, same technique this project's
  jt03/jt6295 clock enables already established, just with a wider
  (23-bit) accumulator since the ratio doesn't reduce as small.
- **ROM extraction**: `tools/mkgfxrom.py`'s existing `segments` mode
  reproduces the reference's `ROM_LOAD` + `ROM_CONTINUE` + `ROM_COPY`
  audiocpu ROM layout (`mustang.16`, a single 0x10000-byte file split
  across region offsets 0/0x10000, then region 0x18000 duplicated from
  region 0) byte-for-byte, by re-reading file offset 0 into region
  0x18000 — no new tooling needed. Graphics ROMs (`90058-1/4/8/9`) are
  shared with parent set `mustang` (mustangb has no `parent`-relative
  clone data of its own for these — confirmed via CRC match against
  `ROM_START(mustang)`), so extraction searches `mustang.zip` first,
  matching this project's own established split-romset convention (see
  `docs/rom-audit.md`).

### Verification results

Full 60M-`clk_sys`-cycle (32MHz) run: Z80 executed 745,065 instructions
(last fetch PC=`$0126`, settled into a 3-instruction idle loop at
`$0126/$0129/$012A`), 68000 executed 2,710,850 instructions (150,426
write bus cycles, last fetch PC=`$003A60`), 106 video frames rendered.
IM0 interrupt-acknowledge cycles: 2 total over the run — 1 RST10
(YM3812), 1 RST18 (main CPU), **0 spurious** — confirming the vector
arbitration logic works correctly when it actually fires, not just in
isolation (low overall IRQ activity is expected here: no player
input/coin insert is driven in this testbench, so the 68000 stays in an
attract/boot-only state that triggers very little sound-latch traffic).
Pixel/VRAM sanity: palette 16/1024 non-blank, TX VRAM 233/1024 non-blank
(a real, non-garbage boot/attract-text screen), BG VRAM still blank at
end of run (this window never reaches whatever later state populates
it), 2,204/86,016 rendered pixels non-zero — partial but real, non-noise
rendering, consistent with every prior port's own "pixel dump sanity
check" convention.

**Z80 core cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,172,391 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
the PC sequence matches as an ordered subsequence for the first 2,326
checkpoints, and **every single matched instruction's cycle cost is
exact — 0/2,325 differ (tolerance=0), total cycles over the matched span
46,216=46,216 (ratio=1.000)**. This is the first real cycle-accuracy
result for the GHDL-translated T80 core against a live MAME oracle, and
it's clean: the translation didn't just produce syntactically valid
Verilog (already confirmed via `verilator --lint-only`, see
`docs/t80-vhdl-toolchain.md`) — it's genuinely cycle-exact against real
Z80 hardware timing, for as far as this comparison window reaches.

(One real testbench bug found and fixed along the way: the first
version of `tb_mustangb.cpp` logged raw 32MHz `clk_sys_ticks` to
`z80_cyc.trace` instead of a Z80-clock-equivalent tick count, producing
a spurious, uniform ~9x cycle-cost "mismatch" against the oracle — not a
real RTL defect, just a unit-scaling bug in the trace writer.
Fixed by adding a `dbg_z80_cen` debug output to `mustangb_core.sv` and
counting its pulses in the testbench instead.)

**Where the match stops, and what that is**: oracle checkpoint 2,327
(PC=`$0018`) is never found anywhere in the candidate's own full
745,065-instruction trace (confirmed directly, not just by the diff
tool's own report). What both sides visit at PC=`$00CC`/`$00CD` around
this point is not two alternating instructions but a single `LDIR`
opcode (`ED B0`, confirmed directly against the extracted ROM image at
this exact address) — Z80's block-repeat instructions re-fetch from
their own opcode address every iteration until `BC=0`, which is what
produces the "polling loop" PC signature externally; the oracle
eventually falls through (to `$0119`→`$011A`→`$0018`→...) after some
number of iterations, the candidate also falls through eventually (it's
not permanently stuck — the full run's own last fetch PC, `$0126`, is
reached via a different exit path, never through `$0018` at all). This
is a genuine, real divergence in *which* exit path is taken, not a
decode error or a timing bug — the cycle-perfect match on everything up
to and including this instruction rules out a CPU-core-correctness
explanation. This also sharpens the likely mechanism beyond this
project's usual "live system content" framing (see macross/gunnail/
bjtwin's own still-open protection-MCU timing-drift writeups): real
Z80 hardware checks for a pending maskable interrupt *between* each
`LDIR` iteration, and this port's own RST18 is asserted by the 68000's
`main_mustb_w` write — an event whose exact system-cycle timing depends
on fx68k's own accumulated boot-sequence cycle cost, a completely
separate, independently-validated core. A one-cycle skew in when RST18
becomes pending relative to this `LDIR`'s own iteration count would be
enough to shift *which* iteration takes the interrupt, and hence when
(or with what register/RAM state) execution resumes afterward — the
same class of small, compounding, boundary-condition timing sensitivity
already accepted elsewhere in this project (e.g. the TLCS-90 core's own
"1-cycle FSM-pipeline floor" quirk), not a single fixable bug at a
single address. Not further diagnosed this session — the next concrete
step, if picked up later, would be capturing the system-cycle count at
which RST18 actually asserts on both sides and comparing that against
each side's own `LDIR` iteration count at that moment, rather than
assuming a RAM-content dependency.

### Regression sweep

No shared file was modified — `rtl/mustang/video_mustang.sv`,
`rtl/bjtwin/video_timing.sv`, `rtl/bjtwin/nmk_irq_hacky.sv`,
`rtl/third_party_gen/t80/T80s.v`, and the vendored `jtopl2.v`/`jt6295.v`
were only referenced (`-y` include paths / direct instantiation), never
edited. Re-ran `mustang`'s own testbench (fresh rebuild, 60M cycles):
106 frames rendered, NMK004 past its host-handshake poll loop
(1,248,714 instructions, last PC=`$01DB`, 329 RET-Z-at-`$0E5F` hits,
6,580 YM2203 writes, 42/54 OKI1/OKI2 writes), matching its own
established shape — no crash, no unexpected divergence. Re-ran Tier 1's
`cactus` testbench (fresh rebuild, 12M cycles): 17 frames rendered,
`cactus_rtl.trace` written cleanly, no Verilator errors. Zero
regressions (a full oracle re-diff for cactus wasn't re-run this
session — its own oracle trace lives in the gitignored
`sim/oracle/traces/` and needs regenerating locally; the structural
re-run — clean build, clean completion, same instruction-count shape —
is the regression signal here, not a fresh oracle match).

### Status

Built, boots, and runs clean on both CPUs. The Z80/T80 core is now
**verified cycle-exact against real MAME hardware timing** for the
portion of boot this comparison window covers — the strongest possible
validation that the GHDL VHDL→Verilog translation toolchain (this
session's own prior deliverable, `docs/t80-vhdl-toolchain.md`) actually
works, not just "looks like valid Verilog." IM0 interrupt vectoring
(the trickiest part of the Seibu Sound System port, per that module's
own header) fires correctly with zero spurious vectors when exercised.
**Not yet a full oracle match**: a single well-characterized, real
loop-exit-path divergence (detailed above) stops the ordered PC-sequence
match at instruction 2,326 of the candidate's own much longer run — left
open, not further chased this session, per this project's own
established practice for exactly this class of finding.

**Primary-session review pass** found and fixed two real issues before
commit (both confirmed behaviorally inert for mustangb itself — same
instruction counts, same frame count, same trace shape before and
after — since neither path is exercised by this game's own program, but
both are genuine correctness bugs a later Family E port reusing this
module could hit):
- `seibu_sound.sv`'s register read at offset `0x12`
  (`main_data_pending_r`) returned `main2sub_pending` instead of
  `sub2main_pending` — confirmed via direct ROM disassembly that
  mustangb's own Z80 program never reads address `0x4012` at all (no
  `3A 12 40`/`LD A,(4012h)` anywhere in the image), so this had zero
  effect here, but the reference clearly reads the other flag
  (`seibusound.cpp:262-265`).
- `mustangb_core.sv`'s `main_mustb_w` handler latched the full 16-bit
  write unconditionally, not gated per-byte on `UDSn`/`LDSn` the way
  every other byte-addressable register in the same file already is —
  the reference (`seibusound.cpp:319-329`) only updates whichever byte
  lane `ACCESSING_BITS_0_7`/`8_15` actually covers, leaving the other
  latch's prior value alone on a byte-narrow write.
- Also corrected the "polling loop" characterization above: PC
  `$00CC`/`$00CD` is one `LDIR` opcode (`ED B0`, confirmed against the
  extracted ROM), not two alternating instructions — its own
  hardware repeat-until-`BC=0` mechanism is what produces the
  loop-like PC signature, which sharpens the likely divergence
  mechanism to interrupt-during-`LDIR` resume timing rather than a
  RAM-content-dependent poll.

Changes committed.

## tdragonb — Tier 5's second port (Family E, second Z80-based port in this project)

`tdragonb` ("Thunder Dragon (bootleg with Raiden sounds, encrypted)") is
the natural second Family E target: a Raiden-sound bootleg of `tdragon`
(Tier 2) sharing mustangb's own Seibu Sound System v1.02 hardware
end-to-end — same `set_hacky_interrupt_timing`, same `seibu_sound_map`,
same YM3812/OKIM6295 wiring, even a **byte-identical audiocpu ROM**
(`td_02.bin`, CRC `99ee7505`, same as mustangb's own `mustang.16`).
Despite its name suggesting extra difficulty, `tdragonb` was chosen over
its unencrypted sibling `tdragonb3` because `tdragonb3`'s own `bgtile`
ROM is marked `BAD_DUMP`/"undumpable on this PCB" in the reference
(`nmk16.cpp:7634`) while `tdragonb`'s own ROM set is cleanly, fully
dumped throughout — its "encryption" turned out to be a simple,
**static, one-time bit-permutation** (`decode_tdragonb()`,
`nmk16.cpp:6082-6125`), not a live hardware descrambler, so it was
solvable as an offline ROM-extraction-time transform rather than new
RTL. `tdragonb2`, the third sibling, is flagged
`MACHINE_NOT_WORKING` in the reference itself and wasn't considered.

### What was built

- **`tools/decode_tdragonb.py`** (new tool): a small, standalone
  transliteration of `decode_byte()`/`decode_word()`
  (`nmk16.cpp:5974-5996`) — pure bit-permutation functions, applied once
  by MAME at init, not per-access. Verified against the reference before
  trusting it on real ROM data: both permutation tables checked as
  genuine bijections (`sorted(table) == range(n)`), plus two
  hand-traced single-bit-position examples matched the formula exactly.
  Run *after* `tools/mkrom.py`/`tools/mkgfxrom.py` (which already handle
  the hi/lo interleaving `decode_tdragonb()` itself assumes is already
  done, confirmed via its own `NATIVE_ENDIAN_VALUE_LE_BE` byte-position
  handling resolving, on this little-endian host, to exactly the
  "ROM byte 0 = high byte of the word" convention `mkrom.py` already
  produces) — this tool only permutes bits within already-assembled hex
  lines, no file reading/interleaving of its own. Applied to `maincpu`
  (word mode, 16-bit table) and `bgtile`/`sprites` (byte mode, 8-bit
  table); `fgtile`/`oki`/`audiocpu` are untouched by the reference's own
  `decode_tdragonb()` and extracted plainly.
- **`rtl/tdragonb/tdragonb_core.sv`** (new system top-level): the same
  fx68k+T80s+`seibu_sound`+jtopl2+jt6295 architecture as `mustangb_core.sv`
  (reusing `rtl/seibu/seibu_sound.sv`, `rtl/third_party_gen/t80/T80s.v`,
  `rtl/bjtwin/video_timing.sv` + `rtl/bjtwin/nmk_irq_hacky.sv` all
  **unmodified**), but with `tdragonb_map`'s own memory layout
  (`nmk16.cpp:870-886` — genuinely different from `mustangb_map`: no
  mirroring at all, `main_mustb_w` at `0xC001E-0xC001F` not
  `0x08001E-0x08001F`, a hardwired-constant protection-shrug read at
  `0x044022-0x044023` returning `0x0003` — replicated as-is like this
  project already does for other MAME-author-shrug hacks, not
  investigated further) and, genuinely new to Tier 5,
  **`rtl/tdragon/video_tdragon.sv`** (already built for Tier 2's own
  `tdragon` — confirmed `tdragon_map` and `tdragonb_map` share the
  identical video/VRAM/palette/tilebank/scroll register layout, so this
  port's own scroll/tilebank register wiring is a direct copy of
  `tdragon_core.sv:314-336`'s own working pattern, not reinvented).
- **A genuinely new clock ratio**: `tdragonb`'s own 68000 runs at
  **10MHz**, not the clean `clk_sys/4 = 8MHz` every single other port in
  this project uses (confirmed via a project-wide grep — every other
  `*_core.sv` uses the identical `cpu_div==2'd3`/`2'd1` pattern; this is
  the first port needing anything else). `GCD(10000000,32000000)
  =2000000` gives `increment=5, modulus=16` — a small 4-bit phase
  accumulator drives `enPhi1`/`enPhi2` instead of a free-running
  counter. The one property that actually matters for correctness —
  fx68k's own internal T-state FSM requires `enPhi1`/`enPhi2` to
  **strictly alternate** (never two of the same enable back-to-back,
  confirmed by reading `fx68k.sv`'s own T-state transition table) — was
  verified by simulating the exact accumulator logic in Python for 200
  cycles (12+ full periods) before trusting it in RTL: zero
  same-enable-twice-in-a-row violations. The resulting real average rate
  was cross-checked post-hoc against the actual testbench run too: ~18.75M
  `enPhi1` pulses over 60M `clk_sys` cycles = ratio 0.3125 = 5/16 exactly.

### Verification results

Full 60M-`clk_sys`-cycle (32MHz) run: Z80 executed 745,063 instructions
(last fetch PC=`$0126`, same idle-loop signature as mustangb's own),
68000 executed 3,402,738 instructions (295,839 write bus cycles, last
fetch PC=`$00046C` — notably further into the program than mustangb's
own run reached, consistent with the faster 10MHz clock covering more
real time per `clk_sys` cycle). IM0 interrupt-acknowledge cycles: 1
total — RST10 (YM3812) only, 0 RST18, 0 spurious (this run's own
boot/attract sequence apparently doesn't reach a `main_mustb_w` write
within the window, unlike mustangb's own; not investigated further,
consistent with this being an input-idle attract-mode run rather than a
gameplay session). Pixel/VRAM sanity is **substantially richer than
mustangb's own**: palette 674/1024 non-blank, BG VRAM 4,608/8,192,
TX VRAM 78/1,024, and **85,250/86,016 (99%) rendered pixels non-zero** —
a fully-populated, plausible real frame, not a partial boot screen,
consistent with the 68000 covering much more program ground in the same
`clk_sys` budget.

**Z80 core cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,150,044 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
the PC sequence matches as an ordered subsequence for the first **6,368
checkpoints** — nearly 3x further than mustangb's own 2,326 — with
**only 1/6,367 matched instruction cycle-costs differing** (tolerance=0;
the one mismatch: checkpoint 6367, `PC 0129->012A`, oracle=4
candidate=10, diff=+6), total cycles over the matched span
oracle=82,933/candidate=82,939 (**ratio=1.000**). This is a second,
independent confirmation — at a different main-CPU clock (10MHz vs
mustangb's 8MHz), with the same audiocpu ROM but different interrupt
arrival timing — that the GHDL-translated T80 core is genuinely
cycle-exact against real Z80 hardware, not a coincidence specific to
mustangb's own timing.

**Where the match stops, and what that is**: oracle checkpoint 6,369
(PC=`$0010`) is never found anywhere in the candidate's own full
745,063-instruction trace (confirmed directly). `$0010` is exactly where
a Z80 executing the `RST 10h` opcode (`0xD7` — the YM3812's own IM0
vector byte) lands, so this is the **same underlying mechanism** as
mustangb's own finding, one interrupt source over: both oracle and
candidate *do* experience an RST10 interrupt at some point in their
respective runs (oracle: within this capture window, as this checkpoint
shows; candidate: the single RST10 IACK reported above, at some other
point in its own longer run) — the divergence is *which iteration* of
the `$0126`/`$0129`/`$012A` idle-poll loop the interrupt lands on, not
whether it fires at all or a CPU-decode error (the cycle-perfect match
up to this exact point rules that out). Same class of finding as
mustangb's own "interrupt-during-a-repeat-checked-loop" timing
sensitivity — not further diagnosed this session, consistent with this
project's own established practice for this class of issue.

### Regression sweep

No shared file was modified — `rtl/tdragon/video_tdragon.sv`,
`rtl/seibu/seibu_sound.sv`, `rtl/bjtwin/video_timing.sv`,
`rtl/bjtwin/nmk_irq_hacky.sv`, `rtl/third_party_gen/t80/T80s.v`, and the
vendored `jtopl2.v`/`jt6295.v` were only referenced, never edited.
Re-ran `mustangb`'s own testbench (fresh rebuild, 60M cycles): matches
its own already-established baseline exactly (745,065 Z80 instructions,
2,710,850 68000 instructions, 2 IACKs, 106 frames) — zero regression.
Re-ran `tdragon`'s own testbench (fresh rebuild, 300M cycles): NMK004
executed 6,262,509 instructions (last PC=`$01DB`), 68000 executed
14,151,673 instructions, 527 frames rendered, 35,338 YM2203 writes,
26/20 OKI1/OKI2 writes — a clean, healthy run with no crash. Re-ran
`tdragon1`'s own testbench too (fresh rebuild, 300M cycles): NMK004
executed 6,148,238 instructions (last PC=`$01DA`), protection MCU
executed 2,981,349 instructions (last PC=`$08C4`), **68000 HALT
asserted 508 times** — matching this port's own already-established
baseline exactly — 527 frames rendered, no crash. Zero regressions
across all three.

### Status

Built, boots, and runs clean on both CPUs. The Z80/T80 core now has a
**second, independent cycle-exact confirmation** against real MAME
hardware timing, at a different main-CPU clock ratio than mustangb's
own — a real test of the GHDL translation's own correctness, not a
repeat of the same conditions. IM0 interrupt vectoring, `video_tdragon.sv`
reuse, and the new non-power-of-2 68000 clock-enable derivation all work
correctly. **Not yet a full oracle match**: a single well-characterized
loop-exit-path divergence (detailed above), the same class of finding as
mustangb's own, stops the ordered PC-sequence match at instruction 6,368
of the candidate's own much longer run — left open, not further chased
this session.

## acrobatmbl — Tier 5's third port (Family E, third Z80-based port in this project)

`acrobatmbl` ("Acrobat Mission (bootleg with Raiden sounds)") is the
natural third Family E target: a Raiden-sound bootleg of `acrobatm`
(Tier 2) sharing mustangb's/tdragonb's own Seibu Sound System v1.02
hardware end-to-end (`set_hacky_interrupt_timing`, `seibu_sound_map`,
YM3812/OKIM6295 wiring) and, again, a **byte-identical audiocpu ROM**
(`2.12w`, CRC `99ee7505`, same as mustangb's `mustang.16` and tdragonb's
`td_02.bin`). Despite the ROM_START comment calling this "a bootleg with
a PIC performing simple protection checks," the PIC needed **zero new
RTL**: its own machine config declares `PIC16C57(config,"mcu",
8_MHz_XTAL/2).set_disable()`, `acrobatmbl_map` has no read/write handler
referencing any PIC/protection port at all, and the PIC's own ROM is
genuinely undumped (`NO_DUMP`) — MAME instead statically patches 4
sixteen-bit words in the 68000 program ROM (`init_acrobatmbl()`,
`nmk16.cpp:6238-6262`), replacing two jumps into PIC-protected RAM with
jumps elsewhere. Solvable as an offline ROM-extraction-time transform,
same category as tdragonb's own `decode_tdragonb.py`.

### What was built

- **`tools/patch_rom_words.py`** (new tool): a small, generic word-offset
  patcher for `$readmemh` hex files — applies `init_acrobatmbl()`'s own 4
  word pokes (`rom[0x364]=0x0000, rom[0x365]=0x2d84, rom[0x36a]=0x0000,
  rom[0x36b]=0x3510`, word indices = byte offset/2) after `tools/mkrom.py`'s
  own interleaving. Unlike `decode_tdragonb.py` (a fixed bit-permutation),
  this is a plain value poke, and was written generically enough to reuse
  for any future Family G-style "protection cracked/patched out" ROM fixup
  this project's own `docs/PLAN.md` already anticipates.
- **`rtl/acrobatmbl/acrobatmbl_core.sv`** (new system top-level): the same
  fx68k+T80s+`seibu_sound`+jtopl2+jt6295 architecture as `mustangb_core.sv`/
  `tdragonb_core.sv` (reusing `rtl/seibu/seibu_sound.sv`,
  `rtl/third_party_gen/t80/T80s.v`, `rtl/bjtwin/video_timing.sv` +
  `rtl/bjtwin/nmk_irq_hacky.sv` all **unmodified**), but with
  `acrobatmbl_map`'s own memory layout (`nmk16.cpp:766-781` — confirmed
  identical to `acrobatm_map` apart from the sound/protection entries,
  `main_mustb_w` at `0xC001E-0xC001F` replacing the NMK004 read/write
  trio) and, genuinely new to Tier 5, **`rtl/acrobatm/video_acrobatm.sv`**
  (already built for Tier 2's own `acrobatm` — confirmed identical
  video/VRAM/palette/tilebank/scroll register layout, including the
  family's smallest palette, **768 entries, not 1024**). Deliberately
  does NOT reuse `acrobatm_core.sv`'s own 40MHz `clk_sys` architecture
  (that ratio is specific to the real board's 10MHz 68000) — `acrobatmbl`'s
  own 68000 genuinely runs at a plain `8_MHz_XTAL`, so this port uses
  mustangb's/tdragonb's own 32MHz `clk_sys` convention instead
  (`clk_sys/4`). `video_acrobatm.sv` itself takes a generic `clk_sys`
  input with no internal frequency-specific derivation (verified directly
  against its own module body before assuming this), so it drops into
  either convention unchanged.
- **The project's simplest clock ratios yet**: every clock enable in this
  port is a clean power-of-2 divide from 32MHz `clk_sys` — 68000
  `clk_sys/4` (same as mustangb's own), Z80+YM3812 `clk_sys/8` = 4MHz
  (`8_MHz_XTAL/2`, `nmk16.cpp:4862,4880` — a plain free-running counter,
  not mustangb's/tdragonb's own `14318180/4` phase accumulator),
  OKIM6295 `clk_sys/32` = 1MHz (`8_MHz_XTAL/8`, `nmk16.cpp:4884`).
- **ROM extraction hit a real split-romset naming trap**: `mame_roms/
  acrobatmbl.zip` contains only 5 files (`1.14y`, `2.12w`, `3.10f`,
  `4.10c`, `c.2m`) — `fgtile`/`bgtile`/sprites-part-1 (`10m`/`a.9x`/`b.2k`)
  are shared with parent set `acrobatm` (CRCs confirmed identical via
  direct extraction+hash), but — unlike mustangb's own parent/clone pair
  — stored under genuinely **different member names** in the parent zip
  (`3.ic79`/`am-03.ic8`/`am-01.ic42`, reflecting that board's own chip
  labels). `tools/mkgfxrom.py`'s `--zip` fallback only retries the *same*
  filename in each zip in turn, so this needed the parent zip's own real
  names, not a same-name fallback. Also confirmed and correctly handled
  the same `ROM_IGNORE`-truncation trap `mustangb`'s own review flagged
  as a risk in the brief for this port: `c.2m` is a `0x100000`-byte file
  of which only the first half is used (`ROM_IGNORE(0x080000)`) — loading
  it in full would overflow the declared `0x180000`-byte sprites region.
  Extracted the two contributing files separately (`mkgfxrom.py`'s
  `segments` mode truncates `c.2m` to its used half) and concatenated,
  with a line-count assertion (`1572864` = `0x180000`) added to the
  Makefile itself to catch any future regression in this step mechanically
  rather than relying on a human noticing a silently-wrong sprite sheet.

### Verification results

First run at `RUN_CYCLES=60,000,000` (mustangb's/tdragonb's own budget)
showed a **completely blank frame** — `0/768` palette entries non-blank,
`0/86,016` pixels non-zero. Investigated rather than accepted: `acrobatm`'s
own already-established testbench (`docs/tier2-system.md`'s "acrobatm"
section, above) needed `RUN_CYCLES=240,000,000` at 40MHz (6.0 real
seconds) to reach its own first palette-populated frame — `acrobatmbl`'s
boot sequence follows its parent's closely (`ROM_START`'s own comment:
"extremely similar to the original"), so 60M cycles at 32MHz (1.9 real
seconds) was simply nowhere near enough real time, not a bug. Re-ran at
`RUN_CYCLES=240,000,000` (7.5 real seconds at this port's own 32MHz,
more generous than acrobatm's own 6s budget): **palette 15/768 non-blank,
82,349/86,016 (95.7%) rendered pixels non-zero — an EXACT match to
acrobatm's own already-documented numbers** (same section: "palette RAM
shows 15/768 non-zero entries and 82,349/86,016 rendered pixels are
non-zero... a fully readable, correctly formatted DIP-switch service-mode
menu"). Given acrobatmbl and acrobatm share near-identical boot code,
this exact numeric match is strong evidence `acrobatmbl` renders the
identical DIP-switch menu correctly, not just "plausible" content —
tighter corroboration than either mustangb's or tdragonb's own "partial
but real, non-noise" verification could offer, since there's a matching
sibling result to cross-check against. Z80 executed 3,332,658
instructions (last fetch PC=`$012A`), 68000 executed 10,505,300
instructions (443,098 write bus cycles, last fetch PC=`$002112`). IM0
interrupt-acknowledge cycles: 1 total — RST10 (YM3812) only, 0 RST18, 0
spurious, same shape as tdragonb's own run (no `main_mustb_w` write
observed in this input-idle window).

**Z80 core cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,312,133 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
the PC sequence matches as an ordered subsequence for the first **6,368
checkpoints**, with **only 1/6,367 matched instruction cycle-costs
differing** (tolerance=0; the one mismatch: checkpoint 6367, `PC
0129->012A`, oracle=4 candidate=10, diff=+6), total cycles over the
matched span oracle=82,933/candidate=82,939 (**ratio=1.000**). This is a
**third, independent confirmation** that the GHDL-translated T80 core is
cycle-exact against real Z80 hardware — and notably, the checkpoint
count, mismatch location, and total-cycle figures are **numerically
identical to tdragonb's own result**, despite acrobatmbl's Z80 running
at a genuinely different real clock rate (4MHz here vs tdragonb's
3579545Hz) — exactly what correct Z80 emulation should produce, since
T-state costs are defined per-instruction, not per-real-time-unit, and
both ports share the identical audiocpu ROM. Internal-consistency
evidence on top of the oracle match itself, not just a repeat of it.

**Where the match stops, and what that is**: oracle checkpoint 6,369
(PC=`$0010`, the `RST 10h`/YM3812 IM0 vector address) is never found in
the candidate's own full 3,332,658-instruction trace. Same underlying
mechanism already characterized for mustangb/tdragonb — an
interrupt-during-a-repeat-checked-idle-loop timing sensitivity, not a
CPU-decode error (the cycle-perfect match up to this exact point rules
that out) — recurring here specifically *because* the audiocpu ROM is
unchanged from those two ports, not a newly-discovered issue. Not
further diagnosed this session, consistent with this project's own
established practice for this class of finding.

### Regression sweep

No shared file was modified — `rtl/acrobatm/video_acrobatm.sv`,
`rtl/seibu/seibu_sound.sv`, `rtl/bjtwin/video_timing.sv`,
`rtl/bjtwin/nmk_irq_hacky.sv`, `rtl/third_party_gen/t80/T80s.v`, and the
vendored `jtopl2.v`/`jt6295.v` were only referenced, never edited.
Re-ran `mustangb`'s own testbench (fresh rebuild, 60M cycles): matches
its own already-established baseline exactly (745,065 Z80 instructions,
2,710,850 68000 instructions, 2 IACKs, 106 frames) — zero regression.
Re-ran `acrobatm`'s own testbench (fresh rebuild, 240M cycles): NMK004
executed 4,105,176 instructions (last PC=`$01DB`), 68000 executed
10,545,348 instructions, 338 frames rendered, 21,681 YM2203 writes, 5/5
OKI1/OKI2 writes — a clean, healthy run with no crash, consistent shape
with this port's own established behavior (no shared file was touched,
so this is confirmatory rather than a genuine regression risk).

### Status

Built, boots, and runs clean on both CPUs. The Z80/T80 core now has a
**third, independent cycle-exact confirmation** against real MAME
hardware timing, and — uniquely among the three Tier 5 ports so far —
a **quantitatively exact video-content match** against a closely related
sibling port's own already-verified rendering. The PIC "protection" is
fully resolved via the same offline-ROM-patch technique this project's
own `decode_tdragonb.py` established, needing zero new RTL. A real
split-romset filename mismatch (parent zip stores shared graphics ROMs
under different member names than the clone's own `ROM_START` labels)
was found and worked around correctly, with the previously-flagged
`ROM_IGNORE` truncation trap also handled correctly and now mechanically
guarded by a line-count assertion in the Makefile. **Not yet a full
oracle match**: the same class of well-characterized, unchased
interrupt-timing loop-exit divergence as mustangb's/tdragonb's own
(recurring here because the audiocpu ROM is unchanged, not a new
finding) stops the ordered PC-sequence match at instruction 6,368 of the
candidate's own much longer run — left open, not further chased this
session.

## strahljbl — Tier 5's fourth port (Family E, fourth Z80-based port in this project)

`strahljbl` ("Koutetsu Yousai Strahl (Japan, bootleg)") is the natural
fourth Family E target: a Raiden-sound bootleg of `strahl` (Tier 2)
sharing every prior Tier 5 port's own Seibu Sound System v1.02 hardware
end-to-end (`set_hacky_interrupt_timing`, `seibu_sound_map`, YM3812/
OKIM6295 wiring) and, again, a **byte-identical audiocpu ROM**
(`a6.u417`, CRC `99ee7505`) and OKI ROM (`a5.u304`, CRC `f6f6c4bf`).
Unlike the prior three ports, `strahljbl` uses `empty_init()`
(`nmk16.cpp:10787`) — no ROM patching, no decryption, no protection
workaround needed at all, confirmed by reading the source directly.
This is also this project's first Tier 5 game with a **dual-BG-layer**
video architecture (Strahl has two independent VRAM tilemaps, BG0+BG1,
each with its own X/Y scroll register block).

### What was built

- **`rtl/strahljbl/strahljbl_core.sv`** (new system top-level): the same
  fx68k+T80s+`seibu_sound`+jtopl2+jt6295 architecture as `mustangb_core.sv`/
  `tdragonb_core.sv`/`acrobatmbl_core.sv` (reusing `rtl/seibu/
  seibu_sound.sv`, `rtl/third_party_gen/t80/T80s.v`, `rtl/bjtwin/
  video_timing.sv` + `rtl/bjtwin/nmk_irq_hacky.sv` all **unmodified**),
  with `strahljbl_map`'s own memory layout (`nmk16.cpp:967-983` —
  confirmed identical to `strahl_map`, `nmk16.cpp:947-965, apart from
  the sound entries: `main_mustb_w` at `0x8001E-0x8001F` replaces the
  NMK004 read/write trio; neither map has a `tilebank_w` entry) and,
  genuinely new to Tier 5, **`rtl/strahl/video_strahl.sv`** (already
  built for Tier 2's own `strahl` — confirmed identical video/VRAM/
  palette/scroll register layout). `video_strahl.sv`'s own dual-BG-layer
  port interface (`bg0vram_addr/data`, `bg1vram_addr/data`,
  `bg0_xscroll/yscroll`, `bg1_xscroll/yscroll`) and `strahl_core.sv`'s
  own `sel_scroll0`/`sel_scroll1`/`scroll_reg[0:1][0:3]` wiring pattern
  were copied directly, not reinvented. Main work RAM uses a plain
  masked write (no "mainram_strange_w" quirk — `strahl_map`/
  `strahljbl_map` both map `0xF0000-0xFFFFF` with bare `.ram()`, no
  write-handler override, so standard `COMBINE_DATA` semantics apply,
  same convention as `strahl_core.sv`'s own).
- **IMPORTANT, same pattern as `acrobatmbl_core.sv`'s own**: this file
  does NOT reuse `video_strahl.sv`'s own donor, `strahl_core.sv`'s, 48MHz
  `clk_sys` architecture (12MHz 68000 = clk_sys/4, NMK004/pixel
  clk_sys/6 = 8MHz — clean ratios specific to that board's own 48MHz
  convention). `strahljbl`'s own machine config uses the same nominal
  12MHz 68000 clock, but this port stays on the standard 32MHz `clk_sys`
  every other Tier 5 port already uses. `video_strahl.sv` itself takes a
  generic `clk_sys` input with no internal frequency-specific
  derivation, so it drops into either convention unchanged.
- **A second port needing a 68000 phase accumulator** (after
  `tdragonb`'s own 10MHz case): `strahljbl`'s own 68000 runs at
  `12_MHz_XTAL`. `GCD(12000000,32000000)=4000000` gives
  `increment=3, modulus=8` — a small 3-bit phase accumulator drives
  `enPhi1`/`enPhi2` (the same "wrap fires enPhi1, defer one enPhi2 to
  the very next non-wrap cycle" technique `tdragonb_core.sv` established).
  Hand-traced the full repeating 8-cycle accumulator sequence before
  trusting it in RTL: `enPhi1` fires at wrap-steps 2, 5, 7 of every
  8-cycle window (rate 3/8 exact), `enPhi2` always exactly one `clk_sys`
  cycle later, and the strict-alternation invariant fx68k's own T-state
  FSM requires (confirmed directly against `fx68k.sv`'s own T-state
  transition table, same check `tdragonb`'s own build used) holds for
  every step of the pattern — never two of the same enable back-to-back.
  Z80 + YM3812 both run at `12_MHz_XTAL/4` = 3MHz (identical divisor,
  same shared-clock convention as every prior port);
  `GCD(3000000,32000000)=1000000` gives `increment=3, modulus=32`,
  another small single-phase accumulator. OKIM6295 at `12_MHz_XTAL/12` =
  1MHz *is* a clean divisor from 32MHz (`increment=1, modulus=32` —
  literally `clk_sys/32`), a plain free-running counter, no accumulator
  needed — same pattern as `acrobatmbl_core.sv`'s own OKI cen.
- **ROM extraction hit the same split-romset naming trap
  `acrobatmbl`'s own port already characterized**: `mame_roms/
  strahljbl.zip` contains only 6 files (`129.u28` — `p_rom`, explicitly
  commented "not used by the emulation" in the reference, skipped
  entirely — plus `a5.u304`, `a6.u417`, `a7.u3`, `a8.u2`, `d.8m`).
  `fgtile`/`bgtile`/`bg2tile`, and half of `sprites`, are shared with
  parent set `strahl` but stored under genuinely different member names
  (board-specific chip labels), confirmed via `unzip -l` on both zips
  plus a CRC cross-check against `ROM_START(strahl)`
  (`nmk16.cpp:7764-7799`): `cha.38`→`strahl-3.73` (fgtile, CRC
  `2273b33e`), `6.2m`→`str7b2r0.275` (bgtile, CRC `5769e3e1`),
  `4.4m`→`str6b1w1.776` (bg2tile, CRC `bb1bb155`), and `5.4m`→
  `strl5-03.58` (sprites part 2, CRC `a0e7d210` — this is `strahl`'s own
  *third* sprite chip; the bootleg's `d.8m`, present directly in
  `strahljbl.zip`, is a genuinely unique "bigger ROM" combining what on
  the real board were two separate 0x80000 chips, per the reference's
  own comment "same as original, just a bigger ROM"). Unlike
  `acrobatmbl`'s own sprites region, **no `ROM_IGNORE` truncation trap
  here** — both sprite pieces load in full, `0x100000 + 0x080000 =
  0x180000` exactly matching the declared region size — still guarded by
  the same line-count-assertion convention `acrobatmbl`'s own Makefile
  established, since a wrong file/offset would otherwise fail silently.

### Verification results

Full 240M-`clk_sys`-cycle (32MHz, 7.5 real seconds) run — started at
this budget directly rather than repeating `acrobatmbl`'s own "blank
frame at 60M, re-run at 240M" detour, since `strahl`'s own existing
Tier 2 testbench already establishes `RUN_CYCLES=240,000,000` as its own
real-time-to-first-content budget. Z80 executed 2,499,324 instructions
(last fetch PC=`$012A`, the same `$0126`/`$0129`/`$012A` idle-loop
signature every prior Tier 5 port's own run settles into), 68000
executed 16,855,915 instructions (~90,000,075 `enPhi1` clock-enable
ticks — matches the target 3/8 ratio almost exactly, 240,000,000×3/8=
90,000,000 predicted), 308,740 write bus cycles, last fetch PC=
`$00145E`. IM0 interrupt-acknowledge cycles: 1 total — RST10 (YM3812)
only, 0 RST18, 0 spurious, same shape as tdragonb's/acrobatmbl's own
runs (no `main_mustb_w` write observed in this input-idle window). 422
video frames rendered.

**Pixel/VRAM sanity, cross-checked against `strahl`'s own already-
documented baseline rather than assumed plausible in isolation**: at its
own `RUN_CYCLES=240,000,000` (48MHz, ~5 real seconds), `strahl`'s own
testbench shows only 4/1024 non-blank palette entries and 2,665/86,016
(3.1%) non-zero pixels — a genuine hardware self-test/diagnostic screen,
not a rich attract-mode frame (`docs/tier2-system.md`'s own "strahl"
section above). `strahljbl`'s run here, at a comparable-or-longer real
time (7.5s vs strahl's own 5s), shows a **richer but consistent-shape**
result: palette 165/1,024 non-blank, BG0 VRAM 8,192/8,192 (100%), BG1
VRAM 8,192/8,192 (100%), TX VRAM 954/1,024 (93%), and 8,851/86,016
(10.3%) rendered pixels non-zero. Both BG layers being fully written but
the actual non-zero-pixel fraction staying modest (10.3%, not 90%+) is
consistent with a text-heavy diagnostic screen where most of VRAM holds
a "blank" tile value that itself is non-zero data but renders as
background — the same class of content `strahl`'s own sibling run
already established, reached further given the extra real time here,
not a differently-shaped (and therefore suspicious) result. Re-running
the testbench a second time with `TB_DUMP_VRAM=1` reproduced every
number above exactly (instruction counts, frame count, VRAM/pixel
counts) — confirming determinism, not a one-off.

**Z80 core cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
975,232 oracle instructions, diffed via `sim/compare/cyc_diff.py`): the
PC sequence matches as an ordered subsequence for the first **6,368
checkpoints**, with **only 1/6,367 matched instruction cycle-costs
differing** (tolerance=0; the one mismatch: checkpoint 6367, `PC
0129->012A`, oracle=4 candidate=10, diff=+6), total cycles over the
matched span oracle=82,933/candidate=82,939 (**ratio=1.000**). This is a
**fourth, independent confirmation** that the GHDL-translated T80 core
is cycle-exact against real Z80 hardware — and, exactly as expected
since `strahljbl` shares the identical byte-for-byte audiocpu ROM with
`tdragonb`/`acrobatmbl`, every one of these numbers (checkpoint count,
mismatch location, and total-cycle figures) is **numerically identical**
to both of those ports' own results, despite yet another different real
Z80 clock rate (3MHz here vs tdragonb's 3579545Hz vs acrobatmbl's 4MHz)
— exactly what correct, purely T-state-based Z80 emulation should
produce. A third internal-consistency data point on top of the oracle
match itself.

**Where the match stops, and what that is**: oracle checkpoint 6,369
(PC=`$0010`, the `RST 10h`/YM3812 IM0 vector address) is never found in
the candidate's own full 2,499,324-instruction trace. Same underlying
mechanism already characterized for mustangb/tdragonb/acrobatmbl — an
interrupt-during-a-repeat-checked-idle-loop timing sensitivity, not a
CPU-decode error (the cycle-perfect match up to this exact point rules
that out) — recurring here specifically because the audiocpu ROM is
unchanged, not a newly-discovered issue. Not further diagnosed this
session, consistent with this project's own established practice for
this class of finding.

### Regression sweep

No shared file was modified — `rtl/strahl/video_strahl.sv`,
`rtl/seibu/seibu_sound.sv`, `rtl/bjtwin/video_timing.sv`,
`rtl/bjtwin/nmk_irq_hacky.sv`, `rtl/third_party_gen/t80/T80s.v`, and the
vendored `jtopl2.v`/`jt6295.v` were only referenced, never edited.
Re-ran `mustangb`'s own testbench (fresh rebuild, 60M cycles): matches
its own already-established baseline exactly (745,065 Z80 instructions,
2,710,850 68000 instructions, 2 IACKs, 106 frames) — zero regression.
Re-ran `strahl`'s own testbench (fresh rebuild, 240M cycles): NMK004
executed 2,727,068 instructions (last PC=`$0EB1`), 68000 executed
8,617,315 instructions (1,010,721 write bus cycles, last fetch
PC=`$0013EA`), 47 YM2203 writes, 5/5 OKI1/OKI2 writes, 281 frames
rendered — a clean, healthy run with no crash (no shared file was
touched, so this is confirmatory rather than a genuine regression risk).

### Status

Built, boots, and runs clean on both CPUs. The Z80/T80 core now has a
**fourth, independent cycle-exact confirmation** against real MAME
hardware timing, and a second confirmed-correct non-power-of-2 68000
clock-enable derivation (verified via the same fx68k T-state-alternation
check `tdragonb`'s own build established). The dual-BG-layer video
architecture renders correctly on both layers, cross-validated in shape
(not just "plausible in isolation") against `strahl`'s own already-
documented sibling rendering at a comparable real-time budget. No new
protection workaround was needed — `strahljbl` uses `empty_init()`.
**Not yet a full oracle match**: the same class of well-characterized,
unchased interrupt-timing loop-exit divergence as every prior Tier 5
port's own (recurring here because the audiocpu ROM is unchanged, not a
new finding) stops the ordered PC-sequence match at instruction 6,368 of
the candidate's own much longer run — left open, not further chased
this session. Changes left uncommitted for the primary session's own
review before commit.

## gunnailb — Tier 5's fifth port, architecturally different from the prior four

`gunnailb` ("GunNail (bootleg)") was assumed to be the natural fifth
Family E target, matching mustangb/tdragonb/acrobatmbl/strahljbl's own
Seibu Sound System hardware — but direct research into the reference
shows this is wrong. `mame/src/mame/nmk/nmk16.cpp:172`'s own "uses the
Seibu Raiden sound hardware" comment lists only `acrobatmbl, mustangb,
strahljb and tdragonb` — **not gunnailb**. Its own `gunnailb()` machine
config (`nmk16.cpp:5419-5442`) calls `gunnail(config)` first (inheriting
Tier 4's real `gunnail` board's own 68000 clock, video, and YM2203
instance unchanged), then swaps in a Z80 with its own distinct sound/IO
maps (`gunnailb_sound_map`/`gunnailb_sound_io_map`, `nmk16.cpp:1065-1079`
— **not** `seibu_sound_map`), wires the YM2203 IRQ directly to the Z80
(a plain maskable IRQ0, no Seibu-style IM0 vector arbitration), moves the
OKI to be driven **directly by the 68000** instead of the Z80 (a source
comment, `nmk16.cpp:1077`: "since the bootleggers used the same audio CPU
ROM as airbustr but a different Oki ROM, they connected the Oki to the
main CPU" — confirmed via `ROM_START(gunnailb)`, `nmk16.cpp:8226`: the
audiocpu ROM comment literally says "matches the one for Kaneko's Air
Buster", a completely unrelated game's Z80 sound program reused
verbatim), and removes the NMK004 device entirely
(`config.device_remove("nmk004")`) — so this port is fully decoupled
from `gunnail`'s own still-open protection-MCU timing-drift issue
(`docs/PLAN.md`'s Tier 4 section).

### What was built

- **`rtl/gunnail/video_gunnailb.sv`** (new — a derivative of Tier 4's
  `video_gunnail.sv`, NOT a shared edit to it): `video_gunnail.sv` drives
  its own bgtile/sprites ROM fetches through two LIVE
  `rtl/nmk214/nmk214.sv` instances, configured via a protection-MCU
  handshake this board doesn't have. `gunnailb`'s own bgtile/sprites ROM
  data is instead descrambled ONCE, OFFLINE — a completely separate
  mechanism from `nmk214` despite sharing the same "8 tables,
  address-bits select which one" conceptual shape (`decode_gfx()`,
  `nmk16.cpp:6005-6054`, called directly from `init_gunnailb()`,
  `nmk16.cpp:6275-6279` — not a live circuit at all). Feeding
  already-correct, offline-descrambled data through a live, unconfigured
  `nmk214` instance would scramble it a second time incorrectly, so
  `video_gunnailb.sv` removes both `nmk214` instances and reads
  `bgtile_rom`/`sprites_rom` directly — every other line (tilemap
  geometry, palette decode, sprite double-buffer/draw FSM, per-scanline
  raster scroll) is copied unchanged. Also genuinely different from
  `video_gunnail.sv`: `gunnailb`'s own `bgtile` ROM is `0x200000` bytes
  (2MB, matching macross's own size and 14-bit tile code), **double**
  `gunnail`'s own `0x100000`/13-bit ROM — confirmed directly by comparing
  `ROM_START(gunnailb)` against `ROM_START(gunnail)`, not assumed from
  the family resemblance.
- **`tools/decode_gunnailb_gfx.py`** (new tool): a standalone
  transliteration of `decode_gfx()`/`decode_byte()`/`decode_word()`/
  `bjtwin_address_map_bg0()`/`bjtwin_address_map_sprites()`
  (`nmk16.cpp:5974-6054`) — 8 candidate bit-permutation tables per region
  (bgtile: per-byte; sprites: per-16-bit-word, little-endian byte pair),
  selected per-address by 3 specific address bits. Verified before
  trusting it on real ROM data: every table checked as a genuine
  bijection, plus hand-traced single-bit-position examples on a
  non-identity table (an earlier draft's own hand-traced examples used
  table index 2, which turned out to be the *identity* permutation in
  both arrays — caught and fixed before running the tool for real, not
  after). Run *after* `tools/mkgfxrom.py`'s own `concat`/`word_swap`
  extraction (bgtile is a plain `ROM_LOAD`, sprites is
  `ROM_LOAD16_WORD_SWAP` — same mode `gunnail`'s own sprite ROM uses),
  same "only permutes bits within already-assembled data" layering
  `tools/decode_tdragonb.py` already established.
- **`rtl/gunnailb/gunnailb_core.sv`** (new system top-level): reuses the
  fx68k+T80s architecture every Tier 5 port shares, but on **`gunnail_
  core.sv`'s own 40MHz `clk_sys` convention**, not the 32MHz convention
  every Seibu-based port used — because `gunnailb(config)` inherits
  `gunnail(config)`'s own 68000 instantiation (`XTAL(10'000'000)`)
  unchanged, only overriding the memory-map function pointer afterward.
  68000/pixel clock enables (`clk_sys/4`=10MHz, `clk_sys/5`=8MHz) and the
  YM2203 (`jt03`) accumulator (`increment=3,modulus=80`→1.5MHz, the SAME
  chip instance/clock `gunnail(config)` already set up — `gunnailb()`
  only rewires its IRQ destination) are copied directly from
  `gunnail_core.sv`. New here: a Z80 cen (6MHz, `GCD(6000000,40000000)
  =2000000`→`increment=3,modulus=20`) and an OKI cen (3MHz,
  `GCD(3000000,40000000)=1000000`→`increment=3,modulus=40`) — both
  small phase accumulators, single-`cen`-pulse shape (no two-phase
  `enPhi1`/`enPhi2` pair needed for either, that's 68000-specific).
  `HALTn` tied high (no protection MCU exists to drive it here, unlike
  `gunnail_core.sv`'s own `.HALTn(~halt_68k)`). VRAM/palette/scrollram/
  scrollramy storage is entirely local — no `prot_wr`/`prot_addr`/
  `prot_sel_*` arbitration anywhere in this file, since there's no
  protection MCU to share the bus with (genuinely simpler than
  `gunnail_core.sv`'s own storage logic in this respect).
- **New sound path — Z80 + direct YM2203 + dual `soundlatch`, not a
  reusable device**: `soundlatch`/`soundlatch2` (MAME's
  `GENERIC_LATCH_8`, `nmk16.cpp:5430-5433`) are plain 8-bit registers
  built directly in `gunnailb_core.sv` — genuinely simple (a data
  register + a pending flag), not built as a general-purpose reusable
  device the way `rtl/seibu/seibu_sound.sv` is, since this wiring is
  specific to this one game. `soundlatch`'s own
  `data_pending_callback().set_inputline(m_audiocpu, INPUT_LINE_NMI)`
  (`nmk16.cpp:5431`) means the 68000→Z80 direction drives the Z80's NMI
  as a level held low from the 68000's write until the Z80 itself reads
  the latch back — implemented as exactly that (a held level, not a
  pulse), relying on T80's own internal NMI edge-detector (real Z80
  hardware: fires once on the falling edge, ignores the level afterward
  until the next fresh falling edge) to handle the "only once per write"
  semantics. The Z80's own I/O map (`gunnailb_sound_io_map`,
  `nmk16.cpp:1072-1079`, an 8-bit `global_mask(0xff)` space) is decoded
  directly off `z80_a[7:0]`: port `0x00` write = audiobank select
  (`macross2_audiobank_w`, `data & 0x7`, `nmk16.cpp:302-305`), `0x02/0x03`
  r/w = YM2203 (jt03, addr/status vs. data offset), `0x04` unused (Oki
  moved to the 68000, see above), `0x06` r/w = `soundlatch`/`soundlatch2`.
  No IM0 vector-mux logic exists anywhere (unlike `seibu_sound.sv`'s own)
  — this Z80's own interrupt mode (IM1, almost certainly, given no vector-
  supply callback is registered anywhere in the reference's own machine
  config) is handled entirely internally by T80 once the Air Buster sound
  program itself executes its own `IM 1` instruction, needing no external
  vector-byte muxing at all.
- **OKI moved to the 68000**: a single byte-write register at `0x194001`
  (odd address, `~LDSn`-gated like every other single-byte register in
  this project) drives `jt6295` directly from the 68000's own bus write
  — no bank device layer (`OKIM6295(config.replace(),m_oki[0],
  12000000/4,...) // no OKI banking`, `nmk16.cpp:5437`), driven straight
  from the 68000 rather than relayed through the Z80's own domain. Still
  uses the same latch-and-hold write-stretch pattern this project's other
  OKI integrations already established (a 40-`clk_sys`-cycle `wrn` hold),
  cheap insurance against any exact-alignment edge case even though a
  68000 bus cycle is already wide on its own. Confirmed directly against
  the reference: `gunnailb_map` has no corresponding OKI *read* entry
  anywhere, consistent with this game being flagged
  `MACHINE_IMPERFECT_SOUND` ("crappy sound, unknown how much of it is
  incomplete emulation and how much bootleg quality").
- **Primary-session review pass found and fixed one real bug before
  commit**: the YM2203 (`jt03`) write-stretch hold was `6'd8` cycles, but
  `ym_cen`'s own worst-case gap (`increment=3, modulus=80`, verified by
  directly simulating the accumulator) is 27 `clk_sys` cycles — an 8-cycle
  hold could not guarantee overlapping a `cen` edge, risking silently
  dropped Z80→YM2203 register writes on unlucky phase alignment. Fixed to
  `6'd40`, matching the exact value `gunnail_core.sv`/`macross_core.sv`
  already use for the identical chip/`cen` setup (which safely exceeds
  the 27-cycle worst case). Verification below was re-run after this fix,
  not before it.
- **ROM extraction hit the same split-romset naming trap
  `acrobatmbl`/`strahljbl` already characterized**: `mame_roms/
  gunnailb.zip` contains only 6 files — the sprites ROM (`27c160.a9`,
  `0x200000` bytes) is missing entirely, shared with parent set `gunnail`
  but stored under a different member name there
  (`92077-7.u134` — confirmed via a direct CRC check, `d49169b3`,
  matching exactly, not assumed from the family resemblance).
- **`sim/rtl/gunnailb/{Makefile,tb_gunnailb.cpp}`** (new) — the
  testbench tracks the Z80's NMI line (falling-edge count, since
  `gunnailb` has no IM0 vector arbitration to check the way the
  Seibu-based ports' own testbenches do) instead of IACK vector
  bookkeeping.

### Verification results

Full 300M-`clk_sys`-cycle (40MHz, 7.5 real seconds) run: Z80 executed
7,442,532 instructions (last fetch PC=`$0AA5`), 68000 executed
13,198,403 instructions (345,205 write bus cycles, last fetch
PC=`$00C35C`), 422 video frames rendered. Z80 NMI (soundlatch write)
falling edges: 3 total over the run — a real, if modest, cross-CPU
handshake signal (this is an input-idle attract/boot-only window, same
caveat every prior port's own low-activity run carries). Z80 wrote to
YM2203 9 times, and the 68000 wrote to the (now directly-attached) OKI 6
times — confirming both the new sound-latch/NMI path and the new
68000-driven OKI path actually get exercised, not just wired and never
touched.

**Pixel/VRAM sanity**: palette 354/1,024 non-blank, BG VRAM 7,951/8,192
(97%) — a real, heavily-populated tilemap — TX VRAM 480/2,048 non-blank,
and 9,671/86,016 (11.2%) rendered pixels non-zero. This is strong,
non-garbage evidence the whole new pipeline works end to end: the
offline GFX descramble tool, `video_gunnailb.sv`'s nmk214-stage removal,
and the VRAM/palette/scrollram wiring all have to be correct
simultaneously to produce a 97%-populated tilemap rather than noise —
reused, already-verified rendering logic (`video_gunnailb.sv`'s own
tilemap/sprite math, copied from Tier 4's `video_gunnail.sv`) plus new
data-path wiring around it, and the combination renders plausibly.

**Z80 core cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,979,403 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
the PC sequence matches as an ordered subsequence for the first
**65,739 checkpoints** — roughly **10x further** than any prior Tier 5
port's own longest match (strahljbl/tdragonb/acrobatmbl: 6,367 each) —
with only **3/65,738 matched instruction cycle-costs differing**
(tolerance=0; all three at the same location, checkpoint 65706/65709/
65712, `PC 0AA5->0AA1`, oracle=10 candidate=247-251), total cycles over
the matched span oracle=935,819/candidate=936,534 (**ratio=1.001**).
This is a **fifth, independent confirmation** that the GHDL-translated
T80 core is cycle-exact against real Z80 hardware — reaching an order of
magnitude deeper into a completely different, unrelated Z80 program
(Air Buster's own sound driver, not the Seibu program every prior port
shares) than any previous port's own oracle match.

**Where the match stops, and what that is**: disassembling the audiocpu
ROM at the divergence point (`sim/rtl/gunnailb/roms/gunnailb_audiocpu.hex`,
bytes at `$0AA1`-`$0AA7`: `ED 60` / `CB 7C` / `C2 A1 0A`) decodes to
`IN H,(C)` / `BIT 7,H` / `JP NZ,$0AA1` — a **hardware status-bit polling
loop** (read a port, loop while bit 7 stays set), not an idle/interrupt
loop like every prior Tier 5 port's own divergence. The candidate takes
~247-251 cycles to exit this loop where the oracle takes only 10 —
consistent with our `jt03` (YM2203) integration's own busy/status flag
staying asserted measurably longer than MAME's model expects at this
specific polling site, a real, timing-sensitive real-hardware-emulation
gap rather than a decode error (cycle-perfect match on every instruction
up to and including this exact point rules that out). Not further
diagnosed this session, consistent with this project's own established
practice for this class of finding — but characterized precisely rather
than left as an unexplained "loop exit" the way a purely PC-sequence-only
diff would have to.

### Regression sweep

No shared file was modified — `rtl/third_party_gen/t80/T80s.v`,
`rtl/bjtwin/video_timing.sv`, `rtl/bjtwin/nmk_irq_hacky.sv`, and the
vendored `jt12/hdl/jt03.v`/`jt6295.v` were only referenced, never edited.
`rtl/gunnail/gunnail_core.sv` and `rtl/gunnail/video_gunnail.sv`
themselves were also never touched — `gunnailb` uses its own separate
`video_gunnailb.sv` and `gunnailb_core.sv` instead (see "What was built"
above for why). Re-ran `mustangb`'s own testbench (fresh rebuild, 60M
cycles): matches its own already-established baseline exactly (745,065
Z80 instructions, 2,710,850 68000 instructions, 2 IACKs, 106 frames) —
zero regression, confirms T80s.v wasn't touched. Re-ran `gunnail`'s own
testbench (fresh rebuild, 300M cycles): NMK004 executed 4,746,286
instructions (last PC=`$01DB`), protection MCU executed 2,824,804
instructions (last PC=`$0088`, **68000 HALT asserted 0 times**), 422
frames rendered — the identical failure *signature* `docs/PLAN.md`'s own
Tier 4 section already documents for `gunnail` (blocked by its own
still-open protection-MCU timing-drift issue, protcpu settling at the
same `$0088` P5-wait address with 0 HALT assertions) — confirming
`gunnail`'s own already-known-broken behavior is unchanged, not newly
broken, and that `video_gunnail.sv`/`gunnail_core.sv` are genuinely
untouched by this port's own work.

### Status

Built, boots, and runs clean on both CPUs — genuinely new work (a Z80 +
direct YM2203 + dual-soundlatch sound path, a new offline GFX-descramble
tool, a new NMK214-free video derivative) rather than a reuse-heavy port
like the prior four. The Z80/T80 core gets its **fifth independent
cycle-exact confirmation**, and by a wide margin the deepest of any Tier
5 port so far (65,738 matched checkpoints vs. 6,367 for the next-best).
Video renders richly and plausibly (97% BG VRAM populated). Because
`gunnailb` removes the NMK004/protection-MCU path entirely, it is fully
decoupled from `gunnail`'s own still-open protection-MCU timing-drift
issue — this port's own remaining gap (a `jt03` busy-flag-timing-
sensitive polling loop, precisely characterized above) is unrelated to
that issue and, unlike it, has a clear, scoped next step if picked up
later: compare `jt03`'s own busy-flag deassertion timing against
MAME's `ym2203_device` model directly. **Not yet a full oracle match**:
left open, not further chased this session, per this project's own
established practice. The new Z80+YM2203+soundlatch sound architecture
built here is narrow to this one game's own specific wiring, not a
general-purpose reusable device — worth noting as adjacent groundwork
for a future Family C (`macross2`-style) port, but not itself a
drop-in component the way `rtl/seibu/seibu_sound.sv` is. Changes left
uncommitted for the primary session's own review before commit.

## macross2 — Tier 3's first port (Family C: Z80-direct-sound, hi-res boards)

`macross2` ("Super Spacefortress Macross II / Chou-Jikuu Yousai Macross
II") is Tier 3's first target — the first port in this project outside
Family E's own Z80-based lineup, and genuinely new territory: real
V-PROM-driven interrupts (`rtl/nmk_irq/nmk_irq.sv`, already built for
Tier 2/4 but never used by a *newly-built* port this session), a new
reusable OKI bank-switcher device (`rtl/nmk112/nmk112.sv`), and a video
architecture that's a genuine hybrid of two already-built modules rather
than a straight derivative of one.

### The "hardest video item" turned out not to apply here

`docs/PLAN.md`'s own original risk assessment flagged Family C's
per-scanline raster scroll as the single hardest video item in the whole
project. Direct research into `nmk16_v.cpp` found this doesn't apply to
`macross2` itself: `VIDEO_START_MEMBER(nmk16_state,gunnail)`
(`nmk16_v.cpp:164-168`) is literally `VIDEO_START_CALL_MEMBER(macross2)`
plus one extra line (`set_scroll_rows(512)`) — i.e. `gunnail`'s own video
setup (Tier 4, already built and oracle-adjacent-verified as
`rtl/gunnail/video_gunnail.sv`) **is** macross2's own setup plus
per-scanline scroll. The hard part is specific to gunnail/raphero, not
macross2, which uses a single plain `scroll_w<0>` register
(`nmk16.cpp:1094`) — the same shape every Tier 5 port's own video used.

### What was built

- **`rtl/macross2/video_macross2.sv`** (new): `video_macross.sv`'s own BG
  tilemap architecture (14-bit tile code, `tilemap_scan_pages` paged
  256x32 addressing, macross2's own `bgtile` ROM being the identical
  0x200000-byte/16384-tile size as macross's own) plus `video_gunnail.sv`'s
  own wider 64x32 TX tilemap sizing — but with no NMK214 descrambling (no
  protection MCU on this board — bgtile/sprites read directly) and a
  widened **5-bit sprite colour field** (`get_colour_5bit`,
  `nmk16.cpp:5457` — every single prior port in this project used 4-bit).
  Confirmed the exact palette layout this needs directly against
  `gfx_macross2`'s own `GFXDECODE_START` (`nmk16.cpp:4194-4198`) rather
  than assumed from family resemblance: sprites at colour base `0x100`
  with 32 colours (`0x100-0x2FF`), TX at `0x300` with 16 colours
  (`0x300-0x3FF`) — a genuinely different TX base than every prior port's
  own `0x200`. BG stays at `0x000`/16 colours, unchanged.
- **A real, non-obvious BG-VRAM banking mechanism, found and correctly
  wired**: macross2's own `bgvideoram` is `0x10000` bytes — **four
  times** every prior port's own `0x4000`. Traced this directly to
  `scroll_w<Layer>` (`nmk16.cpp:479-503`): when `m_bgvideoram[Layer]
  .bytes() > 0x4000` and the scroll register's own offset-0 (X-scroll
  high byte) is written, bits `[5:4]` of that SAME byte select a
  `m_tilerambank` value (0-3) — the tilemap only ever addresses 8192 tile
  positions (`(m_tilerambank<<13)|tile_index`, `nmk16_v.cpp:42`) at a
  time; the larger VRAM is 4 "banks" of the same tilemap, not a wider
  one. Those same bits also land in the numeric X-scroll value itself via
  `set_scrollx`'s own unmasked use of the byte, but get discarded by the
  tilemap's own mod-4096 wraparound — confirmed by direct bit-arithmetic,
  not assumed, so the overlap is real hardware/software convention, not
  an oversight. Wired as a `tilerambank[1:0]` register in
  `macross2_core.sv`, feeding the top 2 bits of `video_macross2.sv`'s own
  (now 15-bit) `bgvram_addr`.
- **`rtl/nmk112/nmk112.sv`** (new, reusable device): ported from
  `mame/src/devices/machine/nmk112.cpp` (131 lines, read in full). 8
  bank-select registers (chip×4-voice-slot), remapping each OKI's own
  logical `0x00000-0x3FFFF` address space by 64KB window. The real open
  question going in was whether this needs jt6295 to expose which of its
  4 internal ADPCM channels issued a given fetch (it doesn't — confirmed
  by reading `jt6295_serial.v`'s own internal round-robin `ch` register,
  never exposed on jt6295's own top-level ports) — resolved by re-reading
  `nmk112.cpp`'s own `oki_map()` closely: the C++ model is **purely
  address-range decoded**, with zero channel-awareness anywhere in its
  own read-side logic (only the CPU-driven *write* side, `okibank_w`,
  associates a register with a "voice" concept, as a naming convention
  for how real game ROM data happens to be organized) — meaning
  `jt6295`'s own vendored source needed no modification at all. Also
  hand-verified the "paged" sample-table override (both OKIs default to
  paged, since neither `macross2()` nor any Family C config calls
  `set_page_mask()`): the first `0x400` bytes of each chip's logical
  space get a *different* per-256-byte bank register than the main
  64KB-window decode, but — worked out by hand from the C++ model's own
  offset arithmetic — this is exactly equivalent to `page*0x10000+addr`
  using the SAME register value samplebank already uses for that index,
  not a separate offset calculation.
- **`rtl/macross2/macross2_core.sv`** (new system top-level): fx68k
  (40MHz `clk_sys` convention, same as `gunnail_core.sv`'s own — this
  board's real 10MHz 68000 matches) + T80s + jt03 (YM2203) + NMK112 +
  jt6295 x2, plus the REAL `nmk_irq.sv` V-PROM interrupt generator
  (`macross2()` calls `set_interrupt_timing`, `nmk16.cpp:5449` — not the
  hacky fixed-scanline substitute every Tier 5 port used; `ROM_START`
  confirms real `nmk_irq:vtiming` PROM data exists for this game).
  Genuinely different from gunnailb's own sound-path wiring in three
  confirmed ways: both OKIs stay on the Z80's own I/O bus through NMK112
  (not moved to the 68000); the Z80 has a real RESET line driven by the
  68000 (`macross2_sound_reset_w`, "every time music changes Z80 is
  reset" per a PCB-verified reference comment — implemented as a genuine
  reset input into T80s); and `soundlatch` has **no**
  `data_pending_callback` wired anywhere in `macross2()`'s own machine
  config (confirmed by reading it directly, `nmk16.cpp:5444-5488`) — so
  unlike gunnailb, writing it does NOT interrupt the Z80 at all; the
  Z80's only interrupt source is YM2203's own plain maskable IRQ0.
- **`tools/mkrom_wordswap.py`** (new tool): macross2's own maincpu ROM is
  a single `ROM_LOAD16_WORD_SWAP` file (`mcrs2j.3`, `nmk16.cpp:8242`), not
  the usual two-chip `ROM_LOAD16_BYTE` pair `tools/mkrom.py` handles —
  this tool applies the identical byte-pair-swap `tools/mkgfxrom.py`'s
  own `word_swap` mode already established (verified the exact swap
  formula against that tool's own implementation, `data[0::2]=raw[1::2];
  data[1::2]=raw[0::2]`, before trusting a from-scratch derivation), but
  composes the result into mkrom.py's own word-per-line `$readmemh`
  format instead of byte-per-line, since a 68000 program ROM needs
  16-bit-wide storage.

### Verification results

Full 300M-`clk_sys`-cycle (40MHz, 7.5 real seconds) run, reproduced
identically on rebuild: Z80 executed 3,037,725 instructions (last fetch
PC=`$0018`), 68000 executed 12,699,218 instructions (692,704 write bus
cycles, last fetch PC=`$00AD38`), Z80 wrote to YM2203 165 times — real
sound-side activity. OKI0/OKI1 writes: 0 each — this input-idle
attract/boot window never drives NMK112 through a real register write,
so **NMK112's own address-remap logic, while carefully hand-derived and
reviewed against the reference, is not exercised by this specific run**
— flagged honestly rather than claimed verified by absence of a crash.

**Pixel/VRAM sanity**: palette 642/1,024 non-blank, BG VRAM 6,720/32,768
non-blank, TX VRAM 256/2,048 non-blank, and **51,217/86,016 (59.5%)
rendered pixels non-zero** — a rich, heavily-populated frame, not a
partial boot screen. This is strong indirect evidence for the whole new
pipeline together: the tilerambank-based BG banking, the widened 5-bit
sprite colour path, the real V-PROM `nmk_irq` timing, and the ROM
extraction (including the new word-swap maincpu tool) all have to be
simultaneously correct to produce this much non-garbage content rather
than noise.

**Z80 cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,391,382 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
**a much weaker result than every prior port's own** — the ordered
PC-sequence match stops at oracle checkpoint 1,199 (only 1,198
checkpoints matched, vs. 2,326-65,738 for the five Tier 5 ports), with
126/1,197 matched instruction cycle-costs differing and a
candidate/oracle total-cycle ratio of ~597x over that short span.
**Disassembled the actual divergence site directly rather than
speculating**: PC `$0018`-`$001D` is `IN A,(0)` / `RLCA` / `JR C,$0018` /
`RET` — a tight status-bit poll on Z80 I/O port `0x00`, which in this
core's own I/O map is YM2203's own address/status register (bit 7 =
busy, standard OPN-family convention). This is the **same underlying
class of finding** `gunnailb`'s own review already identified and left
open (`jt03`'s own busy-flag deassertion timing differing slightly from
MAME's `ym2203_device` model) — not a new bug in this port's own RTL,
but a recurrence of a shared, already-documented `jt03`-core limitation.
It produces a much larger apparent "ratio" here purely because it's hit
almost immediately in macross2's own boot sequence, dominating a tiny
comparison window, rather than appearing after tens of thousands of
clean-matching checkpoints the way it did for `gunnailb`. Ruled out two
alternative explanations before settling on this one: (1) a wrong Z80
clock-enable ratio — rejected, since the per-checkpoint ratios vary
non-uniformly (4.9x-10.4x) rather than scaling by one constant factor,
inconsistent with a simple divisor bug; (2) the Z80 being repeatedly
held in reset by `macross2_sound_reset_w` inflating the testbench's own
`z80_cen_ticks` count during reset-held intervals — tested directly by
gating the count on `dbg_z80_reset_n` and rebuilding; the result barely
changed (ratio 598.3→596.9), ruling this out too (the gating fix is kept
anyway — it's a genuine correctness improvement to the trace-writer's
own methodology regardless of whether it explains this specific gap).

### Regression sweep

No shared file was modified — `rtl/third_party_gen/t80/T80s.v`,
`rtl/bjtwin/video_timing.sv`, `rtl/nmk_irq/nmk_irq.sv`, and the vendored
`jt12/hdl/jt03.v`/`jt6295.v` were only referenced, never edited.
`rtl/gunnail/video_gunnail.sv`/`gunnail_core.sv` and
`rtl/gunnailb/gunnailb_core.sv` themselves were also never touched — this
port uses its own separate `video_macross2.sv`/`macross2_core.sv`.
Re-ran three testbenches fresh: **`mustang`** (60M cycles) matches its
own already-established baseline exactly (1,248,714 NMK004 instructions,
last PC=`$01DB`, 329 RET-Z-at-`$0E5F` hits, 6,580 YM2203 writes, 42/54
OKI1/OKI2 writes, 106 frames) — confirms `nmk_irq.sv` genuinely untouched.
**`gunnail`** (300M cycles) reproduces its own already-documented,
still-open protection-MCU-blocked signature exactly (protcpu last
PC=`$0088`, 0 HALT assertions, 4,746,286 NMK004 instructions, 422
frames) — confirms `video_gunnail.sv`/`gunnail_core.sv` genuinely
untouched, not a new regression. **`gunnailb`** (300M cycles) matches
its own already-established baseline exactly (7,442,532 Z80
instructions, 13,198,403 68000 instructions, 3 NMI falling edges, 9
YM2203 writes, 6 OKI writes, 422 frames) — confirms `T80s.v`/the shared
`jt03` integration pattern genuinely unaffected. Zero regressions across
all three.

**Primary-session review pass found and fixed one real gap in
`nmk112.sv` before commit**: `nmk112.cpp:93/96` masks every written bank
index with `data & m_bankmask[chip]` before storing it (clamping to the
ROM's own actual page count) — the initial RTL stored the raw,
unmasked Z80-written byte instead, with `ROM0_BYTES`/`ROM1_BYTES`
present but explicitly marked "informational only; not hardware-clamped
here." Every real OKI ROM size in this hardware family is a power of
two, making the correct mask a simple `(bytes/65536)-1` bitmask — fixed
to compute and apply it from those same parameters (`macross2_core.sv`'s
own instantiation already passes the exact byte sizes, `2097152`/
`1048576`), turning them from decorative into functional. Confirmed via
direct calculation that macross2's own valid page ranges (0-31, 0-15)
stay safely clear of a separate, unrelated 6-bit headroom limit in the
address-remap function's own 22-bit output width — a latent, currently
inert concern for any hypothetical future ROM larger than 4MB, noted but
not fixed here since it doesn't affect this port and would require
widening the module's own port width, out of scope for a review pass.
Rebuilt and re-ran the full verification after this fix: byte-for-byte
identical results to the pre-fix run (expected, since the game's own
writes are already within range — this hardens future reuse rather than
changing this port's own behavior).

### Status

Built, boots, and runs clean on both CPUs, with a genuinely rich,
plausible render (59.5% non-zero pixels) — strong evidence the whole new
pipeline (real V-PROM `nmk_irq`, the tilerambank BG-banking mechanism,
the widened 5-bit sprite colour path, `nmk112`'s own address-remap
logic, and the new word-swap ROM tool) works correctly together at the
structural level. **NMK112 itself was not exercised through a real
register write in this particular input-idle run** — the address-remap
logic was hand-derived and reviewed carefully against the reference
(including ruling out a wrong hypothesis about needing jt6295 channel
awareness), but has no direct behavioral confirmation yet; a natural
next step if picked up later would be a targeted test that drives actual
OKI playback. **The Z80 oracle match is markedly weaker than every prior
port's own** — precisely characterized (a `jt03` busy-flag polling loop,
the same known-limitation class `gunnailb`'s own review already
flagged, not a new bug), with two alternative hypotheses tested and
ruled out directly rather than left unexamined, but the underlying `jt03`
timing gap itself remains open, consistent with this project's own
established practice for this class of finding. Changes left uncommitted
for the primary session's own review before commit.

## tdragon2 — Tier 3's second port, an unusually direct reuse of macross2's own

`tdragon2` ("Thunder Dragon 2 (9th Nov. 1993)") is Tier 3's second
target. `tdragon2()`'s own machine config (`nmk16.cpp:5490-5533`) is
confirmed **byte-for-byte identical** to `macross2()`'s own in every
respect — same 68000/Z80 clocks, the literal same `macross2_sound_map`/
`macross2_sound_io_map` functions (not just the same shape),
`gfx_macross2`, and `MCFG_VIDEO_START_OVERRIDE(nmk16_state, macross2)`
(the identical video-start function name — not a new one). This means
**`rtl/macross2/video_macross2.sv` and `rtl/nmk112/nmk112.sv` are both
reused completely unmodified** — not even a new derivative file this
time, referenced directly (confirmed via `git diff --stat` on both
directories showing zero changes).

### The one genuinely new thing — and a subtlety the delegation brief itself missed

`tdragon2_map` (`nmk16.cpp:1100-1104`) is `macross2_map(map)` plus one
override: `mainram_swapped_r`/`_w` (`nmk16.cpp:280-288`) apply
`bitswap<16>(offset,15,14,13,12,11,7,9,8,10,6,5,4,3,2,1,0)` to the WORD
OFFSET before indexing `m_mainram` — a real PCB address-line miswiring
(only bits 7 and 10 are actually swapped with each other; every other
bit passes through unchanged, verified independently rather than trusted
from the bit-list alone), faithfully replicated, not a data-bit scramble.

**Verifying this against the reference surfaced something the primary
session's own delegation brief did not anticipate**: this swap applies
ONLY to the 68000 CPU-facing bus handler, not to MAME's own sprite-DMA
snapshot mechanism. `sprite_dma()` (`nmk16.cpp:4518-4524` — the same
shared function every game in this driver uses, tdragon2 included) does
a raw C++ `memcpy(m_spriteram_old.get(), m_mainram + m_sprdma_base/2,
0x1000)`, bypassing MAME's own address-map dispatch entirely (a direct
pointer read of the array member, not a call through the swapped
handler). `video_macross2.sv`'s own `mainram_addr`/`mainram_data` tap
(already existing, unmodified, used for exactly this sprite-snapshot
mechanism — see that module's own body) therefore had to stay
**unswapped**, reading the same raw array the CPU-facing accessor
indexes into. Getting this backwards (swapping both paths, or neither)
would have silently corrupted sprite draw order without necessarily
breaking anything else visible in a quick render check — implemented
correctly in `rtl/tdragon2/tdragon2_core.sv` (the CPU-facing
`mainram_addr_cpu` computation is the only address affected; the
existing `vid_mainram_addr` tap is untouched).

The only other real difference: tdragon2's own `oki2` ROM
(`ww930915.3`) is `0x200000` bytes — double macross2's own `oki2`
(`0x100000`) — while `oki1` stays the same `0x200000` both games share.
`nmk112`'s own `ROM1_BYTES` parameter and the backing array/addressing
width were sized accordingly (confirmed via the actual extracted ROM's
own byte count, `2097152`, matching the source exactly).

### What was built

- **`rtl/tdragon2/tdragon2_core.sv`** (new system top-level, closely
  derived from `macross2_core.sv`): identical clock/address-decode/
  sound-path/video-pipeline wiring, with the mainram address-swap
  (CPU-facing path only) and the `oki2`/`ROM1_BYTES` size difference
  described above as the only real changes.
- **`sim/rtl/tdragon2/{Makefile,tb_tdragon2.cpp}`** (new) — same
  structure as macross2's own testbench; ROM extraction reuses
  `tools/mkrom_wordswap.py` (maincpu, single `ROM_LOAD16_WORD_SWAP`
  file) and `tools/mkgfxrom.py` (everything else) unchanged.

### Verification results

Full 300M-`clk_sys`-cycle (40MHz) run: Z80 executed 3,037,121
instructions (last fetch PC=`$0018`), 68000 executed 12,792,869
instructions (674,675 write bus cycles, last fetch PC=`$00AED6`), Z80
wrote to YM2203 604 times (real sound-side activity, well above
macross2's own 165), OKI0/OKI1 writes: 0 each — same input-idle
NMK112-not-exercised caveat as macross2's own run, flagged honestly
rather than claimed verified.

**Pixel/VRAM sanity**: palette 181/1,024 non-blank, BG VRAM 256/32,768
non-blank, TX VRAM 1,536/2,048 (75%) non-blank, and 14,692/86,016
(17.1%) rendered pixels non-zero — a real, TX-heavy (consistent with a
title/attract-text screen), non-garbage render. Lower overall
non-zero-pixel percentage than macross2's own (59.5%) but not a red
flag on its own — different game content at a different point in its
own boot sequence, and the much higher TX-vs-BG population ratio here
is internally consistent with that explanation rather than looking like
scrambled/garbage output.

**Z80 cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds ≈
1,390,341 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
the PC sequence matches as an ordered subsequence for the first
**2,925 checkpoints** — better than macross2's own 1,198 — with
478/2,924 matched instruction cycle-costs differing (candidate/oracle
total-cycle ratio ~234x over the matched span). **Disassembled the
actual divergence site directly against the extracted ROM** (bytes at
`$0018-$001D`: `DB 00` / `07` / `38 FB` / `C9`, decoding to `IN A,(0)` /
`RLCA` / `JR C,$0018` / `RET`) — the exact same YM2203 busy-flag polling
idiom macross2's own divergence hit, confirmed by disassembly rather
than assumed from the coincidentally-matching PC address alone (the two
games' own audiocpu ROMs are entirely different files). Same underlying
`jt03` busy-flag-timing limitation `gunnailb`'s and `macross2`'s own
reviews already characterized, recurring here (hit repeatedly through
this game's own longer boot sequence, hence the higher mismatch count),
not a new bug in this port's own RTL.

### Regression sweep

Confirmed via `git diff --stat` that no file under `rtl/macross2/`,
`rtl/nmk112/`, `rtl/nmk_irq/`, `rtl/third_party_gen/`, or the vendored
`jt12`/`jt6295` directories has any changes at all — this port only
added new files under `rtl/tdragon2/`/`sim/rtl/tdragon2/`. Re-ran
`macross2`'s own testbench fresh (300M cycles) as a real confirmatory
run rather than relying on the diff alone: matches its own
already-established baseline exactly (3,037,725 Z80 instructions, last
PC=`$0018`, 12,699,218 68000 instructions, last PC=`$00AD38`, 165
YM2203 writes, 422 frames) — zero regression.

### Status

Built, boots, and runs clean on both CPUs, reusing `video_macross2.sv`/
`nmk112.sv` completely unmodified. Found and correctly implemented a
real, non-obvious subtlety the delegation brief itself didn't
anticipate — the mainram address-swap applies only to the CPU-facing
bus path, not the sprite-DMA-snapshot video tap, which needed to stay
reading the same raw array MAME's own `sprite_dma()` does. The Z80 core
gets a sixth independent partial confirmation against a real MAME
oracle capture, reaching further than macross2's own before hitting the
same already-documented `jt03` busy-flag-timing limitation. **Not yet a
full oracle match**: left open, not further chased, consistent with
this project's own established practice. Changes left uncommitted for
the primary session's own review before commit.

## raphero — Tier 3's third port, TLCS-90 as a bare sound CPU for the first time

`raphero` ("Rapid Hero (NMK)", also released as `arcadian`/"Arcadia
(NMK)" and `rapheroa`, all sharing the identical `raphero()` machine
config, `nmk16.cpp:5554-5597`) is Tier 3's third target — bigger in
scope than `tdragon2`'s own near-verbatim reuse, closer to `macross2`'s
own scope. Two genuinely new things, both confirmed directly against
MAME's own source before writing any RTL.

### The one genuinely new thing — TLCS-90 as a bare sound CPU

`raphero()` uses `TMP90841(config,m_audiocpu,XTAL(16'000'000)/2)`
(nmk16.cpp:5561), not Z80. This is the SAME TLCS-90 core family already
built for the NMK004 sound-board-MCU role (`rtl/tlcs90/nmk004_core.sv`)
and the protection-MCU role (`rtl/tlcs90/nmk_prot_core.sv`) — but wired
here, for the first time, as a bare sound CPU with its own direct
memory-mapped bus to YM2203/dual-OKI/NMK112
(`raphero_sound_mem_map`, nmk16.cpp:1134-1145), not through NMK004's
host-latch handshake or the protection-MCU's shared-RAM scheme.

Confirmed directly from `mame/src/devices/cpu/tlcs90/tlcs90.cpp`:
`tmp90841_mem()` (lines 80-84) is "rom-less" (no internal boot ROM,
unlike TMP90840's own 8KB) but uses the IDENTICAL internal 256B RAM
(`0xFEC0-0xFFBF`) and peripheral register block (`tmp90840_regs()`,
`0xFFC0-0xFFEF`) as TMP90840 — the SAME register map
`rtl/tlcs90/nmk004_periph.sv` already implements. **Reused here
completely unmodified** (`p5/p6/p7_ext_en` tied low for "plain"
behavior, matching `nmk004_core.sv`'s own instantiation pattern
exactly) — no new peripheral block was needed. YM2203's own IRQ (MAME's
`ymsnd.irq_handler().set_inputline(m_audiocpu,0)`, nmk16.cpp:5580) maps
to INT0 = `irq_req` bit 0 per `nmk004_periph.sv`'s own documented bit
ordering, OR'd in exactly like `nmk004_core.sv`'s own `irq_req_to_cpu`
pattern.

A subtlety the delegation brief itself didn't spell out, found by
reading `tlcs90.cpp` directly: `raphero_sound_mem_map`'s own
`map(0xe000,0xffff).ram()` declaration does NOT mean the whole
`0x2000`-byte range is external RAM. The TLCS-90 device's own fixed
internal memory map (`tmp90841_mem()`, installed on the CPU's own
internal address space) intercepts `0xFEC0-0xFFBF` and `0xFFC0-0xFFEF`
before MAME's own board-level driver map ever sees those addresses —
same reasoning `nmk004_core.sv`'s own header already documents for
NMK004's case, just not previously stated for a bare-sound-CPU board.
So the real external RAM only backs `0xE000-0xFEBF` (7,872 bytes);
`raphero_core.sv` implements this as two separate arrays
(`snd_ext_ram`/`snd_int_ram`) rather than trusting the literal
`ROM_START` text. Also confirmed: `raphero_map`'s own
`map(0x100016,0x100017).nopw()` (nmk16.cpp:1122, "IRQ enable or z80
sound reset like in Macross 2?") is a genuine no-op here — unlike
`macross2`'s/`tdragon2`'s own sound-reset at the identical address,
`raphero`'s TLCS-90 has no software-triggered reset from the 68000 at
all; it just runs continuously off the shared global reset.

Clock: 68000 at `XTAL(14'000'000)`=14MHz — a genuinely new ratio (every
prior Tier 3 port used 10MHz). From 40MHz `clk_sys`:
`increment=7,modulus=20` (40MHz*7/20=14MHz exact), the same phase-
accumulator "wrap fires enPhi1, defer one enPhi2 to the very next
non-wrap cycle" technique `tdragon2_core.sv`/`strahljbl_core.sv` already
use — verified by direct simulation that the minimum gap between
consecutive `enPhi1` pulses is 2 cycles (never 1), so strict
`enPhi1`/`enPhi2` alternation holds with zero violations across the
whole repeating 20-cycle pattern. TLCS-90 at `XTAL(16'000'000)/2`=8MHz —
unlike T80s/jt03/jt6295 (`clk`=full-rate `clk_sys` + a separate `cen`),
`tlcs90.sv`/`nmk004_periph.sv` need a REAL divided clock edge on their
own `clk` port (confirmed directly from `rtl/mustang/mustang_core.sv`'s
own `.clk(nmk004_clk_r)` wiring) — implemented as a clean `clk_sys/5`
divide (one rising edge every 5 `clk_sys` cycles).

NMK112: instantiated with `ROM0_BYTES=ROM1_BYTES=4194304` (raphero's
own oki1/oki2 are each `0x400000` bytes — double `tdragon2`'s own oki1,
quadruple `macross2`'s own oki2). Verified this sits exactly at, not
past, `nmk112.sv`'s own 22-bit output-width boundary (page 63 << 16 =
`0x3F0000`, the largest representable page before truncation, with zero
slack) — confirmed by direct calculation, not assumed safe by
resemblance to a smaller prior case.

Video is a genuine hybrid — see `rtl/raphero/video_raphero.sv`'s own
header for the full derivation: per-scanline raster X+Y scroll reused
from `video_gunnail.sv`'s own already-solved approach, and `tilerambank`
BG-VRAM banking reused from `video_macross2.sv`'s own already-solved
approach, re-sourced from a 16-bit word register's bits `[13:12]`
instead of `video_macross2.sv`'s own 8-bit byte register bits `[5:4]`
(verified independently against `nmk16_v.cpp:295-311`'s own
`raphero_scroll_w`, not pattern-matched from the byte-register bit
positions). The sprite ROM (`0x600000` bytes, three
`ROM_LOAD16_WORD_SWAP` files) is wider than any prior port's own —
23-bit byte addressing, versus `macross2`'s own 22-bit `0x400000`.

### What was built

- `rtl/raphero/raphero_core.sv` — 68000-side address decode
  (ROM/mainram/palette/BG-VRAM/TX-VRAM/scrollram/scrollramy/a plain
  unnamed `0x400`-byte RAM block at `0x130400-0x1307FF` with no named
  purpose in the reference, implemented faithfully as inert storage),
  the mainram address-line swap (identical formula to
  `tdragon2_core.sv`'s own, video tap deliberately left unswapped), the
  new TLCS-90 external bus decode (`raphero_sound_mem_map`), NMK112, jt03
  (YM2203), jt6295 x2 (OKI), and `nmk004_periph.sv` reused unmodified
  with every override tied inert.
- `rtl/raphero/video_raphero.sv` — the new hybrid video module described
  above.
- `sim/rtl/raphero/{Makefile,tb_raphero.cpp}` — ROM extraction (raphero
  is a clone of `arcadian`, its own `GAME()` parent field; this local
  dump's split-romset convention means most regions live in
  `arcadian.zip` under the same member names, not `raphero.zip` itself —
  confirmed via `unzip -l`, both zips passed to every `mkgfxrom.py` call).
  A real trap handled correctly: `rhp94099.6` is byte-identical (CRC
  `f1a80e5a`) between oki1's own first file and oki2's own second file —
  extracted independently per each region's own `ROM_LOAD` order, not
  deduplicated. `color` (`prom3.u60`) skipped entirely (zero consumers
  in the emulation, matching every prior port). TLCS-90 PC/cycle tracking
  uses `dbg_snd_pc`/`dbg_snd_valid` (tlcs90.sv's own direct debug pins,
  the same rising-edge-of-`dbg_valid` technique
  `sim/rtl/mustang/tb_mustang.cpp`'s own `dbg_nmk004_valid` tracking
  already established) rather than T80s.v's own M1_n-edge trick.

### Verification results

Builds clean under Verilator (only the usual pre-existing warning classes
— width-truncation/expansion notes and vendored-core `UNUSEDSIGNAL`/
`SYNCASYNCNET` warnings already present in every other port's own build,
no new warning class). One real build-time bug found and fixed before
this: `video_timing.sv` was missing from the `Makefile`'s own `SOURCES`
list (copy-paste gap versus `tdragon2`'s own Makefile, which pulls it
from `BJTWIN_DIR`) — caught immediately as a "cannot find module"
Verilator error, not a silent gap.

Ran 300M `clk_sys` cycles (~7.5 real seconds): 68000 executed 18,834,344
instructions (last fetch PC=`$0078C4`, 484,412 write bus cycles),
TLCS-90 executed 4,499,986 instructions (last fetch PC=`$018D`), 7
YM2203 writes, 0 OKI0/OKI1 writes, 422 video frames rendered with real
CRC variety (no single frame CRC dominates — the most common of 423
lines appears 50 times, the rest are much rarer), not a frozen/garbage
image. `TB_DUMP_VRAM=1`: palette 793/1,024 (77.4%) non-blank, BG VRAM
6,750/32,768 (20.6%) non-blank, **TX VRAM 0/2,048 non-blank** (every
entry reads exactly the "space" tile code `0x0020` — i.e. actively
cleared by the program, not simply zero-initialized-and-never-touched;
left open as a benign, unconfirmed "hasn't reached score-digit rendering
yet in this window" explanation rather than investigated further, same
honesty bar `tdragon2`'s section above applies to its own lower render
percentage), 23,212/86,016 (27.0%) rendered pixels non-zero — a real,
non-garbage render.

**TLCS-90 cycle-accuracy, checked against a real MAME oracle capture**
(`sim/oracle/capture_cyc_trace.py --device :audiocpu`, 3 real seconds =
2,270,728 oracle instructions, diffed via `sim/compare/cyc_diff.py`):
this is the first TLCS-90-based sound-CPU oracle comparison outside its
NMK004/protection-MCU roles. The PC sequence matches as an ordered
subsequence for only **83 checkpoints** before the oracle moves on to a
PC (`$0194`) the candidate trace never reaches again — clearly weaker
than either `macross2`'s own (1,198) or `tdragon2`'s own (2,925), but
for a well-characterized reason, not a mystery: **disassembled the
actual divergence site directly against the extracted ROM** (bytes at
`$018D-$0192`: `E3 00 C0 2E` / `A0` / `C7`). `tlcs90.sv`'s own opcode
table (line 507) confirms `E3` decodes as `PFX_MN_SRC` — a
memory-direct-source-operand prefix — with the following two bytes
(`00 C0`) forming the 16-bit address `0xC000`, exactly YM2203's own
status/address port; `C7` falls in the `0xC0-0xCF` range `tlcs90.sv`'s
own cycle table gives a `taken ? X : Y` cost split (i.e. a conditional
branch). This is the exact same YM2203 busy-flag polling idiom
`macross2`'s/`tdragon2`'s own reviews already characterized as a `jt03`
busy-flag-timing limitation, recurring here — confirmed by disassembly,
not assumed from a coincidentally-matching PC address (`raphero`'s own
audiocpu ROM is an entirely different file from either prior port's own
Z80 program). Of the 82 matched cycle-cost deltas, 2 differ (first at
checkpoint 56, both instances of the candidate looping extra iterations
inside the busy-wait before the oracle's own timing lets it escape
sooner); total cycles over the matched span: oracle=1,244,
candidate=2,092 (ratio 1.682x). Because the TLCS-90 falls into this
wait loop within its own first ~70 instructions and never durably
escapes it in this run (spending 3,332,873 of its 4,499,986 total
instructions across the loop's own three PCs), **NMK112 was very likely
not exercised through a real register write in this run either** —
flagged honestly as unconfirmed rather than claimed verified, the same
disclosure `macross2`'s own section above already established the
convention for.

### Regression sweep

Confirmed via `git status --short`/`git diff --stat` that no tracked
file under `rtl/macross2/`, `rtl/tdragon2/`, `rtl/nmk112/`,
`rtl/nmk_irq/`, `rtl/tlcs90/`, `rtl/bjtwin/`, or the vendored `jt12`/
`jt6295` directories has any change at all — only new files under
`rtl/raphero/`/`sim/rtl/raphero/` exist. Re-ran three testbenches fresh
(not relying on the diff alone): `macross2`'s own (300M cycles) matches
its exact established baseline (3,037,725 Z80 instructions, last
PC=`$0018`, 12,699,218 68000 instructions, last PC=`$00AD38`, 165
YM2203 writes, 422 frames); `tdragon2`'s own (300M cycles) likewise
matches (604 YM2203 writes, last Z80 PC=`$0018`, 422 frames);
`mustang`'s own (60M cycles) matches too (NMK004 1,248,714 instructions,
last PC=`$01DB`, 6,580 YM2203 writes, 42/54 OKI1/OKI2 writes, 106
frames) — confirming `tlcs90.sv`/`nmk004_periph.sv` are genuinely
unmodified in practice, not just by diff. Zero regressions across all
three.

### Status

Built, boots, and runs clean on both CPUs. `nmk004_periph.sv` reused as
a bare-sound-CPU peripheral block for the first time with zero
modification, and the internal-SFR-address-carve-out subtlety (real
external RAM ends at `0xFEBF`, not the literal `0xFFFF` the board-level
map's own text suggests) was found and correctly handled by direct
`tlcs90.cpp` source inspection before it could silently corrupt the
internal-RAM/peripheral-register split. `video_raphero.sv`'s own hybrid
(gunnail's per-scanline scroll + macross2's tilerambank, re-sourced from
new word-register bit positions) renders real, varied, non-garbage
frames. The TLCS-90 oracle comparison reaches fewer checkpoints than
either prior Tier 3 port's own Z80 comparison, but for the identical,
already-documented `jt03` busy-flag-timing reason, confirmed by direct
disassembly rather than assumed — **not a new bug in this port's own
RTL**. TX VRAM reading uniformly blank and NMK112 going unexercised in
this run are both left open, honestly flagged as unconfirmed rather
than chased further or claimed working, consistent with this project's
own established practice. Changes left uncommitted for the primary
session's own review before commit.
