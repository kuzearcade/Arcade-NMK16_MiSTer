# Tier 2 — system-level integration (mustang: 68000 + NMK004)

Status: **Three integration milestones done and verified.** A real 68000
(fx68k, the same core Tier 1's `bjtwin_core.sv` already oracle-verifies) is
wired to the completed NMK004 sound board (`rtl/tlcs90/nmk004_core.sv`)
through the real shared-latch host handshake, in a top-level module,
`rtl/mustang/mustang_core.sv` — Milestone 1 answered the question CPU-only
verification (`sim/rtl/tlcs90/tb_nmk004.cpp`) structurally couldn't (does
NMK004 get *past* its host-handshake poll loop once a real 68000 is
attached? yes), Milestone 2 gave the 68000 itself a real interrupt source,
unsticking a *second* stall Milestone 1 had already predicted and
characterized in advance, and Milestone 3 replaced the YM2203 stub with
the real `jt03` core (jotego's YM2203 clone) — a real, verified bus/IRQ
integration that did *not*, on investigation, turn out to be the cause of
the current oracle divergence (Milestone 2's own guess about that was
wrong, and Milestone 3 both proves it and pins down the actual divergent
instruction precisely — see Milestone 3 below). Verified against the same
MAME oracle trace used throughout Tier 2's CPU work, the matched
checkpoint count has gone 175 (CPU-only boundary) → 18,809 (Milestone 1)
→ **21,986** (Milestones 2 and 3 — unchanged by 3, see below) — over 125x
the original CPU-only ceiling.

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

3. **Third divergence (open, now *precisely* characterized): a `RET Z`
   at `0x0E5F` takes the opposite branch from the oracle.** Originally
   described (before Milestone 3 investigated it directly) as "NMK004
   diverges instead of continuing to `0x0E61`", which undersold what's
   actually happening: the RTL's trace *does* reach `0x0097` shortly
   after `0x0E5F` — the same place the oracle eventually reaches too —
   just by a different, shorter path, skipping the oracle's own
   `0x0E61`→`0x0E62`→`0x0E64`→`0x0E66` steps entirely. Reading the ROM
   directly at `0x0E5F` identifies the instruction precisely: `FE D6` is
   `RET Z` (the `0xf8-0xfe` group's second `RET cc` encoding, `cc=Z` —
   see `docs/tier2-tlcs90.md`'s "Third verification result" for how that
   encoding was originally found). The two instructions immediately
   before it (`F9 65` = `XOR A,C`, `E2 64` = `AND A,(HL)`) set the `Z`
   flag this `RET Z` tests — a classic "test whether specific bits in a
   status byte are clear" idiom, `AND` against a bitmask already loaded
   into `A`. Since both traces reach `0x0097` regardless of which way
   this branch goes, the *program itself* doesn't get stuck — but the
   subsequence-diff methodology (see `docs/tier2-tlcs90.md`'s "Second
   verification result" for why an ordered-subsequence match is used at
   all) correctly reports a divergence here anyway, since the oracle's
   own checkpoints at `0x0E61`/`0x0E62`/`0x0E64`/`0x0E66` never appear
   anywhere in the RTL's trace at all if that branch is never taken.
   **Milestone 2's own speculation that this was a YM2203/OKI status-bit
   poll was wrong** — `AND A,(HL)` reads plain memory through `HL`, not a
   YM2203/OKI bus register directly, and Milestone 3 (below) proves it
   independently by making YM2203 real without changing this checkpoint
   at all. The real cause — why the `Z` flag differs, i.e. what's
   actually stored at the tested `HL` address and why it's expected to
   read as an all-clear bitmask here even though it apparently doesn't —
   remains open, and needs the same kind of register/RAM-state trace
   this session's CPU-only opcode work never needed (every synthetic
   self-test built its own expected values from scratch; this is the
   first divergence requiring reconstructing what a specific *real
   firmware* memory location should already contain by this point in
   execution).

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

## Next step

The third divergence (`RET Z` at `0x0E5F`) is now the clear next thing to
resolve, and needs different tooling than anything built so far this
session: a way to inspect NMK004's own live register/RAM state (at least
`A`, `HL`, and the byte at whatever address `HL` holds at that point)
against the same state in MAME's own emulation, since the oracle's PC
trace alone can't say *why* the tested byte differs. Real `jt6295`
(OKI x2) audio integration — needing actual ADPCM sample ROM data
extracted and wired through a ROM interface `jt03` doesn't have — the
real PROM-driven `nmk_irq` scanline state machine (replacing the
synthetic substitution from Milestone 2), and mustang's own video/sprite
pipeline (Family B's tilemap variants, distinct from Tier 1's
bjtwin/Family A ones) remain separate, larger increments beyond that.
