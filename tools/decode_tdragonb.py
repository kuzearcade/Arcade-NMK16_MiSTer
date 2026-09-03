#!/usr/bin/env python3
"""Apply tdragonb's static bit-permutation ROM decode to a $readmemh hex file.

`tdragonb` (Thunder Dragon bootleg with Raiden sounds, encrypted) applies a
fixed, one-time bit-permutation to its maincpu/bgtile/sprites ROM data at
MAME init time — decode_tdragonb()/decode_byte()/decode_word(),
mame/src/mame/nmk/nmk16.cpp:5974-6125. It is NOT a live hardware descrambler
(unlike e.g. nmk214) — real hardware presumably has the inverse permutation
wired into its address/data lines, but functionally the decoded ROM content
is fixed and can be produced once, offline, exactly like this project's
existing tools/mkrom.py and tools/mkgfxrom.py already do for interleaving.

Run AFTER tools/mkrom.py (word mode, maincpu) or tools/mkgfxrom.py (byte
mode, bgtile/sprites) — this script only permutes bits within each already
correctly-assembled hex line, it does not do any file reading/interleaving
itself.

Usage:
    tools/decode_tdragonb.py --mode word --in roms/tdragonb_maincpu.hex --out roms/tdragonb_maincpu.hex
    tools/decode_tdragonb.py --mode byte --in roms/tdragonb_bgtile.hex   --out roms/tdragonb_bgtile.hex

(--in and --out may be the same path — the whole file is read before any
write happens.)
"""

import argparse

# decode_word's own table (nmk16.cpp:6091-6094) — 16-bit words, maincpu only.
WORD_BITP = [0xe, 0xc, 0xa, 0x8, 0x7, 0x5, 0x3, 0x1, 0xf, 0xd, 0xb, 0x9, 0x6, 0x4, 0x2, 0x0]
# decode_byte's own table (nmk16.cpp:6097-6100) — bytes, bgtile/sprites.
BYTE_BITP = [0x7, 0x6, 0x5, 0x3, 0x4, 0x2, 0x1, 0x0]


def decode(src, bitp, nbits):
    ret = 0
    for i in range(nbits):
        ret |= ((src >> bitp[i]) & 1) << (nbits - 1 - i)
    return ret


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", required=True, choices=["word", "byte"])
    ap.add_argument("--in", dest="infile", required=True)
    ap.add_argument("--out", dest="outfile", required=True)
    args = ap.parse_args()

    with open(args.infile) as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    if args.mode == "word":
        decoded = [decode(v, WORD_BITP, 16) for v in values]
        width = 4
    else:
        decoded = [decode(v, BYTE_BITP, 8) for v in values]
        width = 2

    with open(args.outfile, "w") as f:
        for v in decoded:
            f.write(f"{v:0{width}x}\n")

    print(f"decoded {len(decoded)} {args.mode}s ({args.infile} -> {args.outfile})")


if __name__ == "__main__":
    main()
