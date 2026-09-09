#!/usr/bin/env python3
"""Build the raw ioctl_download byte stream for a game's hardware-mode
testbench (and, eventually, its real .mra <rom index="0"> download).

Unlike tools/mkrom.py/mkgfxrom.py/mkrom_wordswap.py (which pre-transform
ROM bytes into a $readmemh format for simulation-only 0-latency arrays),
this tool does NO byte reordering at all — it just concatenates each
region's raw, as-dumped zip member bytes at the fixed absolute offset
docs/hw-bringup.md's per-game table assigns it. The core's own SDRAM
download-write logic (see e.g. rtl/tdragon2/tdragon2_core.sv's g_rom_hw
block) reconstructs 16-bit words from this raw byte stream by parity
(even ioctl_addr -> low byte, odd -> high byte), which happens to
reproduce ROM_LOAD16_WORD_SWAP's own byte order automatically (verified
directly: word = (byte[2n+1]<<8)|byte[2n], the same formula
mkrom_wordswap.py itself uses) — so a region needing that transform on
the sim side needs no special-casing here at all, just a fixed-offset
raw copy.

Usage:
    tools/mk_ioctl_stream.py --zip mame_roms/tdragon2.zip \
        --region 0x000000:6.rom \
        --region 0x080000:5.bin \
        --region 0x0A0000:1.bin \
        --region 0x0C0000:ww930914.2 \
        --region 0x2C0000:ww930917.7,ww930918.8 \
        --region 0x6C0000:ww930916.4 \
        --region 0x8C0000:ww930915.3 \
        --out sim/rtl/tdragon2/roms/tdragon2_ioctl.bin
"""

import argparse
import zipfile


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", required=True, action="append", help="path to a romset zip (repeat for a split clone set: each file is read from the first zip that has it)")
    ap.add_argument("--region", required=True, action="append",
                     help="OFFSET:file[,file...] — repeat per region; multiple comma-separated files concatenate in order (matching a multi-ROM_LOAD region)")
    ap.add_argument("--out", required=True, help="output raw binary file")
    args = ap.parse_args()

    regions = []
    for r in args.region:
        offset_str, files_str = r.split(":", 1)
        offset = int(offset_str, 0)
        files = files_str.split(",")
        regions.append((offset, files))
    regions.sort()

    zips = [zipfile.ZipFile(zp) for zp in args.zip]

    def read_member(fn):
        for z in zips:
            if fn in z.namelist():
                return z.read(fn)
        raise SystemExit(f"error: {fn} not found in any of {args.zip}")

    buf = bytearray()
    for offset, files in regions:
        if offset < len(buf):
            raise SystemExit(f"error: region at 0x{offset:x} overlaps previous data (buffer already {len(buf)} bytes)")
        buf.extend(b"\x00" * (offset - len(buf)))
        for fn in files:
            buf.extend(read_member(fn))

    with open(args.out, "wb") as f:
        f.write(buf)

    print(f"wrote {len(buf)} bytes ({len(regions)} regions) to {args.out}")


if __name__ == "__main__":
    main()
