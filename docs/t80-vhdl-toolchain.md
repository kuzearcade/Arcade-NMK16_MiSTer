# T80 VHDL→Verilog toolchain (GHDL + ghdl-yosys-plugin)

## Why this exists

Tier 5 (Family E, Raiden-sound bootlegs) and Tier 3 (Family C, Z80-direct
boards) both need the Z80 CPU. This project vendors it as **T80**
(`rtl/third_party/t80/`, bootstrap-fetched per `deps.lock`), which is pure
VHDL (`T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`,
`T80_Reg.vhd`, `T80s.vhd`, plus other top-level variants) — the real logic
used unmodified for the Quartus/hardware build.

Verilator (this project's whole simulation methodology, see
`docs/sim-harness.md`) has **zero VHDL support**. Rather than substitute a
different, hand-picked Z80 core for simulation (which would mean verifying
two different CPU implementations against the oracle instead of one), this
translates the *real* T80 VHDL into an equivalent synthesizable Verilog
netlist using GHDL + Yosys, once, and commits the result
(`rtl/third_party_gen/t80/T80s.v`) for simulation use only. The vendored
VHDL stays untouched and is what actually goes into the Quartus build.

## What's committed vs. generated

- `rtl/third_party_gen/t80/T80s.v` — the generated Verilog netlist
  (T80s wrapper + T80/T80_ALU/T80_MCode/T80_Reg, ~20K lines, real gates
  and `always @(posedge...)` DFF blocks — not a stub). **Committed** —
  this directory is tracked, unlike `rtl/third_party/` which is gitignored.
- `rtl/third_party_gen/t80/ghdl-compat.patch` — a small patch applied to a
  *copy* of the vendored VHDL before translation (never touches
  `rtl/third_party/t80/` itself). **Committed.**
- `tools/gen_t80_verilog.sh` — regenerates `T80s.v` from the current
  `rtl/third_party/t80/` + the patch. Only needs to be re-run if
  `deps.lock`'s `t80` pin changes.

## Building the toolchain (one-time, not part of tools/bootstrap.sh)

This is a heavyweight dev-toolchain setup, not a per-build dependency —
regenerating `T80s.v` is rare (only on a T80 version bump), so it isn't
wired into the normal build/sim flow.

Ubuntu's packaged `ghdl` (`apt install ghdl`) is **not sufficient** — it's
built without `--enable-synth`, so `ghdl-yosys-plugin` can't link against
it (missing `libghdl_synth__*` symbols, incomplete `Pval`/`synth_instance_type`
types in `synth.h`). Confirmed by reading `ghdl-yosys-plugin`'s own `ci.sh`,
which builds GHDL from source with exactly `--enable-libghdl --enable-synth`.

```sh
# 1. Build GHDL from source with synth support
git clone --depth 1 https://github.com/ghdl/ghdl
cd ghdl
./configure --enable-libghdl --enable-synth --prefix=$HOME/ghdl-install
make all GNATMAKE="gnatmake -j4"   # needs gnat (apt install gnat)
make install

# 2. Build ghdl-yosys-plugin against it
git clone https://github.com/ghdl/ghdl-yosys-plugin
cd ghdl-yosys-plugin
# Drop vhdl_backend.o from the OBJS line in the Makefile — it's an
# unrelated, optional `write_vhdl` backend that doesn't build against
# apt's Yosys 0.52 API (ID::single_bit_vector / is_builtin_ff / etc. were
# removed/renamed upstream) and ghdl.cc/ghdl_rename.cc don't depend on it.
make GHDL=$HOME/ghdl-install/bin/ghdl
# -> produces ghdl.so
```

`GHDL=... make ...` (shell-prefix env var) does **not** work — the
Makefile sets `GHDL=ghdl` via plain assignment, which always wins over an
inherited environment variable unless `make -e` is used. Use
`make GHDL=...` (a real command-line variable override) instead.

## VHDL compatibility issues found translating T80 specifically

None of these are toolchain bugs — they're all real legacy-VHDL-style
quirks in T80's own source (bare component instantiation without a
`component` declaration, mixing `std_logic_unsigned` with `std_logic_1164`)
that permissive tools (Quartus, ModelSim, older GHDL) silently accept but
strict elaboration does not. Fixed via `ghdl-compat.patch`, applied only
to a scratch copy before translation:

1. **Unbound component instantiations.** `u0 : T80 generic map(...) port
   map(...)` (and, inside `T80.vhd` itself, `mcode : T80_MCode`,
   `alu : T80_ALU`, `Regs : T80_Reg`) use bare-entity-name instantiation
   with no `component ... end component` declaration and no `entity`
   keyword. GHDL warns `instance "u0" of component "T80" is not bound`
   and elaborates it as an empty interface-only blackbox — the real logic
   never gets synthesized. Fixed by making the binding explicit:
   `u0 : entity work.T80(rtl)`.

2. **`std_logic_unsigned`/`std_logic_1164` "=" ambiguity.** `use
   IEEE.STD_LOGIC_UNSIGNED.all;` (needed for `x"7"`-style comparisons
   elsewhere in the file) declares its own `"="` for `std_logic_vector`,
   which collides with the *implicit* `"="` every array type gets from its
   own type declaration (`std_logic_1164`'s `STD_LOGIC_VECTOR` type). Both
   have an identical `[std_logic_vector, std_logic_vector return boolean]`
   signature, so any `IR = "00110110"`-style comparison is genuinely
   ambiguous under strict LRM overload resolution — GHDL only surfaces
   this once something forces real elaboration of the architecture body
   (fixing issue #1 above triggers it). Fixed with GHDL's own
   `-fexplicit` flag ("give priority to explicitly declared operator"),
   exactly the documented escape hatch for this scenario.

3. **One literal-width ambiguity.** `ioq := (ioq and x"7") xor
   ('0'&BusA);` — `ioq` is 9 bits, `x"7"` is nominally 4 bits (one hex
   digit). Permissive tools resize it in context; strict elaboration
   doesn't. Fixed by writing the literal explicitly at the target width:
   `"000000111"` (same value, unambiguous).

4. **FSM-inferred latches.** GHDL's synth backend treats a
   conditionally-assigned signal with no `else` (a common FSM/process
   idiom, real hardware behavior) as an error unless `--latches` is
   passed, confirming the design intends it.

Final working command (also what `tools/gen_t80_verilog.sh` runs):

```sh
yosys -m /path/to/ghdl.so -p "
  ghdl --std=93 -fsynopsys -fexplicit --latches \
    T80_Pack.vhd T80.vhd T80_ALU.vhd T80_MCode.vhd T80_Reg.vhd T80s.vhd -e t80s;
  synth;
  write_verilog T80s.v
"
```

## Verification

- `synth` produced 5 real modules (`T80s`, `t80_Brtl_...`,
  `t80_alu_Brtl_...`, `t80_mcode_Brtl_...`, `t80_reg_Brtl`) with real gate
  counts (thousands of `$_DFFE_*`/`$_MUX_`/etc. cells across the
  hierarchy — not an empty/stub blackbox).
- `write_verilog`'s output expands DFF cells into readable
  `always @(posedge CLK, negedge RESET_n)` blocks, not raw internal
  primitive instantiations.
- `verilator --lint-only -Wall -Wno-fatal rtl/third_party_gen/t80/T80s.v`
  — **0 errors**, exit 0 (857 warnings, all expected: unnamed
  Yosys-generated wire names, unused sub-bits on internal nets — standard
  noise for any synthesized netlist, not a correctness signal).
- `tools/gen_t80_verilog.sh` re-run standalone from a clean checkout
  reproduces `T80s.v` byte-for-byte.

Not yet done: no oracle/cycle-accuracy verification against MAME's
`tlcs90`-style trace harness — that's the same methodology used for every
other CPU core in this project (see `docs/sim-harness.md`), still pending
once actual Tier 5/Tier 3 system integration begins.
