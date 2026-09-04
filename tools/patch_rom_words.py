#!/usr/bin/env python3
"""Apply fixed word-offset patches to a $readmemh hex file (one 16-bit word
per line).

Used for MAME-author "protection cracked/patched out" ROM fixups that are
plain static word pokes rather than a bit-permutation (see
tools/decode_tdragonb.py for that case) — e.g. acrobatmbl's own
init_acrobatmbl() (mame/src/mame/nmk/nmk16.cpp:6238-6262), which patches 4
words in the maincpu ROM to skip two jumps into an undumped PIC's own
protected RAM region, rather than emulating the PIC itself (which MAME
doesn't either — the machine config declares it .set_disable()'d).

Usage:
    tools/patch_rom_words.py --in roms/acrobatmbl_maincpu.hex --out roms/acrobatmbl_maincpu.hex \
        --patch 0x364:0x0000 --patch 0x365:0x2d84 --patch 0x36a:0x0000 --patch 0x36b:0x3510

Patch offsets are WORD indices into the hex file (byte_offset/2), matching
the reference's own `u16 *rom` array indexing — always double-check against
the actual source rather than assuming.

(--in and --out may be the same path — the whole file is read before any
write happens.)
"""

import argparse


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="infile", required=True)
    ap.add_argument("--out", dest="outfile", required=True)
    ap.add_argument("--patch", action="append", required=True,
                     help="WORD_INDEX:VALUE (hex or decimal), repeatable")
    args = ap.parse_args()

    with open(args.infile) as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    for p in args.patch:
        idx_s, val_s = p.split(":")
        idx = int(idx_s, 0)
        val = int(val_s, 0)
        if idx >= len(values):
            raise SystemExit(f"error: patch index {idx:#x} out of range (file has {len(values):#x} words)")
        values[idx] = val

    with open(args.outfile, "w") as f:
        for v in values:
            f.write(f"{v:04x}\n")

    print(f"patched {len(args.patch)} word(s) in {args.outfile}")


if __name__ == "__main__":
    main()
