#!/usr/bin/env python3
"""Build a $readmemh byte-array image of a graphics ROM region from a split
MAME romset zip.

Unlike tools/mkrom.py (which reconstructs a 16-bit-word 68000 program ROM),
graphics ROMs in this driver are addressed byte-wise by MAME's gfx_layout
decoders (gfx_8x8x4_packed_msb, gfx_8x8x4_col_2x2_group_packed_msb — see
docs/tier1-bjtwin.md), so this tool emits one byte per $readmemh line.

Three loading modes, matching the ROM_LOAD conventions this driver
actually uses for graphics regions:

  concat        One or more files, concatenated in the given order
                (MAME's ROM_LOAD at increasing offsets). Used for fgtile
                (1 file) and bgtile (2 files).
  interleave16  A ROM_LOAD16_BYTE pair: two same-size files, interleaved
                byte-by-byte, hi-file at even output offsets, lo-file at
                odd offsets. Used for sprites.
  word_swap     A single ROM_LOAD16_WORD_SWAP file (ROMX_LOAD with
                ROM_GROUPWORD | ROM_REVERSE, per mame/src/emu/romentry.h)
                — the dump is already one flat 16-bit-word-addressed
                image (unlike interleave16's two separate chip dumps),
                but each word's two bytes are stored reversed relative
                to what the gfx_layout decoder expects, so this mode
                swaps every adjacent byte pair (0<->1, 2<->3, ...) before
                emitting. Used for blkheart's own sprite ROM
                (90068-8.bin) — confirmed against the macro expansion
                directly, not assumed from the name alone.
  segments      A single file, sliced and reassembled at explicit
                region offsets (one --segments REGION:FILE:LEN triple
                per ROM_LOAD/ROM_CONTINUE line, in ROM_START order) —
                for regions MAME assembles out of physical order via
                ROM_CONTINUE (a single chip's own contents split across
                non-sequential region offsets — its own comment in
                nmk16.cpp literally says "this is a mess"). Used for
                strahl's own OKI sample ROMs, where the reference's own
                bank arithmetic expects a *scrambled* physical layout.
                Output region size is the highest REGION+LEN found.

Split romsets store files shared with a parent set only in the parent's
zip, often under a completely different filename (MAME matches by CRC,
not name, when merging) — confirmed directly for cactus/sabotenb during
Tier 1 ROM auditing (docs/rom-audit.md). Pass --zip multiple times (parent
first or last, order doesn't matter) to search across zips the same way
MAME's -rompath does; each requested filename is looked up by trying
every provided zip in turn.

Usage:
    tools/mkgfxrom.py --zip mame_roms/cactus.zip --zip mame_roms/sabotenb.zip \
        --mode concat --files i03.bin --out sim/rtl/bjtwin/roms/cactus_fgtile.hex

    tools/mkgfxrom.py --zip mame_roms/cactus.zip --mode concat \
        --files s-05.bin s-06.bin --out sim/rtl/bjtwin/roms/cactus_bgtile.hex

    tools/mkgfxrom.py --zip mame_roms/cactus.zip --mode interleave16 \
        --hi s-04.bin --lo s-03.bin --out sim/rtl/bjtwin/roms/cactus_sprites.hex

    tools/mkgfxrom.py --zip mame_roms/blkheart.zip --mode word_swap \
        --files 90068-8.bin --out sim/rtl/blkheart/roms/blkheart_sprites.hex

    tools/mkgfxrom.py --zip mame_roms/strahl.zip --mode segments \
        --files str8pmw1.540 \
        --segments 0x00000:0x00000:0x20000 --segments 0x60000:0x20000:0x20000 \
        --segments 0x40000:0x40000:0x20000 --segments 0x20000:0x60000:0x20000 \
        --out sim/rtl/strahl/roms/strahl_oki1.hex

--hi/--lo order matches ROM_LOAD16_BYTE's own offset argument (the file
loaded at byte offset 0 is --hi/even, the one at offset 1 is --lo/odd) —
always check the actual ROM_START in mame/src/mame/nmk/nmk16.cpp rather
than assuming.
"""

import argparse
import zipfile


def read_from_any(zips, filename):
    for z in zips:
        try:
            return z.read(filename)
        except KeyError:
            continue
    zip_names = ", ".join(z.filename for z in zips)
    raise SystemExit(f"error: {filename!r} not found in any of: {zip_names}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", required=True, action="append", help="path to a romset zip; repeat to search a parent zip too")
    ap.add_argument("--mode", required=True, choices=["concat", "interleave16", "word_swap", "segments"])
    ap.add_argument("--files", nargs="+", help="concat mode: files in ROM_LOAD order; word_swap/segments mode: single file")
    ap.add_argument("--hi", help="interleave16 mode: file at even byte offsets")
    ap.add_argument("--lo", help="interleave16 mode: file at odd byte offsets")
    ap.add_argument("--segments", action="append",
                     help="segments mode: one REGION_OFFSET:FILE_OFFSET:LENGTH triple per ROM_LOAD/ROM_CONTINUE "
                          "line (hex or decimal ints), repeat in ROM_START order")
    ap.add_argument("--out", required=True, help="output $readmemh hex file, one byte per line")
    args = ap.parse_args()

    zips = [zipfile.ZipFile(p) for p in args.zip]
    try:
        if args.mode == "concat":
            if not args.files:
                raise SystemExit("error: --files required for concat mode")
            data = b"".join(read_from_any(zips, f) for f in args.files)
        elif args.mode == "word_swap":
            if not args.files or len(args.files) != 1:
                raise SystemExit("error: --files (exactly one) required for word_swap mode")
            raw = read_from_any(zips, args.files[0])
            if len(raw) % 2 != 0:
                raise SystemExit(f"error: {args.files[0]} is {len(raw)} bytes — must be even for word_swap")
            data = bytearray(raw)
            data[0::2], data[1::2] = raw[1::2], raw[0::2]
            data = bytes(data)
        elif args.mode == "segments":
            if not args.files or len(args.files) != 1:
                raise SystemExit("error: --files (exactly one) required for segments mode")
            if not args.segments:
                raise SystemExit("error: --segments (one or more REGION:FILE:LEN triples) required for segments mode")
            raw = read_from_any(zips, args.files[0])
            triples = []
            for s in args.segments:
                parts = s.split(":")
                if len(parts) != 3:
                    raise SystemExit(f"error: --segments {s!r} must be REGION_OFFSET:FILE_OFFSET:LENGTH")
                region_off, file_off, length = (int(p, 0) for p in parts)
                triples.append((region_off, file_off, length))
            region_size = max(r + l for r, f, l in triples)
            data = bytearray(region_size)
            for region_off, file_off, length in triples:
                if file_off + length > len(raw):
                    raise SystemExit(f"error: segment file_off={file_off:#x} len={length:#x} exceeds "
                                      f"{args.files[0]}'s own {len(raw):#x} bytes")
                data[region_off:region_off + length] = raw[file_off:file_off + length]
            data = bytes(data)
        else:
            if not args.hi or not args.lo:
                raise SystemExit("error: --hi and --lo required for interleave16 mode")
            hi = read_from_any(zips, args.hi)
            lo = read_from_any(zips, args.lo)
            if len(hi) != len(lo):
                raise SystemExit(f"error: {args.hi} is {len(hi)} bytes but {args.lo} is {len(lo)} bytes — must match")
            data = bytearray(len(hi) * 2)
            data[0::2] = hi
            data[1::2] = lo
            data = bytes(data)
    finally:
        for z in zips:
            z.close()

    with open(args.out, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")

    print(f"wrote {len(data)} bytes to {args.out}")


if __name__ == "__main__":
    main()
