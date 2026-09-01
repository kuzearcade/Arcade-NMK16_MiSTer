#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_rldtest.cpp's `prog[]` — same technique as gen_blocktest_rom.py.
# Run directly (`python3 gen_rldtest_rom.py`) to print the C array; paste
# the output into tb_rldtest.cpp's `prog[]` if this file is edited.
#
# Two sub-tests, exercising RLD/RRD through two *different* addressing
# forms (proving the pfx_is_src mem_mode wiring works generically, not
# just for one prefix group):
#   1. RLD (HL) — the (gg) register-indirect form.
#   2. RRD (mn) — the direct-16-bit-address form.
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


def rcf():
	emit(0x0C)


def rld_hl():
	emit(0xE2, 0x10)  # (gg) group, gg=HL(2) -> 0xE0+2; selector 0x10=RLD


def rrd_mn(addr):
	emit(0xE3, addr & 0xFF, (addr >> 8) & 0xFF, 0x11)  # (mn) group; selector 0x11=RRD


def ld_mem16_ff(addr):
	# LD ($FF00+n),A — n = addr & 0xff (addr must be in 0xff00-0xffff)
	emit(0x2F, addr & 0xFF)


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def push_af():
	emit(0x56)


def pop_hl():
	emit(0x5A)


M1 = 0x2000  # RLD test's memory operand
M2 = 0x2100  # RRD test's memory operand

OBS = 0x9000
OBS_RLD_A, OBS_RLD_F = OBS + 0, OBS + 2
OBS_RRD_A, OBS_RRD_F = OBS + 4, OBS + 6

# --- RLD (HL): A=0x3F, M[M1]=0xA5 ---
# new M = {M_lo,A_lo} = {5,F} = 0x5F; new A = {A_hi,M_hi} = {3,A} = 0x3A
# F = SZP[0x3A] (even parity -> PF set, not S, not Z) | CF preserved (=1 via SCF)
ld_r16_imm("hl", M1)
ld_a_imm(0x3F)
scf()
rld_hl()
ld_mem16_ff(0xFFE0)  # observe A (opcode 0x2F consumes only the low byte, giving $FF00|0xE0)
push_af(); pop_hl(); ld_mem16_r16(OBS_RLD_F, "hl")  # observe F (low byte of the write)

# --- RRD (mn): A=0x7C, M[M2]=0x91 ---
# new M = {A_lo,M_hi} = {C,9} = 0xC9; new A = {A_hi,M_lo} = {7,1} = 0x71
# F = SZP[0x71] (even parity -> PF set) | CF preserved (=0 via RCF)
ld_a_imm(0x7C)
rcf()
rrd_mn(M2)
ld_mem16_ff(0xFFE1)  # observe A
push_af(); pop_hl(); ld_mem16_r16(OBS_RRD_F, "hl")  # observe F

emit(0xC8, 0xFE)  # JR T,-2 (self-loop park)

if __name__ == "__main__":
	print(f"// {len(prog)} bytes")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
	print(f"M1=0x{M1:04X} M2=0x{M2:04X}")
	print(f"OBS_RLD_F=0x{OBS_RLD_F:04X} OBS_RRD_F=0x{OBS_RRD_F:04X}")
