# Tier 2 — TLCS-90 CPU core (NMK004 sound MCU)

Status: **RTL in progress, real verified execution.** Register file (now including
IX/IY), flags, condition codes, and a two-level fetch/decode/execute FSM cover the
full base opcode table, all six "(gg)"/"(mn)"/"($FF00+n)" prefixed opcode groups, and
the `(ix+d)`/`(iy+d)`/`(sp+d)`/`(HL+A)` indexed-addressing groups plus the
register-to-register `0xf8-0xfe` group (which turned out to be where plain `ADD A,r`-
style forms and a second `RET cc` encoding actually live — not covered by anything
implemented earlier). Verified against a real MAME oracle: **175 real instructions
match MAME's own CPU core exactly**, running the actual NMK004 boot ROM chained into
`mustang`'s real firmware, reaching all the way to the point where the firmware
legitimately blocks polling `($FB00)` for a byte only the real 68000 host would ever
write — the natural boundary for a CPU-only oracle comparison, not a bug (confirmed:
the RTL's own polling loop content matches the oracle's exactly, both looping
forever for the same reason). See "Third verification result" below.

## Why this exists

NMK004 (used by mustang, bioship, vandyke, blkheart, acrobatm, strahl, tdragon,
hachamf, macross, gunnail, manybloc, + several Afega Mustang-hacks) is not custom
sound silicon — it's a Toshiba **TMP90C840AF**, a member of the **TLCS-90** 8-bit
MCU family, running a fixed 8KB internal boot ROM plus a per-game external program
(up to ~56KB). The same TLCS-90 core is reused in Tier 4 as the NMK-110/113/215
protection MCU (different peripheral wiring, same CPU). No open-source TLCS-90 FPGA
core exists (confirmed by web search during the original project-planning pass) —
this is a from-scratch CPU, the single largest new-component effort in the project.

## ROMs

Two distinct ROM images per NMK004-based game, both already present in `mame_roms/`:

- **`nmk004.zip` → `nmk004.bin`** (8192 bytes, CRC `8ae61a09`) — the fixed internal
  boot ROM, identical across every NMK004 game (it's a MAME *device* ROM, resolved
  from a shared zip at the rompath root, not from each game's own romset zip).
  Mapped at CPU addresses `0x0000-0x1fff`.
- **Per-game external program**, e.g. `mustang.zip` → `90058-7` (65536 bytes) — only
  bytes `0x2000-0xefff` of this file are actually mapped (CPU addresses
  `0x2000-0xefff`); the rest of the 64KB dump is unused padding from how the real
  ROM chip was sized/dumped.

Confirmed both resolve correctly and `mustang` boots today at 1227% realtime under
plain MAME with our `mame_roms/` tree (`mame mustang -rompath mame_roms ...`) —
this is the oracle we'll trace against.

## Memory map

MAME's `address_map` construction applies the *owner*-provided map first, then the
CPU's own *internal* map on top with priority (`emu/addrmap.cpp`: "construct the
internal device map (last so it takes priority)") — resolving what initially looked
like a contradiction (NMK004's own `mem_map` explicitly omits `0x0000-0x1fff` with a
comment noting that's the internal ROM, and yet `device_reset()` sets `PC=0x0000`).
The two maps are additive, not exclusive:

| Range | Source | Contents |
|---|---|---|
| `0x0000-0x1fff` | CPU internal map (`tmp90840_mem`) | 8KB internal boot ROM (`nmk004.bin`) |
| `0x2000-0xefff` | NMK004 device map | External per-game program ROM |
| `0xf000-0xf7ff` | NMK004 device map | 2KB external work RAM |
| `0xf800-0xf801` | NMK004 device map | YM2203 register-address / data (confirmed exercised at boot: table-driven init loop writing `$F800`=addr then `$F801`=data until a `$FF` terminator, from a table at `0x0D27`) |
| `0xf900` | NMK004 device map | OKIM6295 chip 0 |
| `0xfa00` | NMK004 device map | OKIM6295 chip 1 |
| `0xfb00` | NMK004 device map | read latch from 68000 host (`to_nmk004`, synchronized read) |
| `0xfc00` | NMK004 device map | write latch to 68000 host (`to_main`, synchronized write) |
| `0xfc01` | NMK004 device map | OKI chip 0 bankswitch (2-bit) |
| `0xfc02` | NMK004 device map | OKI chip 1 bankswitch (2-bit) |
| `0xfec0-0xffbf` | CPU internal map | 256 bytes internal RAM |
| `0xffc0-0xffef` | CPU internal map (`tmp90840_regs`) | on-chip peripheral registers — see below |

## Register model

- `A`/`F` (8-bit accumulator/flags, packed as 16-bit `AF`), `BC`/`DE`/`HL` (each a
  16-bit pair independently addressable as two 8-bit halves), `IX`/`IY`/`SP`/`PC`
  (16-bit only, no 8-bit halves).
- Full shadow set `AF'`/`BC'`/`DE'`/`HL'`. `EXX` swaps `BC/DE/HL` only (not AF, not
  IX/IY). `EX AF,AF'` swaps AF only, **with one real quirk**: reading the shadow
  bank's `IF` (interrupt-enable) bit always returns the *live* `F`'s `IF`, never the
  banked value — MAME's own comment: `"one interrupt flip-flop? Needed by e.g.
  mjifb"`. Writing the shadow bank is verbatim (no masking); only the *read* path
  substitutes live `IF`. Must replicate exactly — this is a real, load-bearing quirk
  of the oracle we're diffing against, not an incidental implementation detail.
- **Flag bit layout is NOT Z80-standard** despite family resemblance:
  ```
  CF=0x01 Carry   NF=0x02 Subtract   PF/VF=0x04 Parity/Overflow
  XCF=0x08 "extra carry" (2nd carry-style flag, also gates INCX/DECX)
  HF=0x10 Half-carry   IF=0x20 Interrupt-enable (repurposes Z80's Y-flag bit position)
  ZF=0x40 Zero   SF=0x80 Sign
  ```
  TLCS-90 bakes a real interrupt-enable flag directly into F (bit 0x20, Z80's
  otherwise-undocumented Y position) and a genuine second carry flag XCF (Z80's X
  position) — both load-bearing, not undocumented/copy bits.
- IX/IY memory addressing (only when used as a *memory address*, i.e. `MR16`/
  `MR16D8` — not when loaded as a plain 16-bit *value*) is bank-extended via
  `BX`/`BY` registers (`0xffec`/`0xffed`, bits 3-0 → address bits 19-16, OR'd not
  added) into the CPU's real 20-bit address space. Deferred — see "Known gaps."

## Addressing modes

14 distinct modes (`e_mode` in the reference), each an operand slot resolved during
instruction decode before execute:

| Mode | Meaning |
|---|---|
| `I8`/`I16` | immediate byte/word |
| `D8`/`D16` | signed displacement byte / 16-bit relative constant (`D16` reads as `raw-1`, an intentional off-by-one used by `CALLR`) |
| `R8`/`R16` | register (register-select code in the opcode's low bits, contiguous `B,C,D,E,H,L,A`=0-6 for R8; `BC,DE,HL,(3=unused),IX,IY,SP,AF,AF2`=0,1,2,4-8 for R16 — code 3 always absent, confirmed reserved) |
| `MI16` | memory, direct 16-bit address (short-form `$FF00+n` zero-page style is common) |
| `MR16` | memory indirect via a register pair, `(rr)` — IX/IY-banked when the register is IX/IY |
| `MR16D8` | memory indirect, `(rr+d)`, same IX/IY banking rule |
| `MR16R8` | memory indirect, `(rr+r8)` — the 8-bit index is **sign-extended** before adding, even though read as unsigned register content |
| `R16D8`/`R16R8` | *value* `rr+d` / `rr+r8` (load-effective-address form, used by `LDA`) |
| `BIT8`/`CC` | literal bit index / condition code, encoded directly in the opcode |

## Instruction set — implementation phasing

The full opcode table (~65 semantic operations, several with 8-bit/16-bit variants
via an `OP_16` flag bit rather than a true prefix byte) is large. Phased by what the
real boot trace exercises first (captured via MAME's own debugger `trace` command
against `:nmk004:mcu` — see "Verification" below) vs. deferred:

**Phase 1 (base table, done):** `NOP`, `LD`/`LDW` (register/immediate/direct/
indirect forms — by far the most opcode space), `EX`/`EXX`, `INC`/`DEC` (r8/r16/
`INCW`/`DECW` memory forms), `DJNZ` (both the 8-bit-B and 16-bit-BC forms — both
seen in the boot trace's RAM-clear loops), `ADD`/`SUB`/`CP`/`AND`/`OR`/`XOR`/`ADC`/
`SBC`, `JP`/`JR`/`CALL`/`CALLR`/`RET`/`RETI` (all condition-code gated forms),
`PUSH`/`POP`, `DI`/`EI` (with the delayed-EI one-instruction latency), `HALT`,
`RCF`/`SCF`/`CCF`/`CPL`/`NEG`/`DAA`, `BIT`/`SET`/`RES`, `INCX`/`DECX`.

**Phase 2 (all six "(gg)"/"(mn)"/"($FF00+n)" prefixed opcode groups, done):**
register-indirect `(gg)` and full-16-bit-direct/short-address `(mn)`/`($FF00+n)`
addressing extended to *every* register (not just the A/HL-only short forms Phase 1
covers) for `LD`/`ADD`-family/`INC`/`DEC`/`INCW`/`DECW`/rotate-shift/`BIT`/`SET`/
`RES`, plus register-indirect and direct-address `JP`/`CALL`. Implemented as a
second decode level: once the base opcode byte identifies one of
`0xe0-0xe6`/`0xe3`/`0xe7`/`0xe8-0xee`/`0xeb`/`0xef`, the FSM fetches whatever the
group needs (a register code is already embedded in the opcode byte for the `(gg)`
groups; the `(mn)`/`($FF00+n)` groups fetch an address first) then the
operation-selector byte, and a second combinational table (mirroring the first)
resolves the same op/mode/register fields the base table produces directly — the
rest of the FSM doesn't know or care which table an instruction came from.

**Phase 3 (indexed and register-to-register groups, done):** `(ix+d)`/`(iy+d)`/
`(sp+d)`/`(HL+A)` addressing (opcode groups `0xf0-0xf7`) for the same operation set
as Phase 2, plus the `0xf8-0xfe` register-to-register group — which turned out to be
where plain `ADD A,r`-style 8-bit register-register forms and 16-bit `ADD HL,gg`
actually live (nowhere in the base table has a bare register-register ALU form at
all), along with register-register `LD r,g`/`LD rr,gg` and a *second* `RET cc`
encoding (only valid when the group's own opcode byte is exactly `0xfe`). Both
extensions reuse the same two-level decode architecture Phase 2 established: the
indexed groups resolve their effective address once, up front (base register value
+ sign-extended displacement, or `HL + sign_extend(A)`), storing it exactly like the
`(mn)`/`($FF00+n)` groups already do (no new addressing-mode enum needed); the
register-to-register group needs no memory access at all, so its "external operand"
(embedded in the base opcode byte, same mechanism as `(gg)`'s register code) is
just a second register-select code, reusing the same fill logic once more. New
IX/IY registers were added to the register file for this (previously reachable
in principle via the base table's `LD rr,nn`/`PUSH`/`POP` — which never distinguished
IX/IY from any other register code — but silently a no-op, since those registers
didn't exist yet; not something the verification trace happened to exercise before
now, so not a regression, but worth naming as a latent gap this closed incidentally).
`EX (gg)/(mn)/($FF00+n)/(ix+d)/(iy+d)/(HL+A),rr` (the memory-operand forms of `EX` —
register-only `EX` is implemented) is the one op across all these groups still
deferred, alongside everything below.

**Deferred (not yet needed to make further verified progress — add once the oracle
trace shows where):** `MUL`/`DIV`, `RLD`/`RRD`, block transfer
`LDI`/`LDIR`/`LDD`/`LDDR`/`CPI`/`CPIR`/`CPD`/`CPDR`, `LDAR`, `CALLR`, `SWI`, IX/IY
bank extension via `BX`/`BY`. `LDA` and `TSET` are **dead opcode space in MAME
itself** — decode() recognizes them but the reference model's own execute-switch
has no handler (commented out, would `fatalerror` if ever actually reached),
meaning no MAME oracle trace can ever exercise or validate them. Implementing them
with the obvious/documented semantics is safe (real silicon surely supports them)
but they can never be cross-checked — flagged as a permanent verification blind
spot, not a bug to chase.

### Flag-formula highlights worth getting exactly right (see reference for full detail)

- 8-bit `ADD`/`ADC`/`SUB`/`SBC`/`CP`: standard two's-complement overflow (`VF`)
  formula, `HF` from nibble carry, `CF`+`XCF` together on carry-out.
- 16-bit register-to-register `ADD HL,rr` **only** touches C/H/N (`F &= SF|ZF|IF|VF`
  preserves S/Z/V) — every *other* 16-bit arithmetic addressing-mode combo
  recomputes S/Z/V fully. Easy to miss, a real asymmetry in the reference.
- `INC`/`DEC r8`: **preserves CF** (`F &= (IF|CF)`), only `SZHV` recomputed.
  `INC`/`DEC` on a *register-pair* (not memory): touches **only XCF**, nothing
  else. `INCW`/`DECW` (the separate memory-operand-only opcodes) compute full
  flags — three different flag behaviors for what sounds like "the same"
  operation family, all real, all must be kept distinct.
- `DAA`: computes the BCD adjustment (`diff`) and the new CF/HF conditions from
  the **pre-adjustment** `lo`/`hi`/`cf`/`hf`/`nf`, not from the post-adjustment
  accumulator — a classic DAA pitfall, documented in full in the reference.
- Rotate/shift ops have an accumulator-specific flag path (`A` as the operand:
  preserve S/Z/IF/P, recompute only C/X) distinct from every other operand
  (memory or non-A register: full S/Z/P recompute) — mirrors Z80's own
  `RLCA`-vs-`RLC r` asymmetry but with TLCS-90's own preserved-bit set.

## Interrupt model

- Reset: `PC = 0x0000`. No indirect vector table — every interrupt jumps **directly**
  to inline code at `0x10 + irq_index*8` (`INTSWI`=0 through `INTTX`=13, so vectors
  span `0x10-0x78`, all inside the internal boot ROM).
- `take_interrupt`: push `PC` then `AF` (so `RETI` pops `AF` then `PC` — correct
  LIFO), clear `IF`, jump. A fixed 20-cycle latency is charged once per
  `execute_run()` call (not per-instruction), applied outside normal per-opcode
  cycle bookkeeping.
- Priority is scan order (`INTSWI` highest, `INTTX` lowest), gated by `F&IF` for
  everything **except SWI**, which is a synchronous opcode that calls
  `take_interrupt` directly, bypassing the IF gate entirely (genuinely
  non-maskable). **NMI is *not* truly non-maskable in this model** despite the
  reference's own doc-comment priority table calling it that — it's routed through
  the same `m_irq_state`-polling mechanism as maskable IRQs and IS gated by `F&IF`
  (only its *mask-bit* check is skipped, not the top-level IF gate). Replicating
  MAME's actual behavior here (not the datasheet-implied "true NMI") matters since
  MAME's own model is the oracle.
- Delayed `EI`: sets an internal "armed" flag rather than `IF` directly; `IF`
  becomes set one full instruction *after* the `EI` opcode (classic Z80/8080-style
  one-instruction interrupt-disable window following `EI`).

## Peripheral registers (`0xffc0-0xffef`)

Real datasheet-quality detail exists in the reference source, but critically:
`tmp90840_regs` maps `0xffc0-0xffef` to a catch-all `reserved_r`/`reserved_w` stub
**first**, with named handlers for only a subset of addresses layered on top —
several registers the boot ROM writes (`TFFCR`, `WDMOD`, `WDCR`, `ADMOD`, `DMAEH`,
per the captured boot trace's own disassembly) have **no real handler in MAME at
all** and silently no-op. This directly narrows what RTL needs to implement for
oracle-parity: registers MAME itself stubs can be stubbed in RTL too (same
"accept the write, do nothing" pattern already established for bjtwin's OKI ports).

Confirmed exercised by the captured boot trace: `BX`/`BY` (index bank, write $00 —
i.e. banking disabled at boot), `P01CR`/`P2CR`/`P3CR`/`P4CR`/`P67CR`/`P8CR`
(port direction/function config), `TRUN`/`TMOD`/`TCLK`/`TREG0-3`/`T4MOD`/
`TREG4L/H`/`TREG5L/H` (timer configuration — MAME *does* implement real countdown
+ IRQ generation for these, unlike the reserved group above), `INTEH`/`INTEL`
(interrupt enable masks), `SMMOD`/`ADMOD`/`WDMOD`/`WDCR`/`DMAEH` (all in the
reserved/no-op group per above).

`P4` bit 0 is the one peripheral behavior already known from the NMK004 wrapper
itself (not the CPU core): it drives the 68000 host's reset line
(`nmk004_device::port4_w`). Everything else port/pin-related (P1/P2 as an
address/data bus for the external ROM, P3 as RD/WR strobes) doesn't need literal
GPIO-pin modeling in our RTL — a synthesizable core can implement the external bus
directly as dedicated address/data/strobe signals, making the corresponding
`P01CR`/`P2CR`/`P3CR`/`P4CR` writes accept-and-ignore in RTL (the configuration
they'd perform in real silicon is implicit in our design already).

## Known gaps / deferred work (documented, not hidden)

1. **Timers are not yet implemented as real counters.** The boot ROM configures
   and starts them (`TRUN=$23` at the end of the init sequence, `INTEH=$01`
   enabling one high-byte interrupt source) — real countdown+IRQ behavior is
   almost certainly needed once we get past boot into the main firmware loop
   (sound-driving MCU firmware is fundamentally timer/interrupt-paced). Phase 1
   targets boot-sequence execution only; timers are stubbed (configuration
   accepted, no counting/IRQ yet) until oracle-trace comparison shows where real
   timer behavior is actually needed.
2. **IX/IY bank extension (`BX`/`BY`) not yet implemented** — boot trace writes
   both to 0 (banking disabled), so not yet exercised; needed before trusting any
   firmware that uses >64KB addressing via IX/IY.
3. **Serial (UART) and ADC peripherals not implemented** — `tmp90840_regs` doesn't
   even map serial registers for this specific device variant (commented out in
   the reference), and P5 (ADC-capable pins) has no plausible use for a sound MCU.

## Verification plan

Mirrors the project's established methodology (Tier 0/1: verify CPU execution
against a real MAME oracle trace before trusting anything downstream):

1. Capture a real disassembled execution trace directly from MAME's own debugger
   (`trace <file>,:nmk004:mcu` + `go`/`exit`, run against `mustang` — proven
   working this session, 212K-line trace captured covering the full boot sequence
   through YM2203 register table initialization). This is a *stronger* oracle
   than the nmktrace bus-tap approach used for the 68000 — it's MAME's own
   disassembler output, PC + mnemonic + operands per instruction, no bus-tap
   blind-spot risk (per Tier 1's hard-won lesson about the Lua tap's real,
   reproducible coverage gaps).
2. Build the RTL core's own equivalent PC/instruction trace (via debug ports on
   the CPU module, same `dbg_*` pattern established in `bjtwin_core.sv`) and diff
   directly against the MAME disassembly trace — a straightforward text diff on
   PC sequence is a strong first-pass correctness signal even before full
   cycle-accurate timing is trusted.
3. Extend the nmktrace bus-tap/state-comparison tooling to the external RAM/YM/OKI
   register writes once instruction-level correctness is established, following
   exactly the state-comparison methodology from Tier 1's palette/VRAM work.

## What's built so far

- `rtl/tlcs90/tlcs90.sv` — a real, working CPU core covering the base opcode
  table plus all six prefixed opcode groups (see "Instruction set" above):
  register file (BC/DE/HL/AF + full shadow set with the AF2-shared-IF
  quirk), flags with the correct non-Z80 bit layout, condition codes, and a
  two-level FETCH→DECODE→(operand/prefix bytes)→READ→EXECUTE→WRITE state
  machine. See the module's own header for the authoritative scope/deferred
  list, mirrored in this doc's "Instruction set" section above.
- `sim/rtl/tlcs90/tb_tlcs90.cpp` + `Makefile` — Verilator testbench. Loads
  the real `nmk004.bin` (internal boot ROM, from the shared `nmk004.zip`
  device ROM) and `mustang`'s real external program (`90058-7`), runs the
  core, and logs every instruction boundary's PC to `tlcs90_rtl.trace` for
  direct comparison against a MAME oracle trace.

### First verification result (base table only)

Captured a real oracle trace via MAME's own debugger (`trace file,:nmk004:mcu`
+ `go` + `exit`, run against `mustang` with `mame_roms/` — see "Verification
plan" above) and diffed the RTL's PC sequence against it directly:

```
matched 16 of 6982 compared instructions before first mismatch
  rtl:    0000 0001 0003 0006 00DF 00E2 00E5 00E8 00EB 00EE
          00F1 00F4 00F7 00FA 00FD 0100 0103 0104 ...
  oracle: ....(same through 0103).......................... 0107 010A ...
```

**17 real instructions match MAME's own CPU core exactly, PC-for-PC** — the
full base-table boot sequence: `NOP`, `LD D,n`, `LD SP,nn`, an unconditional
`JP`, and 13 consecutive `LD ($FF00+n),n` short-address writes. The
divergence at instruction 17 was exactly the predicted one: PC=0x103 is
`LD HL,($EFFE)`, a full 16-bit-direct-address form from a not-yet-implemented
prefixed opcode group.

### Second verification result (prefixed groups added)

After implementing all six prefixed opcode groups, re-diffed against a fresh,
longer oracle capture. MAME's `trace` command **collapses repeated loop
bodies** in its output (`(loops for N instructions)` summary lines instead of
literally repeating them) — a straight positional diff produces false
mismatches right at every loop boundary, so the comparison instead checks
that the (collapsed) oracle PC sequence appears as an **exact ordered
subsequence** of the RTL's fully-unrolled trace, which correctly tolerates
the collapsed regions while still catching any real divergence:

```
matched 86 oracle checkpoints as an exact ordered subsequence
stopped at oracle checkpoint 87 (PC=0x017D), not found in the remaining trace
last matched checkpoint: PC=0x017B
```

**86 real instructions match MAME's own CPU core exactly** — both the 2048-
and 256-byte RAM-clear loops (each confirmed to run the exact expected
iteration count) and the complete YM2203 register-table init loop (420
collapsed iterations in the oracle, all correctly traversed), using `LD A,
(HL)`, `LD ($F800/$F801),A` (16-bit direct address), and `CP (HL),n`
(register-indirect) — real exercise of every one of the six new prefix
groups' addressing paths, not just the ones the divergence point happened to
land on. The divergence at PC=0x17B was initially (and, per the next section,
**incorrectly**) attributed to `XOR A,(HL+A)`; tracing the actual opcode
bytes (`0xFE 0x65`) against the reference source during the next milestone
revealed it's really `XOR A,A` via an entirely different, previously
unidentified opcode group — see "Third verification result" below for the
correction and what that group turned out to be.

**A real, reproducible Verilator bug was found and fixed along the way,
not just a project bug**: a `resolve_direct(mode, rsel)` helper function —
wrapping a `case` that dispatches to `r8_read()`/`r16_read()` — silently
returned `0x0000` instead of the correct register value specifically when
called from inside a ternary on the right-hand side of a non-blocking
assignment (`val1 <= cond ? resolve_direct(...) : r1;`). Caught by directly
comparing a separately-exposed live `r16_read()` debug signal (correct)
against `val1` moments after the same non-blocking assignment fired
(wrong) — same inputs, same cycle, two different answers depending only on
which call path computed them. Root cause not pinned down further (Verilator
composing one `function automatic`'s case-dispatch return value through
another in that specific expression position, as best as could be
determined — not anything wrong with `r8_read()`/`r16_read()` themselves,
confirmed independently correct). Fixed by inlining the same three-way
mode selection directly at both call sites instead of routing through the
wrapper function — measurably fixes it, so kept, rather than chasing the
simulator bug further. This is exactly the class of bug the "verify against
a real MAME oracle, not just clean compilation" methodology exists to catch
— a register that silently reads back the wrong value has no reason to show
up as a lint warning or a compile error.

### Third verification result (indexed and register-to-register groups added)

Implemented `MR16D8`/`MR16R8` addressing (`0xf0-0xf7`) to get past the PC=0x17B
divergence — but the actual opcode bytes there (`0xFE 0x65`) turned out **not**
to belong to that group at all. Tracing them against the reference source
directly: `0xf0-0xf7`'s own case list is `case 0xf0: case 0xf1: case 0xf2:` /
`0xf3` / `0xf4-0xf6` / `0xf7` — `0xFE` isn't in it. `0xFE` is the **register-
to-register** group (`0xf8-0xfe`, previously unidentified and unimplemented,
not mentioned anywhere in the original addressing-mode inventory), which
interprets `b0-0xf8` as an *8-bit or 16-bit register code* (not a memory
base) — so `0xFE 0x65` is `XOR A,g` with `g = 0xFE-0xF8 = 6 = A`, i.e.
`XOR A,A`, matching the oracle's own disassembly exactly (it really does say
"xor a,a", not an abbreviated "(HL+A)" as first assumed). This is also where
plain `ADD A,r`-style 8-bit and `ADD HL,rr`-style 16-bit **register-to-
register** ALU forms live — nowhere in the base table or any of the other
prefix groups has a bare register-register ALU operand, which had gone
unnoticed until this specific divergence forced tracing the real opcode bytes
instead of assuming which documented-but-unverified group they'd fall into.
Implemented both this group and the real `(ix+d)`/`(iy+d)`/`(HL+A)` indexed
groups together (see "Instruction set" above), plus the `ADD HL,rr`
register-to-register flag special-case this group's `ADD HL,gg` form finally
made reachable (previously implemented as inapplicable dead code, since
nothing before this could reach it — now real and covered).

Re-diffed against the same oracle capture used for the second result:

```
matched 175 oracle checkpoints as an exact ordered subsequence
stopped at oracle checkpoint 176 (PC=0x0EB3), not found in the remaining trace
last matched checkpoint: PC=0x0EB1
```

**175 real instructions match MAME's own CPU core exactly** — up from 86,
covering everything through `mustang`'s OKI/port initialization and into a
host-handshake wait loop (`LD D,($FB00)` / `CP A,D` / `JR NZ,$0EAB`, polling
the read latch from the 68000 host for a value only the real host would ever
write). Checked directly that this is a real, expected boundary and not a
bug: the RTL's own trace shows the *identical* three-instruction loop
content at the *identical* addresses, looping indefinitely for the same
reason MAME's own oracle capture does (the trace tool's loop-collapse count
even matches structurally) — a standalone CPU-only testbench has no 68000
counterpart to satisfy this handshake, so this is the natural verification
boundary for "TLCS-90 core validated first in isolation" per the project's
own stated methodology, not a CPU defect. Going further needs either a
fuller system simulation (68000 + shared RAM + real cross-CPU
synchronization) or a testbench that deliberately fakes the handshake
response — both are system-integration-level work, not CPU-core work.

Next step: a real peripheral/timer/interrupt module (ports, INTEL/INTEH,
timers) is the natural next slice of CPU-adjacent work remaining; getting
NMK004 actually driving YM2203/OKI hardware needs that plus the
system-level integration described above.
