#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_muldivtest.cpp's `prog[]` — same technique as gen_blocktest_rom.py /
# gen_rldtest_rom.py. Run directly (`python3 gen_muldivtest_rom.py`) to
# print the C array; paste the output into tb_muldivtest.cpp's `prog[]` if
# this file is edited.
#
# Four sub-tests, F deliberately chained across the three DIV tests
# (rather than re-primed each time) so the same running flag register
# proves both the "set VF" and "clear VF" paths use the *same* quotient
# check, not two independently-lucky flag values:
#   1. MUL: HL(H=0xFF sentinel,L=0xC8) * C(0x03) = 600 (0x0258) — proves
#      the 16-bit product (not just an 8-bit truncation) lands in HL, the
#      old H is fully replaced (not preserved), and — checked against an
#      SCF-primed F — that MUL genuinely touches no flags at all.
#   2. DIV (quotient=400>255, sets VF): HL=4000/B=10 -> H=0(remainder),
#      L=0x90 (400&0xFF), VF set. F chained from MUL's SCF-primed value.
#   3. DIV (quotient=14<=255, clears VF): a *fresh* HL/divisor 100/B=7 ->
#      H=2,L=14, VF cleared — using the *same* F the previous test just
#      set VF=1 in, so a passing check here proves the clear path is real,
#      not a test that would pass by F already being 0.
#   4. DIV by zero: RCF first (known F=0 baseline), then HL(0x12,0x34)/E=0
#      -> H=old L=0x34, L=~old H=0xED, VF forced set unconditionally.
prog = bytearray()


def emit(*bs):
	for b in bs:
		prog.append(b & 0xFF)


def ld_r16_imm(reg, val):
	op = {"bc": 0x38, "de": 0x39, "hl": 0x3A}[reg]
	emit(op, val & 0xFF, (val >> 8) & 0xFF)


def scf():
	emit(0x0D)


def rcf():
	emit(0x0C)


def mul(g):
	# g: R8 code (0=B,1=C,2=D,3=E,4=H,5=L,6=A)
	emit(0xF8 + g, 0x12)


def div(g):
	emit(0xF8 + g, 0x13)


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def push_af():
	emit(0x56)


def pop_hl():
	emit(0x5A)


OBS = 0x9000
OBS_MUL_HL, OBS_MUL_F = OBS + 0, OBS + 2
OBS_DIVA_HL, OBS_DIVA_F = OBS + 4, OBS + 6
OBS_DIVB_HL, OBS_DIVB_F = OBS + 8, OBS + 10
OBS_DIVC_HL, OBS_DIVC_F = OBS + 12, OBS + 14

# --- MUL: HL=0xFFC8 (L=0xC8), C=0x03 -> HL=0x0258, F unchanged (SCF-primed) ---
ld_r16_imm("hl", 0xFFC8)
ld_r16_imm("bc", 0x0003)
scf()
mul(1)  # g=C
ld_mem16_r16(OBS_MUL_HL, "hl")
push_af(); pop_hl(); ld_mem16_r16(OBS_MUL_F, "hl")

# --- DIV A: HL=4000, B=10 -> quotient 400 (>255, VF set), remainder 0 ---
ld_r16_imm("hl", 4000)
ld_r16_imm("bc", 0x0A00)
div(0)  # g=B
ld_mem16_r16(OBS_DIVA_HL, "hl")
push_af(); pop_hl(); ld_mem16_r16(OBS_DIVA_F, "hl")

# --- DIV B: HL=100, B=7 -> quotient 14 (<=255, VF cleared), remainder 2 ---
# F is NOT re-primed here: it's whatever DIV A just left it as (VF=1).
ld_r16_imm("hl", 100)
ld_r16_imm("bc", 0x0700)
div(0)  # g=B
ld_mem16_r16(OBS_DIVB_HL, "hl")
push_af(); pop_hl(); ld_mem16_r16(OBS_DIVB_F, "hl")

# --- DIV C: divide by zero. HL=0x1234, E=0 -> H=old L, L=~old H, VF set ---
rcf()
ld_r16_imm("hl", 0x1234)
ld_r16_imm("de", 0x0000)
div(3)  # g=E
ld_mem16_r16(OBS_DIVC_HL, "hl")
push_af(); pop_hl(); ld_mem16_r16(OBS_DIVC_F, "hl")

emit(0xC8, 0xFE)  # JR T,-2 (self-loop park)

if __name__ == "__main__":
	print(f"// {len(prog)} bytes")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
	for name in ("OBS_MUL_HL", "OBS_MUL_F", "OBS_DIVA_HL", "OBS_DIVA_F",
	             "OBS_DIVB_HL", "OBS_DIVB_F", "OBS_DIVC_HL", "OBS_DIVC_F"):
		print(f"{name}=0x{globals()[name]:04X}")
