#!/usr/bin/env python3
# Derivation source for the synthetic TLCS-90 program hardcoded into
# tb_switest.cpp's `prog[]` — same technique as the other gen_*_rom.py
# scripts this session. Run directly (`python3 gen_switest_rom.py`) to
# print the C array; paste it into tb_switest.cpp's `prog[]` if this file
# is edited.
#
# Lays the program out address-by-address (not just appended blind) since
# SWI's fixed vector (0x0010, INTSWI) and its two real interrupt-vector
# neighbors (0x0008 — no real source there, but a plausible landing spot
# for a vector-arithmetic off-by-one; 0x0018 — NMI's own vector, a
# plausible landing spot for a "used the wrong irq index" bug) all need to
# sit at their real, fixed addresses. Reset starts execution at 0x0000, so
# the main program jumps immediately out of that low region to a safe area
# before any of the vector/poison content.
#
#   0x0000: JP 0x0100                (jump straight to the main program)
#   0x0008: poison A — writes a "landed on 0x0008" marker and traps
#           forever if ever reached (must NOT happen)
#   0x0010: the real SWI/INTSWI vector — corrupts A (proving RETI's
#           restore is real, not just "nothing touched it"), writes an
#           "ISR really ran" marker, and RETIs
#   0x0018: poison B — writes a "landed on NMI's vector instead" marker
#           and traps forever if ever reached (must NOT happen)
#   0x0100: main program — sets SP, A=0x42, SCF (F=0x09: CF=1,XCF=1),
#           DI (IF=0, proving SWI ignores it — genuinely non-maskable),
#           SWI, then (only reachable if RETI returned to exactly the
#           right place) observes A and F are back to their pre-SWI
#           values.
addrs = {}
prog = {}  # address -> byte, sparse


def put(addr, *bs):
	for i, b in enumerate(bs):
		prog[addr + i] = b & 0xFF
	return addr + len(bs)


def jp(addr, target):
	return put(addr, 0x1A, target & 0xFF, (target >> 8) & 0xFF)


def ld_a_imm(addr, val):
	return put(addr, 0x36, val & 0xFF)


def ld_mem16_a(addr, target):
	return put(addr, 0xEB, target & 0xFF, (target >> 8) & 0xFF, 0x26)


def ld_mem16_r16(addr, target, reg):
	sel = {"bc": 0x40, "de": 0x41, "hl": 0x42}[reg]
	return put(addr, 0xEB, target & 0xFF, (target >> 8) & 0xFF, sel)


def ld_r16_imm(addr, reg, val):
	op = {"bc": 0x38, "de": 0x39, "hl": 0x3A, "sp": 0x3E}[reg]
	return put(addr, op, val & 0xFF, (val >> 8) & 0xFF)


def scf(addr):
	return put(addr, 0x0D)


def di(addr):
	return put(addr, 0x02)


def swi(addr):
	return put(addr, 0xFF)


def reti(addr):
	return put(addr, 0x1F)


def jr_short_loop(addr):
	return put(addr, 0xC8, 0xFE)


def push_af(addr):
	return put(addr, 0x56)


def pop_hl(addr):
	return put(addr, 0x5A)


OBS = 0x9000
OBS_ISR_RAN = OBS + 0        # 0x99 if the real ISR at 0x0010 ran
OBS_A_RESTORED = OBS + 2     # 0x42 if RETI correctly restored A
OBS_F_RESTORED = OBS + 4     # 0x09 (low byte) if RETI correctly restored F
OBS_WRONG_0008 = OBS + 6     # must stay 0x00 — poison A must never write here
OBS_WRONG_0018 = OBS + 8     # must stay 0x00 — poison B must never write here

# ---- reset vector ----
jp(0x0000, 0x0100)

# ---- poison A: a wrong-vector landing spot just below the real one ----
a = 0x0008
a = ld_a_imm(a, 0xBA)
a = ld_mem16_a(a, OBS_WRONG_0008)
a = jr_short_loop(a)
assert a == 0x0010, hex(a)

# ---- the real SWI/INTSWI vector ----
a = 0x0010
a = ld_a_imm(a, 0x99)  # deliberately corrupt A
a = ld_mem16_a(a, OBS_ISR_RAN)
a = reti(a)
assert a <= 0x0018, hex(a)
# pad up to 0x0018 with NOPs (0x00) if there's a gap
while a < 0x0018:
	a = put(a, 0x00)

# ---- poison B: NMI's own real vector, a plausible off-by-one target ----
a = 0x0018
a = ld_a_imm(a, 0xBB)
a = ld_mem16_a(a, OBS_WRONG_0018)
a = jr_short_loop(a)

# ---- main program ----
a = 0x0100
a = ld_r16_imm(a, "sp", 0xF000)
a = ld_a_imm(a, 0x42)
a = scf(a)
a = di(a)
a = swi(a)
addrs["swi_return_site"] = a
a = ld_mem16_a(a, OBS_A_RESTORED)
a = push_af(a)
a = pop_hl(a)
a = ld_mem16_r16(a, OBS_F_RESTORED, "hl")
a = jr_short_loop(a)

if __name__ == "__main__":
	lo, hi = min(prog), max(prog)
	print(f"// sparse image, 0x{lo:04X}-0x{hi:04X}")
	print(f"// swi_return_site=0x{addrs['swi_return_site']:04X}")
	for name in ("OBS_ISR_RAN", "OBS_A_RESTORED", "OBS_F_RESTORED", "OBS_WRONG_0008", "OBS_WRONG_0018"):
		print(f"{name}=0x{globals()[name]:04X}")
	print("// {address: byte} entries, for the testbench to poke individually:")
	for addr in sorted(prog):
		print(f"\t\t{{0x{addr:04X}, 0x{prog[addr]:02X}}},")
