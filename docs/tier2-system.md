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
