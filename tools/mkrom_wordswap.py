#!/usr/bin/env python3
"""Build a $readmemh-compatible ROM image from one or more
ROM_LOAD16_WORD_SWAP MAME program ROM files (unlike tools/mkrom.py, which
handles the near-universal two-chip ROM_LOAD16_BYTE case).

macross2's own maincpu ROM (mcrs2j.3, ROM_LOAD16_WORD_SWAP, nmk16.cpp:8242)
is a single flat file whose adjacent byte pairs are stored in the opposite
order a big-endian 68000 word-addressed decoder needs — the same byte-pair
reversal tools/mkgfxrom.py's own `word_swap` mode already documents/applies
for graphics ROMs, but this tool emits mkrom.py's own word-per-line
$readmemh format (one 16-bit value per line) instead of mkgfxrom.py's
byte-per-line format, since a 68000 program ROM is consumed as a 16-bit-wide
array, not a byte array.

powerins' own maincpu is TWO ROM_LOAD16_WORD_SWAP files at consecutive
offsets (93095-3a.u108 @0x00000, 93095-4.u109 @0x80000, nmk16.cpp:8994-8998)
— pass --file multiple times, in ROM_START's own listed order, and each
file's word-swapped output is concatenated in that order.

Usage:
    tools/mkrom_wordswap.py --zip mame_roms/macross2.zip --file mcrs2j.3 \
        --out sim/rtl/macross2/roms/macross2_maincpu.hex

    tools/mkrom_wordswap.py --zip mame_roms/powerins.zip \
        --file 93095-3a.u108 --file 93095-4.u109 \
        --out sim/rtl/powerins/roms/powerins_maincpu.hex
"""

import argparse
import zipfile


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", required=True, help="path to the romset zip")
    ap.add_argument("--file", required=True, action="append",
                     help="a ROM_LOAD16_WORD_SWAP file; repeat in ROM_START's own listed order for multi-file regions")
    ap.add_argument("--out", required=True, help="output $readmemh hex file, one 16-bit word per line")
    args = ap.parse_args()

    with zipfile.ZipFile(args.zip) as z:
        chunks = [z.read(fn) for fn in args.file]

    total_words = 0
    with open(args.out, "w") as f:
        for fn, data in zip(args.file, chunks):
            if len(data) % 2 != 0:
                raise SystemExit(f"error: {fn} is {len(data)} bytes — must be an even length")
            for i in range(0, len(data), 2):
                # byte pair stored [lo,hi] in the dump; swap to [hi,lo] (word = hi<<8|lo... )
                # ROM_LOAD16_WORD_SWAP reverses each word's own two bytes relative
                # to a plain big-endian word read, so word = (data[i] << 8) | data[i+1]
                # AFTER swapping means: raw dump byte i is the LOW byte, i+1 is HIGH.
                word = (data[i + 1] << 8) | data[i]
                f.write(f"{word:04x}\n")
            total_words += len(data) // 2

    total_bytes = sum(len(d) for d in chunks)
    print(f"wrote {total_words} words ({total_bytes} bytes) from {len(args.file)} file(s) to {args.out}")


if __name__ == "__main__":
    main()
