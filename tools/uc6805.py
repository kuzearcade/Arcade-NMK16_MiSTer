#!/usr/bin/env python3
"""Assembler/disassembler for jt680x's jt6805 microcode ROM.

The control store is 4096 x 39 bits, addressed as {opcode[7:0], step[3:0]}:
every 6805 opcode gets a 16-microinstruction slot, and the shared sequences
(addressing modes, push/pop, interrupt entry) live in the slots of opcodes
the 6805 leaves illegal, reached through the one-deep microcode JSR in
jt6805_ctrl.v.

  uc6805.py dis <6805.uc> [opcode ...]   readable dump (all, or just these)
  uc6805.py asm <src.ucs> <out.uc>       assemble the text form back
  uc6805.py rt  <6805.uc>                round-trip check: dis | asm == input

Field layout is jt6805.v's own (see 6805.vh's `assign` block); the symbolic
values are 6805_param.vh's.
"""
import sys

# name -> (lsb, width); everything not listed is a 1-bit flag
FIELDS = [
    ("brlatch",   0, 1), ("alu_sel",   1, 4), ("branch",    5, 1),
    ("brt_sel",   6, 2), ("carry_sel", 8, 2), ("cc_sel",   10, 4),
    ("ea_sel",   14, 2), ("halt",     16, 1), ("fetch",    17, 1),
    ("jsr_sel",  18, 5), ("ld_sel",   23, 3), ("ni",       26, 1),
    ("wr",       27, 1), ("op0inv",   28, 1), ("swi",      29, 1),
    ("stop",     30, 1), ("rmux_sel", 31, 4), ("opnd_sel", 35, 2),
    ("inc_pc",   37, 1), ("md_shift", 38, 1),
]
WIDTH = 39

ENUM = {
    "alu_sel":   ["-", "ADD", "AND", "BCLR", "BSET", "EOR", "LSL", "LSR", "OR", "SUB"],
    "brt_sel":   ["-", "CLR", "SET"],
    "carry_sel": ["-", "CIN", "MSB"],
    "cc_sel":    ["-", "C", "C0", "C1", "HNZC", "I0", "I1", "N0Z1", "NZ", "NZC", "NZC1"],
    "ea_sel":    ["-", "M", "S"],
    "jsr_sel":   ["-", "DIR", "DIRA", "EXT", "EXTA", "IDLE6", "IDX", "IDX16",
                  "IDX16A", "IDX8", "IDX8A", "IMM", "IVRD", "PSH16", "PSH8",
                  "RET", "RTI8"],
    "ld_sel":    ["-", "A", "CC", "EA", "MD", "PC", "S", "X"],
    "rmux_sel":  ["-", "A", "CC", "EA", "IV", "MD", "ONE", "PC", "S", "X", "ZERO"],
    "opnd_sel":  ["-", "LD0", "LD1"],
}
FLAGS = [n for n, _, w in FIELDS if w == 1]

# the ucode-procedure entry points, as 6805_param.vh names them
PROCS = {
    0x82: "IVRD", 0x90: "IMM", 0x91: "DIR", 0x87: "DIRA", 0x92: "EXT",
    0x84: "EXTA", 0x93: "IDX", 0x94: "IDX8", 0x85: "IDX8A", 0x95: "IDX16",
    0x96: "IDX16A", 0x3B: "PSH8", 0x4B: "PSH16", 0xAF: "IDLE6", 0x7B: "RTI8",
    0x9E: "ISRV",
}


def get(word, lsb, width):
    return (word >> lsb) & ((1 << width) - 1)


def put(word, lsb, width, val):
    assert 0 <= val < (1 << width), (lsb, width, val)
    return word | (val << lsb)


def decode(word):
    """39-bit word -> list of 'field' / 'field=VALUE' tokens, in field order."""
    out = []
    for name, lsb, width in FIELDS:
        v = get(word, lsb, width)
        if v == 0:
            continue
        if width == 1:
            out.append(name)
        else:
            names = ENUM[name]
            out.append("%s=%s" % (name, names[v] if v < len(names) else "?%d" % v))
    return out


def encode(tokens):
    word = 0
    byname = {n: (l, w) for n, l, w in FIELDS}
    for t in tokens:
        if "=" in t:
            name, val = t.split("=", 1)
            lsb, width = byname[name]
            word = put(word, lsb, width, ENUM[name].index(val))
        else:
            lsb, width = byname[t]
            assert width == 1, t
            word = put(word, lsb, width, 1)
    return word


def load_uc(path):
    rom = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        assert len(line) == WIDTH, (len(line), line)
        rom.append(int(line, 2))
    assert len(rom) == 4096, len(rom)
    return rom


def dump_uc(rom, path):
    with open(path, "w") as f:
        for w in rom:
            f.write(format(w, "039b") + "\n")


def disassemble(rom, only=None):
    lines = []
    for op in range(256):
        slot = rom[op * 16:(op + 1) * 16]
        if only is not None and op not in only:
            continue
        if all(w == 0 for w in slot):
            continue
        tag = PROCS.get(op)
        lines.append("op %02X%s" % (op, "   ; %s proc" % tag if tag else ""))
        last = max(i for i, w in enumerate(slot) if w != 0)
        for i, w in enumerate(slot[:last + 1]):
            lines.append("  %X: %s" % (i, " ".join(decode(w))))
    return lines


def assemble(lines):
    rom = [0] * 4096
    op = None
    for raw in lines:
        line = raw.split(";")[0].strip()
        if not line:
            continue
        if line.startswith("op "):
            op = int(line[3:5], 16)
            continue
        step, _, rest = line.partition(":")
        rom[op * 16 + int(step.strip(), 16)] = encode(rest.split())
    return rom


def main():
    cmd = sys.argv[1]
    if cmd == "dis":
        only = set(int(a, 16) for a in sys.argv[3:]) or None
        print("\n".join(disassemble(load_uc(sys.argv[2]), only)))
    elif cmd == "asm":
        dump_uc(assemble(open(sys.argv[2]).read().splitlines()), sys.argv[3])
    elif cmd == "rt":
        rom = load_uc(sys.argv[2])
        back = assemble(disassemble(rom))
        bad = [i for i in range(4096) if rom[i] != back[i]]
        print("round-trip: %d/4096 mismatched" % len(bad))
        for i in bad[:10]:
            print("  %03X op %02X step %X: %039b vs %039b" % (i, i >> 4, i & 15, rom[i], back[i]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
