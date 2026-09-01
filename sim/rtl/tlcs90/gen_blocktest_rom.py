#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded (as a plain
# byte array, not a $readmemh file — this program is small and doesn't need
# nmk004_core.sv's memory map) into tb_blocktest.cpp's `prog[]`. Not run by
# the Makefile; this is the documentation of *how* those bytes were
# assembled and the tool to regenerate them if the test program ever needs
# to change — see tb_blocktest.cpp's header for what each sub-test proves.
#
# Run directly (`python3 gen_blocktest_rom.py`) to print the C array; paste
# the output into tb_blocktest.cpp's `prog[]` if this file is edited.
prog = bytearray()


def emit(*bs):
	for b in bs:
		prog.append(b & 0xFF)


def ld_r16_imm(reg, val):
	op = {"bc": 0x38, "de": 0x39, "hl": 0x3A}[reg]
	emit(op, val & 0xFF, (val >> 8) & 0xFF)


def ld_a_imm(val):
	emit(0x36, val & 0xFF)


def scf():
	emit(0x0D)


def blockop(name):
	sel = {
		"LDI": 0x58, "LDIR": 0x59, "LDD": 0x5A, "LDDR": 0x5B,
		"CPI": 0x5C, "CPIR": 0x5D, "CPD": 0x5E, "CPDR": 0x5F,
	}[name]
	emit(0xFE, sel)


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def push_af():
	emit(0x56)


def pop_hl():
	emit(0x5A)


SRC1, DST1 = 0x2000, 0x3000  # LDIR: 5 bytes, ascending
SRC2, DST2 = 0x2100, 0x3100  # LDDR: 4 bytes, descending
SRC3 = 0x2200                # CPIR: 5 bytes, 0xCC present at index 2
SRC4 = 0x2300                # CPDR: 5 bytes, 0xCC absent
SRC5, DST5 = 0x2400, 0x3400  # LDI: single-step, must not repeat

OBS = 0x9000
OBS_LDIR_BC, OBS_LDIR_HL, OBS_LDIR_DE = OBS + 0, OBS + 2, OBS + 4
OBS_LDDR_BC, OBS_LDDR_HL, OBS_LDDR_DE = OBS + 6, OBS + 8, OBS + 10
OBS_CPIR_BC, OBS_CPIR_HL, OBS_CPIR_F = OBS + 12, OBS + 14, OBS + 16
OBS_CPDR_BC, OBS_CPDR_F = OBS + 18, OBS + 20
OBS_LDI_BC = OBS + 22

ld_r16_imm("hl", SRC1); ld_r16_imm("de", DST1); ld_r16_imm("bc", 5)
blockop("LDIR")
ld_mem16_r16(OBS_LDIR_BC, "bc"); ld_mem16_r16(OBS_LDIR_HL, "hl"); ld_mem16_r16(OBS_LDIR_DE, "de")

ld_r16_imm("hl", SRC2 + 3); ld_r16_imm("de", DST2 + 3); ld_r16_imm("bc", 4)
blockop("LDDR")
ld_mem16_r16(OBS_LDDR_BC, "bc"); ld_mem16_r16(OBS_LDDR_HL, "hl"); ld_mem16_r16(OBS_LDDR_DE, "de")

ld_r16_imm("hl", SRC3); ld_r16_imm("bc", 5); scf(); ld_a_imm(0xCC)
blockop("CPIR")
ld_mem16_r16(OBS_CPIR_BC, "bc"); ld_mem16_r16(OBS_CPIR_HL, "hl")
push_af(); pop_hl(); ld_mem16_r16(OBS_CPIR_F, "hl")

ld_r16_imm("hl", SRC4 + 4); ld_r16_imm("bc", 5); scf(); ld_a_imm(0xCC)
blockop("CPDR")
ld_mem16_r16(OBS_CPDR_BC, "bc")
push_af(); pop_hl(); ld_mem16_r16(OBS_CPDR_F, "hl")

ld_r16_imm("hl", SRC5); ld_r16_imm("de", DST5); ld_r16_imm("bc", 2)
blockop("LDI")
ld_mem16_r16(OBS_LDI_BC, "bc")

emit(0xC8, 0xFE)  # JR T,-2 (self-loop park)

if __name__ == "__main__":
	print(f"// {len(prog)} bytes")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
