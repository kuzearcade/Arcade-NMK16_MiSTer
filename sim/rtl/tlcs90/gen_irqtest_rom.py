#!/usr/bin/env python3
# Generates roms/irqtest_boot.hex — a small synthetic TLCS-90 program used
# by `make run-irqtest` to verify the CPU core's interrupt-dispatch
# mechanism end-to-end (vector jump, PUSH PC/AF ordering, IF clear/restore,
# RETI return). See docs/tier2-tlcs90.md "Fourth verification result" for
# why this exists: the real NMK004 boot ROM's own EI instruction (PC=0x1DA)
# is unreachable in a CPU-only testbench (it's past a host-handshake wait
# loop only a real 68000 could satisfy), so real interrupt dispatch can't be
# exercised via the real ROM here.
#
# Not committed (see .gitignore's blanket **/roms/*.hex rule) — regenerate
# with `python3 gen_irqtest_rom.py` before `make run-irqtest` (the Makefile
# target depends on it).
#
# Program: set SP (required — TLCS-90 doesn't initialize it at reset, and
# an uninitialized SP=0 pushes into unmapped 0xfff0-0xffff address space in
# nmk004_core's memory map, silently discarding the return address), point
# timer 0 at a fast compare match, enable it and its interrupt, EI, then
# self-loop. RETI is planted at the INTT0 vector the CPU core computes:
# 0x10 + (irq_idx+3)*8 where irq_idx=1 for T0 (bit1 of irq_req/irq_mask)
# -> 0x30.
prog = {
    0x0000: 0x3E, 0x0001: 0x00, 0x0002: 0xFF,  # LD SP,0xFF00
    0x0003: 0x36, 0x0004: 0x3B,                # LD A,0x3B
    0x0005: 0x2F, 0x0006: 0xD4,                # LD (FFD4h),A   ; TREG0
    0x0007: 0x36, 0x0008: 0x01,                # LD A,0x01
    0x0009: 0x2F, 0x000A: 0xD8,                # LD (FFD8h),A   ; TCLK (tclk0=prescale div1)
    0x000B: 0x36, 0x000C: 0x21,                # LD A,0x21
    0x000D: 0x2F, 0x000E: 0xDB,                # LD (FFDBh),A   ; TRUN (master+T0 enable)
    0x000F: 0x36, 0x0010: 0x02,                # LD A,0x02
    0x0011: 0x2F, 0x0012: 0xE7,                # LD (FFE7h),A   ; INTEH (enable INTT0)
    0x0013: 0x03,                              # EI
    0x0014: 0xC8, 0x0015: 0xFE,                # JR T,-2  (self-loop back to 0x0014)
    0x0030: 0x1F,                              # RETI (INTT0 vector)
}

rom = [0x00] * 8192
for addr, val in prog.items():
    rom[addr] = val

with open("roms/irqtest_boot.hex", "w") as f:
    for b in rom:
        f.write("%02x\n" % b)
