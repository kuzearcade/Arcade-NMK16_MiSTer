#!/usr/bin/env python3
"""Build a $readmemh-compatible ROM image from a split MAME romset zip.

NMK16-family 68000 program ROMs are near-universally two same-size chips
loaded with MAME's ROM_LOAD16_BYTE convention (one chip = high byte of each
16-bit word at even offsets, the other = low byte at odd offsets — 68000 is
big-endian). This tool reconstructs the flat word-addressed ROM image
Verilator testbenches load via $readmemh, straight from the same .zip a
real MiSTer .mra would reference.

Usage:
    tools/mkrom.py --zip mame_roms/cactus.zip --hi 02.bin --lo 01.bin \
        --out sim/rtl/bjtwin/roms/cactus_maincpu.hex

--hi/--lo order matches the order MAME's ROM_START lists them in (first
ROM_LOAD16_BYTE entry = high byte, second = low byte) — always double-check
against the actual ROM_START in mame/src/mame/nmk/nmk16.cpp rather than
assuming file-name order, since it is not consistent across games.
"""

import argparse
import zipfile


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", required=True, help="path to the romset zip")
    ap.add_argument("--hi", required=True, help="chip file supplying the high byte of each word")
    ap.add_argument("--lo", required=True, help="chip file supplying the low byte of each word")
    ap.add_argument("--out", required=True, help="output $readmemh hex file, one 16-bit word per line")
    args = ap.parse_args()

    with zipfile.ZipFile(args.zip) as z:
        hi = z.read(args.hi)
        lo = z.read(args.lo)

    if len(hi) != len(lo):
        raise SystemExit(f"error: {args.hi} is {len(hi)} bytes but {args.lo} is {len(lo)} bytes — must match")

    with open(args.out, "w") as f:
        for i in range(len(hi)):
            word = (hi[i] << 8) | lo[i]
            f.write(f"{word:04x}\n")

    print(f"wrote {len(hi)} words ({len(hi) * 2} bytes) to {args.out}")


if __name__ == "__main__":
    main()
