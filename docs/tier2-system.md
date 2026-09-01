# Tier 2 — system-level integration (mustang: 68000 + NMK004)

Status: **Two integration milestones done and verified.** A real 68000
(fx68k, the same core Tier 1's `bjtwin_core.sv` already oracle-verifies) is
wired to the completed NMK004 sound board (`rtl/tlcs90/nmk004_core.sv`)
through the real shared-latch host handshake, in a top-level module,
`rtl/mustang/mustang_core.sv` — Milestone 1 answered the question CPU-only
verification (`sim/rtl/tlcs90/tb_nmk004.cpp`) structurally couldn't (does
NMK004 get *past* its host-handshake poll loop once a real 68000 is
attached? yes), and Milestone 2 (this update) gave the 68000 itself a real
interrupt source, unsticking a *second* stall this document's own
Milestone 1 had already predicted and characterized in advance. Verified
against the same MAME oracle trace used throughout Tier 2's CPU work, the
matched checkpoint count has gone 175 (CPU-only boundary) → 18,809
(Milestone 1) → **21,986** (Milestone 2) — over 125x the original
CPU-only ceiling.

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

3. **Third divergence (open, characterized, deferred): NMK004 matches the
   oracle up to `0x0E5F`, then diverges instead of continuing to
   `0x0E61`.** The RTL trace never reaches `0x0E61` at all — instead of
   continuing past `0x0E5F` into what the oracle shows as a call chain
   (`0x0066` → `0x02FF` → ...), the RTL returns to the `0x01DA`/`0x01DB`
   idle loop. Confirmed via a 4x-longer run (100,000,000 cycles) that this
   is *not* a "needs more time" situation like the first divergence was —
   the RTL stops at the exact same checkpoint regardless. The PC range
   just before the divergence (`0x0E4A`-`0x0E5F`, short 2-3-byte
   instruction spacing) has the shape of NMK004's own register-table-init
   loops seen earlier in the boot sequence (see
   `docs/tier2-tlcs90.md`'s "Second verification result" — the YM2203
   init loop uses the exact same idiom), strongly suggesting this is
   further FM/OKI register setup or status-bit polling — and
   `mustang_core.sv`'s YM2203/OKI ports are still plain register-latch
   stubs (see "What's built" above), always reporting a fixed idle byte
   rather than a real busy/status flag. A conditional branch testing that
   status bit taking the *stub's* value instead of what real silicon
   would report is a plausible, consistent explanation for a clean
   divergence right at this boundary — not proven by a bus-level trace
   the way the two earlier bugs were, but consistent with everything
   observed and with the next already-documented scope boundary (real
   `jt12`/`jt6295` audio). Flagged as the first thing to check when that
   work begins, not chased further in this milestone.

Re-confirmed all existing Tier 2 regressions (175-checkpoint CPU oracle
match, 211-fire interrupt self-test, and every synthetic CPU-opcode test
this session built) unchanged, and Tier 1's own `bjtwin_core.sv` build
still succeeds using the same `video_timing.sv`/`nmk_irq_hacky.sv` files
now shared between the two families.

## Next step

Real `jt12`/`jt6295` audio integration is the most promising next
increment given the third divergence's own likely cause — even a
register-level-accurate (not necessarily audio-sample-accurate) status/
busy-bit model might be enough to get past it. The real PROM-driven
`nmk_irq` scanline state machine (replacing this milestone's synthetic
substitution) and mustang's own video/sprite pipeline (Family B's
tilemap variants, distinct from Tier 1's bjtwin/Family A ones) remain
separate, larger increments beyond that.
