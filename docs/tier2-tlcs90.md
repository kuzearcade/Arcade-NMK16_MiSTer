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

The CPU core now also has **real interrupt dispatch** (priority-scanned maskable
IRQs + NMI, PUSH PC/AF, vector jump, RETI return) and a **real peripheral/timer
module** (`nmk004_periph.sv`: ports, timers 0-5 with true compare-match/prescale/
chaining behavior, INTEL/INTEH) wired into a full board wrapper (`nmk004_core.sv`).
Since the real boot ROM never reaches its own `EI` instruction in a CPU-only
testbench (see "Fourth verification result" below), the interrupt/timer mechanism
was verified with a small synthetic self-test program instead — confirmed working
end-to-end (211 correctly-vectored, correctly-returned-from interrupts over a
100000-cycle run). See "Fourth verification result" below.

**IX/IY bank extension via BX/BY is now implemented** too (`ix_bank`/`iy_bank`
CPU inputs, `bank1`/`bank2` address computation, matching the reference's
bitwise-OR-not-add semantics exactly). Since no currently-known NMK004 game
ever sets a nonzero bank, this was verified with a dedicated standalone
synthetic test (`tb_banktest.cpp`) exercising a real 16-bank memory model
directly against the CPU core — found and fixed one real bug along the way
(a "sticky" internal register that let a direct-address write spuriously
inherit a *previous* instruction's bank). See "Fifth verification result"
below.

**The block-transfer/compare family (`LDI`/`LDIR`/`LDD`/`LDDR`/`CPI`/`CPIR`/
`CPD`/`CPDR`) is now implemented** too, reusing the existing `M_MR16`/`r1=HL`
read pipeline to fetch `RM8(HL)` and a literal `pc -= 2` re-fetch for the
`*IR`/`*DR` repeat forms, mirroring the reference exactly. Since no
currently-known game's boot trace reaches these opcodes either, verified
with a second dedicated standalone test (`tb_blocktest.cpp`) — a 5-part
synthetic program covering ascending and descending block copy, a
found-early and an exhausted-search compare, and confirming the non-`R`
single-step forms genuinely don't repeat. All checks passed on the first
run. See "Sixth verification result" below.

**RLD/RRD are now implemented** too — reachable via every SRC prefix group's
own selector byte `0x10`/`0x11` (never the base table), rotating the 12-bit
`{A_lo,M_hi,M_lo}` unit one nibble left or right. Verified with a third
dedicated standalone test (`tb_rldtest.cpp`) exercising both opcodes through
two *different* addressing forms — `(HL)` and a direct 16-bit address — to
prove the shared `mem_mode` decode wiring genuinely generalizes rather than
happening to work for whichever form was implemented first. All checks
passed on the first run. See "Seventh verification result" below.

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
  added) into the CPU's real 20-bit address space. Implemented — see "Fifth
  verification result" below.

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

**Phase 4 (block transfer/compare, done):** `LDI`/`LDIR`/`LDD`/`LDDR`/`CPI`/`CPIR`/
`CPD`/`CPDR` — same `0xf8-0xfe` group as Phase 3's register-to-register forms,
selector byte `0x58-0x5f`, only valid when the group's own opcode byte is exactly
`0xfe` (same `gg==R16_SP` gate Phase 3's second `RET cc` encoding already uses).
Reuses the existing `M_MR16`/`r1=R16_HL` read pipeline to fetch `RM8(HL)` for
free (mode2 stays `M_NONE` — `DE` is a destination `EXECUTE` writes to directly,
not a decoded operand slot, since this is a two-different-addresses operation
the existing single-address-pair architecture doesn't otherwise support); the
`*IR`/`*DR` repeat forms are a literal `pc -= 2` re-fetch of the same 2-byte
instruction when their loop condition holds, mirroring the reference's own
`m_pc.w.l -= 2` exactly rather than looping internally. See "Sixth verification
result" below.

**Phase 5 (RLD/RRD, done):** reachable via every SRC prefix group's own
selector byte `0x10`/`0x11` — `(gg)`, `(mn)`, `($FF00+n)`, `(ix+d)`/`(iy+d)`,
`(HL+A)` — never the base table, resolved through the same `pfx_is_src`
level-2 decode branch every other SRC-side op (`INC`/`DEC`/rotate-shift/etc.)
already shares. `A` isn't a decoded operand in this group's own encoding
(there's no room for a second operand slot alongside the memory one), so
`EXECUTE` reads/writes it directly — the same reasoning Phase 4's `LDI*`/
`CPI*` already established for `DE`. Rotates the 12-bit `{A_lo,M_hi,M_lo}`
unit one nibble left (`RLD`) or right (`RRD`), reusing the existing `szp8()`
helper for the flag formula (`F = (F&(IF|CF)) | SZP[new A]`, exactly
mirroring the reference). See "Seventh verification result" below.

**Deferred (not yet needed to make further verified progress — add once the oracle
trace shows where):** `MUL`/`DIV`, `LDAR`, `CALLR`, `SWI`. `LDA` and
`TSET` are **dead opcode space in MAME
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

1. **IX/IY bank extension (`BX`/`BY`) is implemented in the CPU core** (see
   "Fifth verification result" below) but not backed by real >64KB storage at
   the system level: `nmk004_core.sv`'s memory map gates every currently-mapped
   region on `cpu_addr_bank==0` (matching every currently-known game, whose
   boot trace always leaves BX/BY at 0 and whose external programs top out
   around 56KB) and leaves a nonzero-bank access genuinely unmapped (reads 0,
   writes dropped) rather than aliasing it onto bank 0. If a game is ever
   identified that legitimately needs >64KB via IX/IY banking, that's where a
   real backing region would be added.
2. **Serial (UART) and ADC peripherals not implemented** — `tmp90840_regs` doesn't
   even map serial registers for this specific device variant (commented out in
   the reference), and P5 (ADC-capable pins) has no plausible use for a sound MCU.
   Watchdog (WDMOD/WDCR) and DMA (DMAEH) are likewise unimplemented, matching
   MAME's own `reserved_r`/`reserved_w` stub for these exact registers.
3. **IRF-clear (`0xffc3`) is accepted but a no-op** — the only real IRQ sources
   modeled so far (the timers) already auto-clear on take via the CPU's own
   dispatch logic, matching `clear_irq()` being called from `take_interrupt()`
   for every source except INT0 in level mode. Manual IRF clearing only matters
   for sources not modeled yet (INT0/INT1/INT2/serial) — a real, narrow gap, not
   a blanket stub.
4. **YM2203/OKI/host-handshake are external ports, not internally modeled** —
   `nmk004_core.sv` exposes real bus ports for these (`ym_cs`/`ym_we`/...,
   `oki0_*`/`oki1_*`, `host_to_mcu`/`mcu_to_host`) rather than stubbing them,
   since they aren't this module's own state; connecting real `jt12`/`jt6295`
   cores and a real 68000 is system-level integration work, not CPU/peripheral
   work.

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
- `sim/rtl/tlcs90/tb_tlcs90.cpp` + `Makefile` (`make run`) — Verilator
  testbench. Loads the real `nmk004.bin` (internal boot ROM, from the shared
  `nmk004.zip` device ROM) and `mustang`'s real external program (`90058-7`),
  runs the core, and logs every instruction boundary's PC to
  `tlcs90_rtl.trace` for direct comparison against a MAME oracle trace.
- `rtl/tlcs90/nmk004_periph.sv` — on-chip peripheral registers
  (`0xffc0-0xffef`): ports (plain latches, see module header for why real
  GPIO-pin modeling isn't needed), timers 0-3 (8-bit or 16-bit-paired per
  TMOD, real compare-match/prescale/chaining counters matching
  `t90_timer_callback` structurally), timer 4/5 (16-bit free-running with
  independent TREG4/TREG5 compare points, matching `t90_timer4_callback`),
  INTEL/INTEH decode into an 11-bit `irq_mask`, and BX/BY (stored/read back,
  wired via `bx`/`by` outputs into the CPU core's `ix_bank`/`iy_bank` inputs).
- `rtl/tlcs90/nmk004_core.sv` — the full board wrapper: CPU + peripherals +
  memory map (boot ROM/external ROM/work RAM/internal RAM/peripherals),
  with YM2203/OKI×2/host-handshake exposed as real external ports for a
  future system-level wrapper rather than stubbed internally.
- `sim/rtl/tlcs90/tb_nmk004.cpp` + `Makefile` (`make run-nmk004`,
  `make run-irqtest`) — Verilator testbench for the full board wrapper, in
  two modes selected by which boot ROM is linked in: the real ROM (regression
  vs. the same oracle trace, since real peripherals shouldn't change anything
  already-verified) and a synthetic self-test ROM (`sim/rtl/tlcs90/roms/
  irqtest_boot.hex`) that proves the interrupt/timer mechanism end-to-end —
  see "Fourth verification result" below.
- `sim/rtl/tlcs90/tb_banktest.cpp` + `Makefile` (`make run-banktest`) —
  standalone CPU-core-only Verilator testbench with a synthetic 16-bank x
  64KB memory model (independent of nmk004_core.sv, which doesn't back a
  nonzero bank with real memory yet) that proves IX/IY bank extension
  end-to-end — see "Fifth verification result" below.
- `sim/rtl/tlcs90/tb_blocktest.cpp` + `gen_blocktest_rom.py` + `Makefile`
  (`make run-blocktest`) — standalone CPU-core-only Verilator testbench
  with a synthetic 5-part program (assembled by the sibling `.py` script,
  which also documents each byte's derivation) proving
  `LDI`/`LDIR`/`LDD`/`LDDR`/`CPI`/`CPIR`/`CPD`/`CPDR` end-to-end — see
  "Sixth verification result" below.
- `sim/rtl/tlcs90/tb_rldtest.cpp` + `gen_rldtest_rom.py` + `Makefile`
  (`make run-rldtest`) — standalone CPU-core-only Verilator testbench with
  a synthetic 2-part program proving `RLD`/`RRD` end-to-end through two
  different addressing forms — see "Seventh verification result" below.

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

### Fourth verification result (peripheral/timer/interrupt module + synthetic interrupt self-test)

Built the peripheral register module (`nmk004_periph.sv`) and the full board
wrapper (`nmk004_core.sv`), and added real interrupt dispatch to the CPU core
itself (`irq_req`/`irq_mask` inputs, priority-scanned lowest-set-bit encoding,
push PC then AF with the correct pre-`IF`-clear AF value, jump to
`0x10+(idx+3)*8`, chained through two new FSM states `S_IRQ_PUSH2_LO`/
`S_IRQ_PUSH2_HI`). Regression-verified this didn't disturb the existing
175-checkpoint CPU match (unchanged — `make run` still matches 175 of the same
oracle checkpoints).

Bringing up the new peripheral module found **three real, independent RTL
bugs**, none caught by lint or the PC-trace regression (none affected PC
sequence, only peripheral-internal state), all found by adding temporary
debug ports and comparing traced values against hand-derived expected
behavior (since removed once bring-up was complete — see below):

1. **Same Verilator function-composition bug as the CPU core's earlier
   `resolve_direct()` bug, a second independent instance**: a
   `prescale_of()` helper function called from inside continuous `wire`
   assignments silently never evaluated correctly. Fixed the same way —
   replaced with combinational `always @(*)` blocks computing named regs
   directly, no function call composed into another expression.
2. **Prescaler free-running regardless of timer enable** — the real bug
   behind "timer never fires": `presc0` (and siblings) incremented every
   `base_tick` unconditionally from power-on, only resetting via its own
   match. By the time firmware enabled the timer via `TRUN`, the prescaler
   had already drifted arbitrarily far from the match point and could take
   up to 65536 base-ticks to return to it. Fixed by gating the prescaler on
   the enable signal (`if (!en0) presc0<=0; else if(base_tick) ...`),
   matching the reference's `t90_start_timer()` resetting the timer's phase
   on every (re-)start.
3. **`irq_req` bit-position off-by-one** — a hand-written concatenation
   assigning `fired0..fired5` into the 11-bit `irq_req` bus was off by one
   position against the documented bit order, confirmed by hand-counting.
   Happened to produce a plausible-looking result for the one config tested
   purely by coincidence. Fixed with an explicit indexed `always @(*)`
   assignment (`irq_req_r[1]=fired0; ...`) instead of positional
   concatenation.

**Verifying interrupt dispatch itself needed a synthetic test program**,
since the real boot ROM's `EI` instruction only executes at PC=0x1DA — past
the host-handshake wait loop this session's CPU-only testbench can never
satisfy (no real 68000 exists to write `$FB00`). Built a tiny synthetic
TLCS-90 program (`sim/rtl/tlcs90/roms/irqtest_boot.hex`, generated by a small
Python script, not hand-assembled bytes-in-a-vacuum) that initializes `SP`
(the real boot ROM's `EI` path relies on `SP` already being set — the
synthetic program must do this explicitly, an early iteration that omitted it
found `SP=0` at reset pushes into unmapped `0xfff0-0xffff` address space,
silently discarding the return address and corrupting `RETI`), configures
timer 0 for a fast compare match (`TREG0=0x3B`, `TCLK`=divide-by-1
prescale), enables it (`TRUN=0x21`) and its interrupt (`INTEH=0x02`), then
`EI` + self-loops. A `RETI` is planted at the computed INTT0 vector
(`0x10+(1+3)*8=0x30`). Linked via a dedicated Makefile target
(`make run-irqtest`) that builds `nmk004_core` against this synthetic ROM
instead of the real one:

```
tb_nmk004: ran 100000 clk cycles, 16421 instructions, wrote irqtest.trace
tb_nmk004: PC visited $0030 (irqtest INTT0 vector) 211 times
```

Confirmed via the full PC trace, not just the vector-hit count: every
setup instruction (`0x0000`-`0x0013`) executes **exactly once**, the
self-loop (`0x0014`) accounts for the overwhelming majority of PC visits,
and `0x0030` (the RETI) is visited 211 times — consistent with the
configured ~472-clk-cycle timer period over a 100000-cycle run, and, crucially,
proof that `RETI` correctly returns control to the interrupted point (the
self-loop) rather than resetting to `PC=0` or corrupting execution, and that
the CPU correctly re-arms and re-fires on every subsequent match rather than
firing once and going silent. This positively verifies vector computation,
`PUSH PC`/`PUSH AF` ordering, `IF` clear-on-entry, and `IF` restore-on-`RETI`,
all end-to-end — the one part of "175 instructions match the oracle" could
never exercise on its own.

Temporary debug ports added to `nmk004_periph.sv`/`nmk004_core.sv` during
this bring-up have been removed now that verification is complete (per this
project's established convention of not leaving unexplained debug scaffolding
in committed RTL); `tb_nmk004.cpp` now does its own PC-based interrupt-vector
counting instead, so `make run-irqtest`'s pass/fail signal doesn't depend on
any peripheral-internal debug port.

### Fifth verification result (IX/IY bank extension)

Implemented BX/BY-driven IX/IY bank extension in the CPU core: two new
inputs (`ix_bank`/`iy_bank`, sourced from `nmk004_periph.sv`'s existing
`bx`/`by` outputs) and a widened bus interface (`addr_bank`, a 4-bit output
alongside the existing 16-bit `addr`) that the CPU sets to the correct bank
nibble — and only the correct bank nibble — for the two addressing forms the
reference actually banks: register-indirect through IX/IY with no
displacement (`MR16`, the "(gg)" prefix groups) and IX/IY-plus-displacement
(`MR16D8`, the `(ix+d)`/`(iy+d)` indexed groups). Every other addressing
form (SP-relative, `(HL+A)`, direct/short-address, PC fetches, SP-relative
push/pop) stays bank 0, matching the reference's own per-addressing-mode
dispatch (`Read/WriteN_8/16`'s `case e_mode::MR16`/`MR16D8` switching on the
base register) exactly — including the bitwise-OR-not-add composition (a
16-bit offset wraparound within one access never carries into the bank) and
the fact that `MR16R8` (`(HL+A)`) is never banked even though it superficially
resembles the other two forms.

Verifying this needed a **dedicated standalone test**, since no currently-known
NMK004 game ever sets BX/BY to anything but 0 (confirmed by the existing
175-checkpoint oracle trace) — there's no real firmware to diff against for
this specific behavior. `tb_banktest.cpp` drives the CPU core directly
(`ix_bank` fixed at a non-zero test value; no peripheral needed, since BX/BY's
*storage* lives in `nmk004_periph.sv`, not the CPU) against a synthetic
16-bank x 64KB memory model in C++ — something a single flat address space
can't distinguish — and runs a small hand-assembled program exercising all
four combinations (`MR16` read/write, `MR16D8` read/write) plus two plain
direct-address writes that must **not** pick up a bank:

```
OK:   bank0[$FFE0] (LD A,(IX) then LD ($FFE0),A) = 0x55
OK:   bank5[0x1000] (LD (IX),A) = 0x77
OK:   bank0[0x1000] (must be untouched) = 0xAA
OK:   bank0[$FFE1] (LD A,(IX+0x10) then LD ($FFE1),A) = 0x66
OK:   bank5[0x1010] (LD (IX+0x10),A) = 0x88
OK:   bank0[0x1010] (must be untouched) = 0xBB
tb_banktest: PASS (all 6 checks)
```

Each check reads back a bank-specific sentinel byte pre-seeded at the same
offset in both bank 0 and the test bank, so a read or write that landed in
the wrong bank is immediately visible, and the "must be untouched" checks
positively confirm no bleed-through into bank 0 (ruling out an
add-instead-of-OR bug).

**A real bug was found and fixed on the first run**: a direct-address write
(`LD ($FFE1),A`, opcode `0x2F` — never banked, per the reference) executed
immediately after an IX-relative read spuriously inherited that read's bank.
Root cause: `pfx`/`gg` (registers that record which prefix group, if any,
produced the current instruction's resolved address — read by the new
`bank1`/`bank2` logic to tell a genuine direct `M_MI16` address apart from
an IX/IY-relative one resolved *into* the same `M_MI16` tag) are only ever
written on the *prefixed* decode path; a following base-table instruction
never resets them, so they're "sticky" — silently correct for every use
that existed before this change (nothing else read them outside their own
prefix's decode sequence), but wrong the instant something started reading
them for every instruction. Fixed by explicitly resetting `pfx <= PFX_NONE`
on the base-table decode path (`S_DECODE`'s `d_pfx == PFX_NONE` branch, see
tlcs90.sv) — re-ran `tb_banktest` clean afterward, and re-confirmed the
existing 175-checkpoint oracle match and the 211-fire `run-irqtest` result
are both unchanged.

At the system level, `nmk004_core.sv`'s memory map still gates every
currently-mapped region on `cpu_addr_bank==0` and leaves a nonzero-bank
access genuinely unmapped rather than backing it with real >64KB storage —
see "Known gaps" above for why, and what would change if a game is ever
identified that needs it.

### Sixth verification result (block transfer/compare family)

Implemented `LDI`/`LDIR`/`LDD`/`LDDR`/`CPI`/`CPIR`/`CPD`/`CPDR` (see "Phase 4"
above for the exact decode/execute mechanism). Like the block-transfer
family's decode-only relatives (RET cc's second encoding, IX/IY bank
extension), no currently-known game's boot trace reaches these opcodes —
they weren't exercised before the host-handshake boundary the 175-checkpoint
oracle trace stops at — so this needed a third dedicated standalone test,
`tb_blocktest.cpp`, generated from `gen_blocktest_rom.py` (a small Python
"assembler" the same way `gen_irqtest_rom.py` and (informally) `tb_banktest.cpp`
derived their own synthetic programs, kept here as a real regeneratable
source rather than a comment describing hand-counted bytes).

Five sub-tests, run against a flat 64KB memory model (no banking needed —
these ops always address through HL/DE, never IX/IY):

```
OK:   LDIR final BC = 0x0000
OK:   LDIR final HL = 0x2005
OK:   LDIR final DE = 0x3005
OK:   LDIR copied bytes match source exactly
OK:   LDIR byte past destination end (must be untouched) = 0x00
OK:   LDDR final BC = 0x0000
OK:   LDDR final HL = 0x20FF
OK:   LDDR final DE = 0x30FF
OK:   LDDR copied bytes match source exactly
OK:   LDDR byte before destination start (must be untouched) = 0x00
OK:   CPIR final BC (found, stops early) = 0x0002
OK:   CPIR final HL (one past the match) = 0x2203
OK:   CPIR final F (Z=1,N=1,PF=1,CF preserved=1) = 0x47
OK:   CPDR final BC (not found, exhausted) = 0x0000
OK:   CPDR final F (Z=0,N=1,PF=0,SF=1,CF preserved=1) = 0x83
OK:   LDI final BC (decremented once, not driven to 0) = 0x0001
OK:   LDI copied first byte = 0x77
OK:   LDI did not touch second byte (no repeat) = 0x00
tb_blocktest: PASS (all checks)
```

`LDIR`/`LDDR` prove ascending and descending block copy (byte-exact, with an
explicit "one byte past/before the block must stay untouched" check ruling
out an off-by-one), and that `BC`/`HL`/`DE` land exactly where the
reference's algorithm says they should once the loop naturally exhausts
`BC` to 0. `CPIR` (found at index 2 of 5, stops early) and `CPDR` (not
present, exhausts the whole block) prove both loop-exit conditions
independently, plus the exact flag formula for each outcome (F values
hand-derived from the reference's `F = (F&(IF|CF)) | SZ[b8] |
((A^a8^b8)&HF) | NF`, checked via the same PUSH AF/POP HL/`LD (nn),HL`
register-observation trick `tb_banktest.cpp` didn't need but this test
does, since F has no other path to memory). `LDI` (the non-repeating
single-step form) proves the *IR*/*DR* gate is real — that a bare `LDI`
transfers exactly one byte and decrements `BC` exactly once, rather than
silently behaving like `LDIR`.

All checks passed on the first run — no bug found this time, unlike the
interrupt/timer and bank-extension milestones. Re-confirmed all four
existing regressions (175-checkpoint oracle match, 211-fire interrupt
self-test, and the bank-extension test) unchanged afterward.

### Seventh verification result (RLD/RRD)

Implemented `RLD`/`RRD` (see "Phase 5" above). Same situation as the prior
two milestones — no currently-known game's boot trace reaches these
opcodes — so a fourth dedicated standalone test, `tb_rldtest.cpp` (generated
from `gen_rldtest_rom.py`), was needed. This one deliberately exercises the
two opcodes through *different* addressing forms rather than reusing the
same one twice, since `RLD`/`RRD`'s decode entry is a single `pfx_is_src`
branch shared by all five SRC prefix groups (`(gg)`, `(mn)`, `($FF00+n)`,
`(ix+d)`/`(iy+d)`, `(HL+A)`) — a bug specific to how one particular group
resolves its address (e.g. a `pfx_addr` composition mistake in the `(mn)`
group's own decode) wouldn't necessarily show up if the test only ever
went through `(gg)`:

```
OK:   RLD (HL): M[0x2000] after = 0x5F
OK:   RLD (HL): A after (observed via $FFE0) = 0x3A
OK:   RLD (HL): F after = 0x05
OK:   RRD (0x2100): M[0x2100] after = 0xC9
OK:   RRD (0x2100): A after (observed via $FFE1) = 0x71
OK:   RRD (0x2100): F after = 0x04
tb_rldtest: PASS (all checks)
```

`RLD (HL)` (the `(gg)` register-indirect form) and `RRD (0x2100)` (the
`(mn)` direct-address form) both check the memory-side result directly
(read back from the flat memory model, no observe-write needed since the
CPU already wrote it there), the register-side result (`A`, via the same
`LD ($FF00+n),A` observe-write technique established earlier), and `F` (via
the `PUSH AF`/`POP HL`/`LD (nn),HL` trick `tb_blocktest.cpp` introduced,
since `F` has no other path to memory) — with the two tests deliberately
using a preceding `SCF`/`RCF` pair to put `CF` in a *different* known state
each time (1 then 0), proving the preserved-`CF`-bit half of the flag
formula is genuinely carried through rather than coincidentally always
landing on the same value either test would pass with by accident.

All checks passed on the first run. Re-confirmed all five existing
regressions (175-checkpoint oracle match, 211-fire interrupt self-test, the
bank-extension test, and the block-transfer test) unchanged afterward.

Next step: `MUL`/`DIV`, `LDAR`, `CALLR`, `SWI`, and the memory-operand forms
of `EX` are the remaining CPU-core gaps; getting NMK004 actually driving
real YM2203/OKI hardware needs system-level integration (a real 68000 +
shared RAM + `jt12`/`jt6295` cores) to get past the host-handshake boundary
this tier's CPU-only testbench can't cross on its own.
