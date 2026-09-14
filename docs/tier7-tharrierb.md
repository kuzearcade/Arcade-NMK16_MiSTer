# Task Force Harrier (Lettering bootleg) — the MC68705R3 port

`tharrierb` is the last `nmk16.cpp` set that needed a CPU core this project
did not have. Unlike `tharrier`, whose MCU is undumped and which MAME
replaces with a hardcoded response table (`tharrier_mcu_r`), the bootleg's
protection chip is a **fully dumped MC68705R3** — `mc68705r35.bin`, the whole
4 KB internal image including the bootstrap ROM and the interrupt vectors.
So this is a real CPU port, and "matches MAME" here means the RTL executes
the same instruction stream as MAME's `m6805`, not that it reproduces a
simulation of missing silicon.

The CPU is **jotego's jt6805** (`rtl/third_party/jt680x/hdl`), a microcoded
design: a 4096 x 39-bit control store addressed as `{opcode[7:0], step[3:0]}`,
with the shared sequences (addressing modes, push/pop, interrupt entry) parked
in the slots of opcodes the 6805 leaves illegal and reached through a
one-deep microcode JSR. `rtl/m68705/` holds the control store
(`6805.uc`/`6805.vh`/`6805_param.vh`) and `m68705_core.sv`, the peripheral
wrapper — ports A/B/C/D with their DDRs, the timer, MISC/PCR/ACR/ARR, 112
bytes of RAM and the 4 KB ROM, laid out as
`m6805_hmos_device::internal_map` + `m68705r_device::internal_map` define it.

`tools/uc6805.py` disassembles and reassembles the control store (`dis`,
`asm`, `rt`); the round trip reproduces all 4096 words bit-for-bit, so the
microcode is readable and editable rather than an opaque binary.

## Verifying the CPU against MAME

`sim/rtl/m68705` runs the wrapper standalone against a MAME `m6805`
instruction trace.

Capturing the oracle needs MAME's debugger, driven from Lua because this
build has no `set_instruction_hook` binding:

```
mame tharrierb -debug -debugger none -autoboot_script mcu_io.lua
```
```lua
local d = manager.machine.debugger
d:command('trace out.tr,mcu,noloop')     -- noloop, or runs collapse to a comment
d.execution_state = "run"
```

The MCU's only non-deterministic inputs are Port B (the 68000's data latch),
Port D (the cabinet inputs) and the external IRQ pin. In the traced window
Port D reads `0x00` on every Port C select, so the testbench ties it low;
Port B's reads are replayed from a MAME memory tap in order; and the IRQ is
asserted at the instruction indices MAME took it on
(`roms/irq_at.txt`, from the trace's own `(interrupted at ...)` lines). That
makes the whole run deterministic.

**Result: 960,794 instructions and 13 interrupts, zero mismatches.**

Three traps, each of which first looked like a CPU bug — worth knowing before
building another oracle like this:

- `fetch` and `ni` read **after** the clock edge are the *next*
  microinstruction's control bits. A replayed byte must therefore be retired
  one cycle later than it is detected, and an injected IRQ vectors on the
  boundary it is detected on rather than the following one. Getting the first
  wrong made the MCU read the *second* queued byte on its first Port B read.
- MAME's Lua memory taps are removed when the handle is garbage collected.
  Without keeping it in a global, the Port B log silently stopped two thirds
  of the way through a 400-frame run — which looked exactly like a
  divergence at instruction 645,983.
- MAME's trace prints no line for an interrupt boundary (just an
  `(interrupted at ...)` note), so the RTL's vectoring `ni` must be traced
  but neither compared nor counted.

The withdrawn `e6e7074` branch recorded this CPU as "returns the first
handshake value, then diverges after its first JSR/RTS", blamed on this
project's microcode generator. That was wrong on both counts: JSR and RTS are
correct (they execute at instructions 11-14 of the boot sequence, inside the
matching prefix), and so is everything else the game's MCU program runs.

## NMK-10, again, and this one was load-bearing

The wrapper originally read its 4 KB ROM and 112 B RAM combinationally.
Quartus cannot infer M10K from an asynchronous read, so both became flops:
**17,782 ALMs for this module alone**, against 41,910 on the device with
`NMK16_Gunnail` already using 26,492. That is the real reason the set had never
shipped.

jt6805 samples `din` on its own `cen` — the chip's 2.4576 MHz crystal, one
pulse in roughly 16 `clk_sys` — and holds the address for that whole window,
so a **`clk_sys`-registered read** settles long before the CPU latches it and
needs no change to jt6805 at all:

| | ALMs | M10K |
|---|---|---|
| asynchronous reads | 17,782 | 0 |
| registered reads | **830** | 5 |

The microcode ROM itself stays as logic (about 700 of those 830 ALMs —
Quartus compresses it well, the control store being mostly zeros) and is left
alone.

Two read paths were also matched to MAME exactly even though this game never
exercises them: an input-configured Port C bit reads 1 (`port_r` is
`mask | (latch & ddr) | (input & ~ddr)`, and `m_port_input` powers up 0xFF),
and the 0x0F39-0x0F7F gap between the user EPROM and the bootstrap ROM reads
0xFF rather than the zeros the dumped image holds there.

## The interrupt is edge triggered and latched

`m6805_base_device::execute_set_input` only ever ORs into
`m_pending_interrupts`, on the transition to ASSERT, and nothing clears it
until the CPU services the interrupt. jt6805 instead samples its `irq` input
live at an instruction boundary.

That difference is not academic here. `tharrierb`'s 68000 pulses the MCU's
IRQ by writing 0 then 1 to `0x080010` back to back — ten 10 MHz cycles, about
1 us — while the MCU's instructions are 2-10 us long, so the pulse is simply
missed. The symptom was the 68000 spinning forever at `0x83C` on the first
handshake with a **provably correct** MCU: its instruction trace matched
MAME's for all 882 instructions up to the point MAME took that interrupt, and
then it just kept polling.

`m68705_core.sv` therefore latches the assert edge and clears the latch when
the vector at `0x0FFA` is fetched — the RTL's observable equivalent of MAME's
`interrupt()` clearing the pending bit.

## The game port (game id 55)

`tharrierb_map` is its own map on tharrier's board, so the video (`gfx_tharrier`,
`set_screen_lowres`, `get_sprite_flip`, the BG X scroll snooped from main RAM
word `0x9F00`) and the sound board (Z80 at 4.9152 MHz, YM2203, two OKIs with
`tharrier_okibank_w`) are the ones `tharrier` already uses. What is new:

- Four MCU registers in the I/O block, each with `.mirror(0xf00)`: `0x080000`
  reads `0x8000` (status), `0x080002` reads Port A in the msb and Port B in
  the lsb, `0x080010` bit 0 low asserts the MCU IRQ, `0x080012` is the byte
  Port B reads back. The I/O decode for this map therefore ignores
  `a[11:8]`.
- `soundlatch2` moves to `0x08000F` and the sound latch stays at `0x08001F`;
  flipscreen and the sound-CPU reset are `unmaprw()`, and this map's unmapped
  reads return 0.
- Port D is a five-way input mux selected by Port C[2:0] (0 DSW1, 1 DSW2,
  2 BUTTONS, 3 P1, 4 P2, anything else 0), and **every bit of all five ports
  is `IP_ACTIVE_HIGH`**, so they are built by inverting this family's own
  active-low inputs and the `.mra` `<switches>` default is the raw MAME
  default word `00,00`.
- `0x09C000-0x09CFFF` and `0x09D800-0x09DFFF` are plain RAM ("verified in
  test mode"), carried on the spare BGVRAM2 array.
- The MCU image rides in the protection-firmware slot (`BASE_BYTE_PROT`),
  read back out of SDRAM after reset by the loader the NMK-215/113 boards
  already use, with the 68000 held in reset until it is in.

One ROM-layout subtlety: the bootleg's 8x8 tile ROM is **half** the original's
(0x8000, 1024 tiles). MAME wraps tile codes modulo the region's own tile count
(`gfx_element::get_data` does `code %= m_total_elements`), so the `.mra` fills
the family's 0x10000 slot with a **second copy** of the ROM rather than with
zeros — which reproduces that wrap exactly for every code above 1023.

## Verification

Reference sim (`make GAME=tharrierb` in `sim/rtl/gunnail_mg`, `TB_DSW1=00
TB_DSW2=00`) against MAME 0.289 frames captured through `screen:pixels()`
(**not** `machine.video:snapshot()`, which under `-video none` returns a stale
bitmap). The MCU's own instruction trace is available as
`<game>_prot.trace` — `gunnail_core` routes the M68705's PC through the
TLCS-90 protection debug ports, which this board has no use for.
