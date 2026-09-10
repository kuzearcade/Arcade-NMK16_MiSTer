#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_flagtest.cpp's `prog[]` — same technique as the other gen_*_rom.py
# scripts. Run directly (`python3 gen_flagtest_rom.py`) to print the C
# array; paste it into tb_flagtest.cpp's `prog[]` if this file is edited.
#
# Regression gate for the two CPU-core bugs found by register-state
# tracing against a MAME oracle during the GunNail sound-sequencer
# investigation (docs/hw-bringup.md, "Fourth pass"; docs/known-issues.md
# NMK-5), plus the follow-on bug the first fix left behind. Reference
# semantics from mame/src/devices/cpu/tlcs90/tlcs90.cpp:
#
#   INC/DEC (8-bit):  F = (F & (IF|CF)) | SZHV_xxx[a8]; if (a8==0) F |= XCF
#                     — XCF is *recomputed* every time (cleared unless the
#                     result is exactly zero). Bug 1: the RTL never set it.
#   INCX/DECX:        execute only `if (F & XCF)`, else do nothing — the
#                     chaining mechanism the above XCF feeds ("INC lo;
#                     INCX hi").
#   SET/RES b,g:      `OP( SET,4 ) BIT8( 1, b1 - 0xb8 ) R8( 2, b0 - 0xf8 )`
#                     under the 0xF8+g prefix — the operand register is g,
#                     the prefix byte's own code. Bug 2: the RTL wrote the
#                     result to memory instead of the register (a no-op on
#                     g). Bug 2b: the first fix wrote back to A regardless
#                     of g, correct for `res 7,a` (all GunNail uses) and
#                     wrong for every other register.
#
# Sub-tests (each observed through its own slot at OBS, so one failure
# can't mask another):
#   1. DEC A to zero sets XCF (and ZF/NF), CF preserved: SCF; LD A,1; DEC A
#      -> F = ZF|NF|XCF|CF = 0x4B.
#   2. DEC A to non-zero *clears* XCF: LD A,2; DEC A -> F = NF|CF = 0x03
#      (CF still preserved from the SCF; XCF gone — proves recompute, not
#      sticky).
#   3. INC A wrapping to zero sets XCF (and ZF/HF): LD A,0xFF; INC A ->
#      F = ZF|HF|XCF|CF = 0x59.
#   4. INCX chaining on a memory pair at $FF10/$FF11 (INCX only has
#      memory forms; the base-table one is `INCX ($FF00+n)`): lo=0xFF,
#      hi=0x12. INC lo -> 0x00 (XCF=1); INCX hi -> 0x13. Then INC lo ->
#      0x01 (XCF=0); INCX hi -> must NOT run, stays 0x13. Expect
#      lo=0x01, hi=0x13 (an always-executing INCX would give hi=0x14; a
#      never-executing one, 0x12).
#   5. DECX chaining likewise at $FF20/$FF21: lo=0x01, hi=0x34. DEC lo ->
#      0x00 (XCF=1); DECX hi -> 0x33. DEC lo -> 0xFF (XCF=0); DECX hi ->
#      stays 0x33. Expect lo=0xFF, hi=0x33.
#   6. SET/RES on A (prefix 0xFE): LD A,0; SET 7,A; SET 0,A; RES 7,A ->
#      A = 0x01.
#   7. SET/RES on non-A registers (prefixes 0xF8/0xF9), done *after* 6 and
#      before A is observed, with bit choices that would visibly corrupt
#      A if the writeback went to A instead: LD B,0; LD C,0xFF; SET 5,B;
#      RES 4,C -> BC = 0x20EF, and A still 0x01 (bug 2b gives BC=0x00FF,
#      A=0x21).
prog = bytearray()


def emit(*bs):
	for b in bs:
		prog.append(b & 0xFF)


R8 = {"b": 0, "c": 1, "d": 2, "e": 3, "h": 4, "l": 5, "a": 6}


def ld_r8_imm(reg, val):
	emit(0x30 + R8[reg], val)          # LD r,n


def inc_a():
	emit(0x80 + R8["a"])               # INC r


def dec_a():
	emit(0x88 + R8["a"])               # DEC r


def scf():
	emit(0x0D)


def inc_ff(n):
	emit(0x87, n)                      # INC ($FF00+n)


def incx_ff(n):
	emit(0x07, n)                      # INCX ($FF00+n)


def dec_ff(n):
	emit(0x8F, n)                      # DEC ($FF00+n)


def decx_ff(n):
	emit(0x0F, n)                      # DECX ($FF00+n)


def set_b_g(bit, reg):
	emit(0xF8 + R8[reg], 0xB8 + bit)   # SET b,g


def res_b_g(bit, reg):
	emit(0xF8 + R8[reg], 0xB0 + bit)   # RES b,g


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def push_af():
	emit(0x56)


def pop_hl():
	emit(0x5A)


def observe_af(addr):
	push_af(); pop_hl(); ld_mem16_r16(addr, "hl")   # word = {A, F}


OBS = 0x9000
OBS_DEC0_AF = OBS + 0   # after DEC A -> 0
OBS_DEC1_AF = OBS + 2   # after DEC A -> 1
OBS_INC0_AF = OBS + 4   # after INC A 0xFF -> 0
OBS_BC      = OBS + 6   # after SET 5,B / RES 4,C
OBS_SETRES_AF = OBS + 8 # A after the register SET/RES sequence

PAIR_INC = 0x10   # $FF10 lo, $FF11 hi
PAIR_DEC = 0x20   # $FF20 lo, $FF21 hi

# 1. DEC A to zero: SCF first so a preserved CF is provable.
scf()
ld_r8_imm("a", 0x01)
dec_a()
observe_af(OBS_DEC0_AF)

# 2. DEC A to non-zero: XCF must be cleared again, CF still 1.
ld_r8_imm("a", 0x02)
dec_a()
observe_af(OBS_DEC1_AF)

# 3. INC A wrapping to zero.
ld_r8_imm("a", 0xFF)
inc_a()
observe_af(OBS_INC0_AF)

# 4. INCX chain: fires once, then must not fire.
inc_ff(PAIR_INC); incx_ff(PAIR_INC + 1)
inc_ff(PAIR_INC); incx_ff(PAIR_INC + 1)

# 5. DECX chain: fires once, then must not fire.
dec_ff(PAIR_DEC); decx_ff(PAIR_DEC + 1)
dec_ff(PAIR_DEC); decx_ff(PAIR_DEC + 1)

# 6. SET/RES on A.
ld_r8_imm("a", 0x00)
set_b_g(7, "a")
set_b_g(0, "a")
res_b_g(7, "a")

# 7. SET/RES on B and C, then observe BC and (only now) A.
ld_r8_imm("b", 0x00)
ld_r8_imm("c", 0xFF)
set_b_g(5, "b")
res_b_g(4, "c")
ld_mem16_r16(OBS_BC, "bc")
observe_af(OBS_SETRES_AF)

emit(0xC8, 0xFE)  # JR T,-2 (self-loop park)

if __name__ == "__main__":
	print(f"// {len(prog)} bytes")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
	for name in ("OBS_DEC0_AF", "OBS_DEC1_AF", "OBS_INC0_AF", "OBS_BC", "OBS_SETRES_AF"):
		print(f"{name}=0x{globals()[name]:04X}")
	print(f"PAIR_INC=0xFF{PAIR_INC:02X} PAIR_DEC=0xFF{PAIR_DEC:02X}")
