#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_extest.cpp's `prog[]` — same technique as the other gen_*_rom.py
# scripts this session. Run directly (`python3 gen_extest_rom.py`) to
# print the C array; paste it into tb_extest.cpp's `prog[]` if this file
# is edited.
#
# Two sub-tests, deliberately using two *different* addressing forms
# (register-indirect and direct-address) so a bug specific to one
# prefix group's own address resolution can't hide behind only ever
# testing the other — same reasoning tb_rldtest.cpp already established
# for RLD/RRD, which share this exact same pfx_is_src decode branch:
#   1. EX (HL),DE — the (gg) register-indirect form.
#   2. EX (0x2100),BC — the (mn) direct-address form.
# Both directions of the swap are checked independently: the register
# ends up with the memory word's original value, AND the memory word
# ends up with the register's original value (a bug that only wrote one
# direction, or wrote the same value to both, would still leave one of
# these four checks wrong).
prog = bytearray()


def emit(*bs):
	for b in bs:
		prog.append(b & 0xFF)


def ld_r16_imm(reg, val):
	op = {"bc": 0x38, "de": 0x39, "hl": 0x3A}[reg]
	emit(op, val & 0xFF, (val >> 8) & 0xFF)


def ex_gg_rr(gg_reg, rr_reg):
	gg = {"bc": 0x00, "de": 0x01, "hl": 0x02, "ix": 0x04, "iy": 0x05, "sp": 0x06}[gg_reg]
	rr = {"bc": 0x00, "de": 0x01, "hl": 0x02, "ix": 0x04, "iy": 0x05, "sp": 0x06}[rr_reg]
	emit(0xE0 + gg, 0x50 + rr)


def ex_mn_rr(addr, rr_reg):
	rr = {"bc": 0x00, "de": 0x01, "hl": 0x02, "ix": 0x04, "iy": 0x05, "sp": 0x06}[rr_reg]
	emit(0xE3, addr & 0xFF, (addr >> 8) & 0xFF, 0x50 + rr)


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def jr_short_loop():
	emit(0xC8, 0xFE)


M1 = 0x2000  # EX (HL),DE's memory operand
M2 = 0x2100  # EX (0x2100),BC's memory operand

OBS = 0x9000
OBS_DE_AFTER = OBS + 0
OBS_BC_AFTER = OBS + 2

# --- EX (HL),DE: M[M1]=0x1234, DE=0xABCD -> DE=0x1234, M[M1]=0xABCD ---
ld_r16_imm("hl", M1)
ld_r16_imm("de", 0xABCD)
ex_gg_rr("hl", "de")
ld_mem16_r16(OBS_DE_AFTER, "de")

# --- EX (0x2100),BC: M[M2]=0x5678, BC=0x9ABC -> BC=0x5678, M[M2]=0x9ABC ---
ld_r16_imm("bc", 0x9ABC)
ex_mn_rr(M2, "bc")
ld_mem16_r16(OBS_BC_AFTER, "bc")

jr_short_loop()  # self-loop park

if __name__ == "__main__":
	print(f"// {len(prog)} bytes")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
	print(f"M1=0x{M1:04X} M2=0x{M2:04X}")
	print(f"OBS_DE_AFTER=0x{OBS_DE_AFTER:04X} OBS_BC_AFTER=0x{OBS_BC_AFTER:04X}")
