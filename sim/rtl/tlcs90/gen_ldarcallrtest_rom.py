#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_ldarcallrtest.cpp's `prog[]` — same technique as gen_blocktest_rom.py
# etc. Run directly (`python3 gen_ldarcallrtest_rom.py`) to print the C
# array and the computed expected values; paste the array into
# tb_ldarcallrtest.cpp's `prog[]` if this file is edited.
#
# Builds the program address-by-address (rather than emitting bytes blind)
# so the M_D16 "raw-1" displacement for LDAR/CALLR/JR can be computed
# exactly from each instruction's own address, the same arithmetic the CPU
# itself performs (target = pc_after_instruction + raw16 - 1).
#
# Three sub-tests:
#   1. LDAR HL,+cd: HL becomes PC-relative, no bus access, no flags.
#   2. CALLR +cd: unconditional push+jump to a small subroutine that
#      writes a marker and RETs — proving both the jump landed exactly
#      right AND the pushed return address is correct (execution resumes
#      exactly after the CALLR instruction, not off by one).
#   3. JR T,+cd (16-bit form, opcode 0x1b): jumps over an 8-byte "poison"
#      block that writes a *different* marker and then self-loops forever
#      if ever reached — so an off-by-one landing either short or long is
#      guaranteed to leave the real marker unwritten, not just executed a
#      cycle or two late.
addrs = {}
prog = bytearray()


def here():
	return len(prog)


def emit(*bs):
	for b in bs:
		prog.append(b & 0xFF)


def ld_r16_imm(reg, val):
	op = {"bc": 0x38, "de": 0x39, "hl": 0x3A, "sp": 0x3E}[reg]
	emit(op, val & 0xFF, (val >> 8) & 0xFF)


def ld_a_imm(val):
	emit(0x36, val & 0xFF)


def ld_mem16_a(addr):
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, 0x26)


def ld_mem16_r16(addr, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	emit(0xEB, addr & 0xFF, (addr >> 8) & 0xFF, sel)


def jr_short_loop():
	emit(0xC8, 0xFE)  # JR T,-2 (self-loop, 8-bit form — already verified elsewhere)


def d16_raw(target, pc_after):
	# Inverse of the CPU's own `target = pc_after + raw - 1`.
	return (target - pc_after + 1) & 0xFFFF


def ldar(target_hl):
	pc_after = here() + 3
	raw = d16_raw(target_hl, pc_after)
	emit(0x17, raw & 0xFF, (raw >> 8) & 0xFF)


def callr(target):
	pc_after = here() + 3
	raw = d16_raw(target, pc_after)
	emit(0x1D, raw & 0xFF, (raw >> 8) & 0xFF)


def jr16(target):
	pc_after = here() + 3
	raw = d16_raw(target, pc_after)
	emit(0x1B, raw & 0xFF, (raw >> 8) & 0xFF)


OBS = 0x9000
OBS_LDAR_HL = OBS + 0
OBS_CALLR_SUB_HIT = OBS + 2
OBS_CALLR_RET = OBS + 4
OBS_JR_MARK = OBS + 6

# ---- main line ----
ld_r16_imm("sp", 0xF000)

# 1. LDAR HL,+cd -> HL = 0x5000
ldar(0x5000)
ld_mem16_r16(OBS_LDAR_HL, "hl")

# 2. CALLR to a subroutine at a fixed forward address; the subroutine
# writes a marker and RETs. Reserve the subroutine's address now so
# callr() can reference it, patch the call site's target after the whole
# main line is laid out (needs the subroutine placed after the JR test,
# so its own address isn't known until then) -- simplest: lay out the
# subroutine FIRST at a fixed, generously-clear-of-everything-else
# address instead of interleaving.
SUBROUTINE_ADDR = 0x0100

callr(SUBROUTINE_ADDR)
addrs["callr_return_site"] = here()
ld_a_imm(0xAB)
ld_mem16_a(OBS_CALLR_RET)  # only reached if RET returned to exactly here

# 3. JR T,+cd (16-bit, unconditional) over an 8-byte poison block that
# writes a *wrong* marker and self-loops forever if ever reached.
jr_site = here()
POISON_LEN = 8
target_after_poison = jr_site + 3 + POISON_LEN
jr16(target_after_poison)
poison_start = here()
ld_a_imm(0xBA)
ld_mem16_a(OBS_JR_MARK)  # "wrong marker" — must NEVER execute
jr_short_loop()  # traps here forever if the jump undershot/overshot
assert here() - poison_start == POISON_LEN, here() - poison_start
assert here() == target_after_poison
ld_a_imm(0xEF)
ld_mem16_a(OBS_JR_MARK)  # correct marker

jr_short_loop()  # final self-loop park

# ---- subroutine (placed at a fixed address, independent of the main
# line's own length) ----
sub = bytearray()


def emit_sub(*bs):
	for b in bs:
		sub.append(b & 0xFF)


emit_sub(0x36, 0xCD)  # LD A,0xCD
emit_sub(0xEB, OBS_CALLR_SUB_HIT & 0xFF, (OBS_CALLR_SUB_HIT >> 8) & 0xFF, 0x26)  # LD (OBS_CALLR_SUB_HIT),A
emit_sub(0x1E)  # RET (unconditional — base table 0x1e)

if __name__ == "__main__":
	print(f"// main line: {len(prog)} bytes, subroutine: {len(sub)} bytes")
	print("// main line:")
	for i in range(0, len(prog), 16):
		row = ", ".join(f"0x{b:02X}" for b in prog[i:i + 16])
		print(f"\t\t{row},")
	print(f"// subroutine, placed at 0x{SUBROUTINE_ADDR:04X}:")
	for i in range(0, len(sub), 16):
		row = ", ".join(f"0x{b:02X}" for b in sub[i:i + 16])
		print(f"\t\t{row},")
	print(f"SUBROUTINE_ADDR=0x{SUBROUTINE_ADDR:04X}")
	print(f"OBS_LDAR_HL=0x{OBS_LDAR_HL:04X}")
	print(f"OBS_CALLR_SUB_HIT=0x{OBS_CALLR_SUB_HIT:04X}")
	print(f"OBS_CALLR_RET=0x{OBS_CALLR_RET:04X} (callr_return_site=0x{addrs['callr_return_site']:04X})")
	print(f"OBS_JR_MARK=0x{OBS_JR_MARK:04X}")
