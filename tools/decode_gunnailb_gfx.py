#!/usr/bin/env python3
"""Apply gunnailb's static bit-permutation GFX ROM decode to a $readmemh hex
file (one byte per line).

`gunnailb` (GunNail bootleg) applies a fixed, one-time bit-permutation to its
bgtile/sprites ROM data at MAME init time — decode_gfx()/decode_byte()/
decode_word()/bjtwin_address_map_bg0()/bjtwin_address_map_sprites(),
mame/src/mame/nmk/nmk16.cpp:6005-6054 (decode_gfx itself) and :5974-6002 (the
shared decode_byte/decode_word/bjtwin_address_map_* helpers — the SAME
decode_byte/decode_word formula tools/decode_tdragonb.py already uses).

This is a genuinely different mechanism from this project's already-built
rtl/nmk214/nmk214.sv: nmk214 is a LIVE, protection-MCU-configured per-fetch
descrambler used by the real (unmodified) hardware in other games; decode_gfx()
is a completely separate, self-contained, purely-software, one-time transform
gunnailb's own init function calls directly (init_gunnailb() = decode_gfx() +
init_banked_audiocpu(), nmk16.cpp:6275-6279) — no live circuit exists on the
bootleg board for this, just fixed post-permuted-at-emulator-init ROM
content, exactly like tdragonb's own decode_tdragonb() case. Both mechanisms
happen to share the same *conceptual family* of scrambling (8 candidate
permutation tables, 3 address bits select which one applies per byte/word)
but use different, independent table sets and address-bit selections here.

Two independent transforms, selected via --mode:

  bg       Per BYTE. Table selected by bjtwin_address_map_bg0(byte_addr) =
           bit2 | bit11<<1 | bit18<<2 (nmk16.cpp:5983-5985), applied via
           decode_byte (8-bit bit-permutation, nmk16.cpp:5974-5979).
           Used for bgtile.

  sprites  Per 16-bit WORD, but the ROM is byte-addressed and each word is
           stored as two consecutive bytes in LITTLE-ENDIAN order (rom[A]=lo,
           rom[A+1]=hi) despite the ROM itself being loaded via
           ROM_LOAD16_WORD_SWAP (run tools/mkgfxrom.py --mode word_swap
           FIRST — this tool only permutes bits within an already correctly
           assembled hex file, same "run after the assembly tool" contract
           tools/decode_tdragonb.py already documents). Table selected by
           bjtwin_address_map_sprites(byte_addr_of_the_low_byte) = bit4 |
           bit17<<1 | bit20<<2 (nmk16.cpp:5999-6001), applied via decode_word
           (16-bit bit-permutation, nmk16.cpp:5989-5996) to the little-endian
           word, then written back in the same byte order. Used for sprites.

Usage:
    tools/decode_gunnailb_gfx.py --mode bg      --in roms/gunnailb_bgtile.hex  --out roms/gunnailb_bgtile.hex
    tools/decode_gunnailb_gfx.py --mode sprites --in roms/gunnailb_sprites.hex --out roms/gunnailb_sprites.hex

(--in and --out may be the same path — the whole file is read before any
write happens.)
"""

import argparse

# decode_byte(src,bitp): ret = sum over i in 0..7  of (((src>>bitp[i])&1) << (7-i))
# decode_word(src,bitp): ret = sum over i in 0..15 of (((src>>bitp[i])&1) << (15-i))
# (nmk16.cpp:5974-5996 — identical formula to tools/decode_tdragonb.py's own `decode()`.)


def decode(src, bitp, nbits):
    ret = 0
    for i in range(nbits):
        ret |= ((src >> bitp[i]) & 1) << (nbits - 1 - i)
    return ret


# bjtwin_address_map_bg0(addr) (nmk16.cpp:5983-5985):
#   ((addr & 0x00004) >> 2) | ((addr & 0x00800) >> 10) | ((addr & 0x40000) >> 16)
def bjtwin_address_map_bg0(addr):
    return ((addr & 0x00004) >> 2) | ((addr & 0x00800) >> 10) | ((addr & 0x40000) >> 16)


# bjtwin_address_map_sprites(addr) (nmk16.cpp:5999-6001):
#   ((addr & 0x00010) >> 4) | ((addr & 0x20000) >> 16) | ((addr & 0x100000) >> 18)
def bjtwin_address_map_sprites(addr):
    return ((addr & 0x00010) >> 4) | ((addr & 0x20000) >> 16) | ((addr & 0x100000) >> 18)


# decode_data_bg[8][8] (nmk16.cpp:6011-6021).
DECODE_DATA_BG = [
    [0x3, 0x0, 0x7, 0x2, 0x5, 0x1, 0x4, 0x6],
    [0x1, 0x2, 0x6, 0x5, 0x4, 0x0, 0x3, 0x7],
    [0x7, 0x6, 0x5, 0x4, 0x3, 0x2, 0x1, 0x0],
    [0x7, 0x6, 0x5, 0x0, 0x1, 0x4, 0x3, 0x2],
    [0x2, 0x0, 0x1, 0x4, 0x3, 0x5, 0x7, 0x6],
    [0x5, 0x3, 0x7, 0x0, 0x4, 0x6, 0x2, 0x1],
    [0x2, 0x7, 0x0, 0x6, 0x5, 0x3, 0x1, 0x4],
    [0x3, 0x4, 0x7, 0x6, 0x2, 0x0, 0x5, 0x1],
]

# decode_data_sprite[8][16] (nmk16.cpp:6023-6034).
DECODE_DATA_SPRITE = [
    [0x9, 0x3, 0x4, 0x5, 0x7, 0x1, 0xb, 0x8, 0x0, 0xd, 0x2, 0xc, 0xe, 0x6, 0xf, 0xa],
    [0x1, 0x3, 0xc, 0x4, 0x0, 0xf, 0xb, 0xa, 0x8, 0x5, 0xe, 0x6, 0xd, 0x2, 0x7, 0x9],
    [0xf, 0xe, 0xd, 0xc, 0xb, 0xa, 0x9, 0x8, 0x7, 0x6, 0x5, 0x4, 0x3, 0x2, 0x1, 0x0],
    [0xf, 0xe, 0xc, 0x6, 0xa, 0xb, 0x7, 0x8, 0x9, 0x2, 0x3, 0x4, 0x5, 0xd, 0x1, 0x0],
    [0x1, 0x6, 0x2, 0x5, 0xf, 0x7, 0xb, 0x9, 0xa, 0x3, 0xd, 0xe, 0xc, 0x4, 0x0, 0x8],
    [0x7, 0x5, 0xd, 0xe, 0xb, 0xa, 0x0, 0x1, 0x9, 0x6, 0xc, 0x2, 0x3, 0x4, 0x8, 0xf],
    [0x0, 0x5, 0x6, 0x3, 0x9, 0xb, 0xa, 0x7, 0x1, 0xd, 0x2, 0xe, 0x4, 0xc, 0x8, 0xf],
    [0x9, 0xc, 0x4, 0x2, 0xf, 0x0, 0xb, 0x8, 0xa, 0xd, 0x3, 0x6, 0x5, 0xe, 0x1, 0x7],
]


def _self_check():
    """Every table must be a bijection on its own index range (a genuine bit
    permutation, not a lossy remap) — verified once at import/run time before
    trusting any table on real ROM data."""
    for i, t in enumerate(DECODE_DATA_BG):
        assert sorted(t) == list(range(8)), f"decode_data_bg[{i}] is not a bijection: {t}"
    for i, t in enumerate(DECODE_DATA_SPRITE):
        assert sorted(t) == list(range(16)), f"decode_data_sprite[{i}] is not a bijection: {t}"
    # decode_byte/decode_word: output bit (n-1-i) = input bit bitp[i]. table 2
    # in both arrays is {n-1,...,1,0} (bitp[i]=n-1-i), which is the IDENTITY
    # permutation (output bit (n-1-i) = input bit (n-1-i), i.e. output bit
    # k = input bit k for every k) — verified directly, not assumed.
    for v in (0x00, 0x01, 0x55, 0xA5, 0xFF):
        assert decode(v, DECODE_DATA_BG[2], 8) == v, f"table bg[2] should be identity, got {decode(v, DECODE_DATA_BG[2], 8):#x} for {v:#x}"
    for v in (0x0000, 0x0001, 0x5555, 0xFFFF):
        assert decode(v, DECODE_DATA_SPRITE[2], 16) == v, f"table sprite[2] should be identity, got {decode(v, DECODE_DATA_SPRITE[2], 16):#x} for {v:#x}"
    # Hand-traced single-bit-position example on a genuine (non-identity)
    # table: decode_data_bg[0] = {3,0,7,2,5,1,4,6} -> bitp[0]=3, so input
    # bit 3 lands at output bit (7-0)=7, and (from bitp[2]=7) input bit 7
    # lands at output bit (7-2)=5.
    assert decode(0b00001000, DECODE_DATA_BG[0], 8) == 0b10000000  # bit3 -> bit7
    assert decode(0b10000000, DECODE_DATA_BG[0], 8) == 0b00100000  # bit7 -> bit5
    # decode_data_sprite[0] = {9,3,4,5,7,1,11,8,0,13,2,12,14,6,15,10} ->
    # bitp[0]=9, so input bit 9 lands at output bit (15-0)=15.
    assert decode(0x0200, DECODE_DATA_SPRITE[0], 16) == 0x8000  # bit9 -> bit15


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", required=True, choices=["bg", "sprites"])
    ap.add_argument("--in", dest="infile", required=True)
    ap.add_argument("--out", dest="outfile", required=True)
    args = ap.parse_args()

    _self_check()

    with open(args.infile) as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    if args.mode == "bg":
        out = [decode(v, DECODE_DATA_BG[bjtwin_address_map_bg0(a)], 8) for a, v in enumerate(values)]
    else:
        if len(values) % 2 != 0:
            raise SystemExit(f"error: sprites mode needs an even number of bytes, got {len(values)}")
        out = [0] * len(values)
        for a in range(0, len(values), 2):
            lo, hi = values[a], values[a + 1]
            word = hi * 256 + lo
            tmp = decode(word, DECODE_DATA_SPRITE[bjtwin_address_map_sprites(a)], 16)
            out[a] = tmp & 0xFF
            out[a + 1] = tmp >> 8

    with open(args.outfile, "w") as f:
        for v in out:
            f.write(f"{v:02x}\n")

    print(f"decoded {len(out)} bytes, mode={args.mode} ({args.infile} -> {args.outfile})")


if __name__ == "__main__":
    main()
