#!/usr/bin/env python3
"""Generate every "Gunnail" rbf .mra file: GunNail (gunnail, gunnailp) and,
since 2026-09-11, the nine lowres NMK004 boards the same rbf runs as
runtime game modes (rtl/gunnail/gunnail_core.sv's game table), with
their straightforward clones. Everything below is transcribed from
mame/src/mame/nmk/nmk16.cpp: GAME() lines, ROM_START blocks and
INPUT_PORTS_START DIP tables. Run from the repo root:
    python3 tools/gen_gunnail_mra.py

Conventions (see docs/hw-bringup.md):
  - The <switches> block is DSW1, DSW2, then the GAME ID byte (game_sel):
    0 gunnail, 1 macross, 2 blkheart, 3 mustang, 4 bioship, 5 vandyke,
    6 acrobatm, 7 strahl, 8 tdragon, 9 hachamf, 10 tdragon1, 11 hachamfp,
    12 mustangs, 13 hachamfb, 14 bjtwin, 15 bjtwinp, 16 bjtwinpa,
    17 sabotenb/nouryoku, 18 cactus, 19 nouryokup, 20 tharrier, 21 vandykeb,
    22 mustangb3.
    ids are listed in bit-value order (value 0 first).
  - ROM part order = the core's per-game SDRAM layout (BASE_BYTE_* in
    gunnail_core.sv): maincpu, NMK004 program, NMK004 boot ROM
    (nmk004.zip), [protection MCU ROM], fgtile, bgtile, [bg2tile],
    [tilerom], sprites, oki1, oki2 — contiguous, each exactly its
    ROM_START file total.
  - A ROM_LOAD16_BYTE pair is an <interleave output="16"> with the
    ODD-offset chip on even stream addresses (map="01") and the even
    chip on odd (map="10"): the core rebuilds words by byte parity and
    reads sprite bytes with address bit 0 inverted, so this reproduces
    both the 68000's word order and the sprite/tilerom byte order
    (verified on hardware for GunNail's maincpu and Power Instinct's
    prototype sprites).
  - Every file carries the five-entry <buttons> list matching the rbf's
    CONF_STR "J1,Button 1,Button 2,Button 3,Start,Coin" (positional
    gamepad mapping — a shorter list shifts Start/Coin).
"""
import os

RELEASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "releases")

BUTTONS = ("Button 1,Button 2,Button 3,Start,Coin", "Y,B,A,Start,R")

# Shared coin tables (ids in bit-value order).
COIN16_B = "5C_3C,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"
COIN16_A = "Free_Play,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"
COIN8_FREE = "Free_Play,1C_4C,3C_1C,1C_2C,4C_1C,1C_3C,2C_1C,1C_1C"
COIN8_5C = "5C_1C,1C_4C,3C_1C,1C_2C,4C_1C,1C_3C,2C_1C,1C_1C"
COIN8_TD1 = "Free_Play,4C_1C,1C_3C,2C_1C,1C_4C,3C_1C,1C_2C,1C_1C"       # tdragon_prot (tdragon1)
COIN8_STRAHL = "5C_1C,4C_1C,3C_1C,2C_1C,1C_4C,1C_3C,1C_2C,1C_1C"

# Part helpers: ("name", "crc") for a plain file; ("pair", even, odd) for a
# ROM_LOAD16_BYTE pair (each (name, crc)); ("slice", name, crc, offset, length)
# for a ROM_CONTINUE chunk; ("fill", nbytes) for a zero pad.
def pair(even, odd):
    return ("pair", even, odd)

NMK004_BOOT = ("nmk004.bin", "8ae61a09")

# Per-parent hardware/DIP description. "regions" lists (comment, [parts]).
GUNNAIL = dict(
    id=0, year=1993, manufacturer="NMK / Tecmo", rot=True, switches="FD,FF",
    dips=[
        ('0', "Flip Screen", "On,Off"), ('1', "Language", "English,Japanese"),
        ('2,3', "Difficulty", "Hardest,Hard,Easy,Normal"),
        ('4', "Unused (SW1:4)", "On,Off"), ('5', "Unused (SW1:3)", "On,Off"),
        ('6', "Unused (SW1:2)", "On,Off"), ('7', "Unused (SW1:1)", "On,Off"),
        ('8', "Unused (SW2:8)", "On,Off"), ('9', "Demo Sounds", "Off,On"),
        ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
    ],
    regions=[
        ("maincpu, 0x080000", [pair(("3e.u131", "61d985b2"), ("3o.u133", "f114e89c"))]),
        ("NMK004 external program, 0x010000", [("92077_2.u101", "cd4e55f8")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("NMK-215 protection MCU ROM, 0x002000 (read into the MCU from SDRAM after reset)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x020000", [("1.u21", "3d00a9f4")]),
        ("bgtile, 0x100000 (NMK214-scrambled, decoded per fetch)", [("92077-4.u19", "a9ea2804")]),
        ("sprites, 0x200000 (ROM_LOAD16_WORD_SWAP, NMK214-scrambled)", [("92077-7.u134", "d49169b3")]),
        ("oki1, 0x080000", [("92077-5.u56", "feb83c73")]),
        ("oki2, 0x080000", [("92077-6.u57", "6d133f0d")]),
    ],
)

MACROSS = dict(
    id=1, year=1992, manufacturer="Banpresto", rot=True, switches="F7,FF",
    dips=[
        ('0', "Service Mode", "On,Off"), ('1', "Demo Sounds", "Off,On"), ('2', "Flip Screen", "On,Off"),
        ('3', "Language", "English,Japanese"), ('4,5', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('6,7', "Lives", "1,2,4,3"),
        ('8,11', "Coin B", COIN16_B), ('12,15', "Coin A", COIN16_A),
    ],
    regions=[
        ("maincpu, 0x080000 (ROM_LOAD16_WORD_SWAP)", [("921a03", "33318d55")]),
        ("NMK004 external program, 0x010000", [("921a02", "77c082c7")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("NMK-215 protection MCU ROM, 0x002000 (byte-identical to gunnail's)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x020000", [("921a01", "bbd8242d")]),
        ("bgtile, 0x200000 (NMK214-scrambled, decoded per fetch)", [("921a04", "4002e4bb")]),
        ("sprites, 0x200000 (ROM_LOAD16_WORD_SWAP, NMK214-scrambled)", [("921a07", "7d2bf112")]),
        ("oki1, 0x080000", [("921a05", "d5a1eddd")]),
        ("oki2, 0x080000", [("921a06", "89461d0f")]),
    ],
)

BLKHEART = dict(
    id=2, year=1991, manufacturer="UPL", rot=False, switches="FF,FF",
    dips=[
        ('0', "Flip Screen", "On,Off"), ('1', "Service Mode", "On,Off"),
        ('2,3', "Difficulty", "Hardest,Hard,Normal,Easy"),
        ('4', "Unknown (SW1:4)", "On,Off"), ('5', "Unknown (SW1:3)", "On,Off"),
        ('6,7', "Lives", "5,2,4,3"),
        ('8', "Unknown (SW2:8)", "On,Off"), ('9', "Demo Sounds", "Off,On"),
        ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("blkhrt.7", "5bd248c0"), ("blkhrt.6", "6449e50d"))]),
        ("NMK004 external program, 0x010000", [("4.bin", "7cefa295")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x020000", [("3.bin", "a1ab3a16")]),
        ("bgtile, 0x100000", [("90068-5.bin", "a1ab4f24")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP)", [("90068-8.bin", "9d3204b2")]),
        ("oki1, 0x080000", [("90068-2.bin", "3a583184")]),
        ("oki2, 0x080000", [("90068-1.bin", "e7af69d2")]),
    ],
)

MUSTANG = dict(
    id=3, year=1990, manufacturer="UPL", rot=False, switches="FF,FF",
    # One 16-bit DSW port: SW2 in the low byte (switch byte 0), SW1 in the high byte (byte 1).
    dips=[
        ('0', "Unknown (SW2:8)", "On,Off"), ('1', "Demo Sounds", "Off,On"),
        ('2,4', "Coin B", COIN8_FREE), ('5,7', "Coin A", COIN8_FREE),
        ('8', "Flip Screen", "On,Off"), ('9', "Unknown (SW1:7)", "On,Off"),
        ('10,11', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('12', "Unknown (SW1:4)", "On,Off"), ('13', "Unknown (SW1:3)", "On,Off"),
        ('14,15', "Lives", "5,2,4,3"),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("2.bin", "bd9f7c89"), ("3.bin", "0eec36a5"))]),
        ("NMK004 external program, 0x010000", [("90058-7", "920a93c8")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x020000", [("90058-1", "81ccfcad")]),
        ("bgtile, 0x080000", [("90058-4", "a07a2002")]),
        ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("90058-8", "560bff04"), ("90058-9", "b9d72a03"))]),
        ("oki1, 0x080000", [("90058-5", "c60c883e")]),
        ("oki2, 0x080000", [("90058-6", "233c1776")]),
    ],
)

BIOSHIP = dict(
    id=4, year=1990, manufacturer="UPL (American Sammy license)", rot=False, switches="FF,FF",
    dips=[
        ('0', "Flip Screen", "On,Off"), ('1,2', "Difficulty", "Easy,Hard,Hardest,Normal"),
        ('3', "Service Mode", "On,Off"), ('4', "Unknown (SW1:4)", "On,Off"),
        ('5', "Demo Sounds", "Off,On"), ('6,7', "Lives", "2,5,4,3"),
        ('8', "Unknown (SW2:8)", "On,Off"), ('9', "Unknown (SW2:7)", "On,Off"),
        ('10,12', "Coin B", COIN8_5C), ('13,15', "Coin A", COIN8_5C),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("2.ic14", "acf56afb"), ("1.ic15", "820ef303"))]),
        ("NMK004 external program, 0x010000", [("6.ic120", "5f39a980")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x010000", [("7", "2f3f5a10")]),
        ("bgtile, 0x080000 (the VRAM layer, gfx1)", [("sbs-g_01.ic9", "21302e78")]),
        ("bg2tile, 0x080000 (the ROM tilemap's tiles, gfx3)", [("sbs-g_02.ic4", "f31eb668")]),
        ("tilerom, 0x020000 (ROM tilemap indices, ROM_LOAD16_BYTE pair)", [pair(("8.ic27", "75a46fea"), ("9.ic26", "d91448ee"))]),
        ("sprites, 0x080000", [("sbs-g_03.ic194", "60e00d7b")]),
        ("oki1, 0x080000", [("sbs-g_04.ic139", "7c74cc4e")]),
        ("oki2, 0x080000", [("sbs-g_05.ic160", "f0a782e3")]),
    ],
)

VANDYKE = dict(
    id=5, year=1990, manufacturer="UPL", rot=True, switches="FF,FF",
    dips=[
        ('0', "Lives", "2,3"), ('1', "Unused (SW1:7)", "On,Off"), ('2', "Unused (SW1:6)", "On,Off"),
        ('3', "Service Mode", "On,Off"), ('4', "Unused (SW1:4)", "On,Off"),
        ('5', "Demo Sounds", "Off,On"), ('6,7', "Difficulty", "Easy,Hard,Hardest,Normal"),
        ('8', "Flip Screen", "On,Off"), ('9', "Unknown (SW2:7)", "On,Off"),
        ('10,12', "Coin B", COIN8_5C), ('13,15', "Coin A", COIN8_5C),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("vdk-1.16", "c1d01c59"), ("vdk-2.15", "9d741cc2"))]),
        ("NMK004 external program, 0x010000", [("vdk-4.127", "eba544f0")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x010000", [("vdk-3.222", "5a547c1b")]),
        ("bgtile, 0x080000", [("vdk-01.13", "195a24be")]),
        ("sprites, 0x200000 (two ROM_LOAD16_BYTE pairs)", [pair(("vdk-07.202", "42d41f06"), ("vdk-06.203", "d54722a8")),
                                                            pair(("vdk-04.2-1", "0a730547"), ("vdk-05.3-1", "ba456d27"))]),
        ("oki1, 0x080000", [("vdk-02.126", "b2103274")]),
        ("oki2, 0x080000", [("vdk-03.165", "631776d3")]),
    ],
)

ACROBATM = dict(
    id=6, year=1991, manufacturer="UPL (Taito license)", rot=True, switches="FE,F7",
    dips=[
        ('0', "Demo Sounds", "On,Off"), ('1', "Flip Screen", "On,Off"),
        ('2,4', "Coin B", COIN8_5C), ('5,7', "Coin A", COIN8_5C),
        ('8', "Service Mode", "On,Off"),
        ('9,10', "Bonus Life", "None,50k and 100k,100k and 200k,100k and 100k"),
        ('11', "Language", "English,Japanese"), ('12,13', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('14,15', "Lives", "5,2,4,3"),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("2.ic100", "3fe487f4"), ("1.ic101", "17175753"))]),
        ("NMK004 external program, 0x010000", [("4.ic74", "176905fb")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x010000", [("3.ic79", "d86c186e")]),
        ("bgtile, 0x100000", [("am-03.ic8", "7c12afed")]),
        ("sprites, 0x180000 (2 files)", [("am-01.ic42", "5672bdaa"), ("am-02.ic29", "b4c0ace3")]),
        ("oki1, 0x080000", [("am-05.ic54", "3b8c2b0e")]),
        ("oki2, 0x080000", [("am-04.ic53", "c1517cd4")]),
    ],
)

def strahl_oki(name, crc):
    # ROM_START(strahl): the 0x80000 chip's four 0x20000 quarters land at
    # region 0x00000, 0x60000, 0x40000, 0x20000 ("this is a mess"); the
    # 0xA0000 region's last 0x20000 is unfilled (bank 3, silence).
    return [("slice", name, crc, 0x00000, 0x20000), ("slice", name, crc, 0x60000, 0x20000),
            ("slice", name, crc, 0x40000, 0x20000), ("slice", name, crc, 0x20000, 0x20000),
            ("fill", 0x20000)]

STRAHL = dict(
    id=7, year=1992, manufacturer="UPL", rot=False, switches="7F,FF",
    dips=[
        ('0,2', "Coin A", COIN8_STRAHL), ('3,5', "Coin B", COIN8_STRAHL),
        ('6', "Flip Screen", "On,Off"), ('7', "Demo Sounds", "On,Off"),
        ('8,9', "Lives", "5,4,2,3"), ('10,11', "Difficulty", "Hardest,Hard,Easy,Normal"),
        ('12', "Unused (SW2:5)", "On,Off"),
        ('13,14', "Bonus Life", "None,300k and every 300k,100k and every 200k,200k and every 200k"),
        ('15', "Service Mode", "On,Off"),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("strahl-02.ic82", "e6709a0d"), ("strahl-01.ic83", "bfd021cf"))]),
        ("NMK004 external program, 0x010000", [("strahl-4.66", "60a799c4")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x010000", [("strahl-3.73", "2273b33e")]),
        ("bgtile, 0x040000 (bgvideoram0's tiles, gfx1)", [("str7b2r0.275", "5769e3e1")]),
        ("bg2tile, 0x080000 (bgvideoram1's tiles, gfx3)", [("str6b1w1.776", "bb1bb155")]),
        ("sprites, 0x180000 (3 files)", [("strl3-01.32", "d8337f15"), ("strl4-02.57", "2a38552b"), ("strl5-03.58", "a0e7d210")]),
        ("oki1, 0x0A0000 (the chip's quarters in ROM_CONTINUE order 0,3,2,1, then 0x20000 unfilled)", strahl_oki("str8pmw1.540", "01d6bb6a")),
        ("oki2, 0x0A0000 (same arrangement)", strahl_oki("str9pew1.639", "6bb3eb9f")),
    ],
)

TDRAGON_DIPS = [
    ('0', "Flip Screen", "On,Off"), ('1', "Unused (SW1:7)", "On,Off"),
    ('2,3', "Difficulty", "Hardest,Easy,Hard,Normal"),
    ('4', "Unused (SW1:4)", "On,Off"), ('5', "Unused (SW1:3)", "On,Off"),
    ('6,7', "Lives", "1,2,4,3"),
    ('8', "Unused (SW2:8)", "Off,On"), ('9', "Demo Sounds", "Off,On"),
    ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
]
TDRAGON = dict(
    id=8, year=1991, manufacturer="NMK (Tecmo license)", rot=True, switches="FF,FF",
    dips=TDRAGON_DIPS,
    regions=[
        ("maincpu, 0x040000", [pair(("91070_68k.8", "121c3ae7"), ("91070_68k.7", "6e154d8e"))]),
        ("NMK004 external program, 0x010000", [("91070.1", "bf493d74")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x020000", [("91070.6", "fe365920")]),
        ("bgtile, 0x100000", [("91070.5", "d0bde826")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP)", [("91070.4", "3eedc2fe")]),
        ("oki1, 0x080000", [("91070.3", "ae6875a8")]),
        ("oki2, 0x080000", [("91070.2", "ecfea43e")]),
    ],
)
TDRAGON1 = dict(
    id=10, year=1991, manufacturer="NMK (Tecmo license)", rot=True, switches="FF,FF",
    dips=[d if d[1] not in ("Coin A", "Coin B") else (d[0], d[1], COIN8_TD1) for d in TDRAGON_DIPS],
    regions=[
        ("maincpu, 0x040000", [pair(("thund.8", "edd02831"), ("thund.7", "52192fe5"))]),
        ("NMK004 external program, 0x010000", [("91070.1", "bf493d74")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("NMK-110 protection MCU ROM, 0x004000 (read into the MCU from SDRAM after reset)", [("nmk-110-tdragon.bin", "cf66a660")]),
        ("fgtile, 0x020000", [("91070.6", "fe365920")]),
        ("bgtile, 0x100000", [("91070.5", "d0bde826")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP)", [("91070.4", "3eedc2fe")]),
        ("oki1, 0x080000", [("91070.3", "ae6875a8")]),
        ("oki2, 0x080000", [("91070.2", "ecfea43e")]),
    ],
)

HACHAMF_DIPS = [
    ('0', "Flip Screen", "On,Off"), ('1', "Language", "English,Japanese"),
    ('2,3', "Difficulty", "Hardest,Easy,Hard,Normal"),
    ('4', "Unknown (SW1:4)", "On,Off"), ('5', "Unknown (SW1:3)", "On,Off"),
    ('6,7', "Lives", "1,2,4,3"),
    ('8', "Unused (SW2:8)", "Off,On"), ('9', "Demo Sounds", "Off,On"),
    ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
]
HACHAMF = dict(
    id=9, year=1991, manufacturer="NMK", rot=False, switches="FD,FF",
    dips=HACHAMF_DIPS,
    regions=[
        ("maincpu, 0x040000", [pair(("7.93", "9d847c31"), ("6.94", "de6408a0"))]),
        ("NMK004 external program, 0x010000", [("1.70", "9e6f48fc")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("NMK-113 protection MCU ROM, 0x004000 (read into the MCU from SDRAM after reset)", [("nmk-113.bin", "f3072715")]),
        ("fgtile, 0x020000", [("5.95", "29fb04a2")]),
        ("bgtile, 0x100000", [("91076-4.101", "df9653a4")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP)", [("91076-8.57", "7fd0f556")]),
        ("oki1, 0x080000", [("91076-2.46", "3f1e67f2")]),
        ("oki2, 0x080000", [("91076-3.45", "b25ed93b")]),
    ],
)
HACHAMFP = dict(
    id=11, year=1991, manufacturer="NMK", rot=False, switches="FF,FF",
    dips=[d if d[0] != '1' else ('1', "Unused (SW1:7)", "English,Japanese") for d in HACHAMF_DIPS],
    regions=[
        ("maincpu, 0x040000", [pair(("kf-68-pe-b.ic7", "b98a525e"), ("kf-68-po-b.ic6", "b62ad179"))]),
        ("NMK004 external program, 0x010000", [("kf-snd.ic4", "f7cace47")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x020000", [("kf-vram.ic3", "a2c1e25d")]),
        ("bgtile, 0x100000 (2 files)", [("kf-scl0.ic5", "8604adff"), ("kf-scl1.ic12", "05a624e3")]),
        ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("kf-obj0.ic8", "a471bbd8"), ("kf-obj1.ic11", "81594aad"))]),
        ("oki1, 0x080000", [("kf-a0.ic2", "e068d2cf")]),
        ("oki2, 0x080000", [("kf-a1.ic1", "d945aabb")]),
    ],
)

MUSTANGS = dict(MUSTANG, id=12, manufacturer="UPL (Seoul Trading license)")

HACHAMFB = dict(HACHAMFP, id=13, switches="FD,FF", dips=HACHAMF_DIPS, manufacturer="bootleg",
    regions=[
        ("maincpu, 0x040000", [pair(("8.bin", "14845b65"), ("7.bin", "069ca579"))]),
        ("NMK004 external program, 0x010000", [("1.70", "9e6f48fc")]),
        ("NMK004 internal boot ROM, 0x002000 (nmk004.zip)", [NMK004_BOOT]),
        ("fgtile, 0x020000", [("5.95", "29fb04a2")]),
        ("bgtile, 0x100000", [("91076-4.101", "df9653a4")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP)", [("91076-8.57", "7fd0f556")]),
        ("oki1, 0x080000", [("91076-2.46", "3f1e67f2")]),
        ("oki2, 0x080000", [("91076-3.45", "b25ed93b")]),
    ])

# Bombjack Twin family: no sound CPU (68000-driven OKIs with NMK112), one
# 8x8 tile layer with two ROMs (fgtile then bgtile, contiguous), NMK-215
# on the protected sets. Coin tables are the 8-entry Free_Play ones.
BJTWIN_DIPS = [
    ('0', "Flip Screen", "On,Off"),
    ('1,3', "Starting level", "China,Hong_Kong,Thailand,Korea,Germany,England,Nevada,Japan"),
    ('4,5', "Difficulty", "Hardest,Hard,Easy,Normal"), ('6,7', "Lives", "1,2,4,3"),
    ('8', "Unknown (SW2:8)", "On,Off"), ('9', "Demo Sounds", "Off,On"),
    ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
]
BJTWIN = dict(
    id=14, year=1993, manufacturer="NMK", rot=True, switches="FF,FF", dips=BJTWIN_DIPS,
    regions=[
        ("maincpu, 0x040000", [pair(("93087-1.bin", "93c84e2d"), ("93087-2.bin", "30ff678a"))]),
        ("NMK-215 protection MCU ROM, 0x002000 (read into the MCU from SDRAM after reset)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x010000 (8x8, the tile layer's bank-0 ROM)", [("93087-3.bin", "aa13df7c")]),
        ("bgtile, 0x100000 (8x8, bank 1, NMK214-scrambled)", [("93087-4.bin", "8a4f26d0")]),
        ("sprites, 0x100000 (ROM_LOAD16_WORD_SWAP, NMK214-scrambled)", [("93087-5.bin", "bb06245d")]),
        ("oki1, 0x100000 (NMK112-banked)", [("93087-6.bin", "372d46dd")]),
        ("oki2, 0x100000 (NMK112-banked)", [("93087-7.bin", "8da67808")]),
    ])
BJTWINP = dict(
    id=15, year=1993, manufacturer="NMK", rot=True, switches="FF,FF", dips=BJTWIN_DIPS,
    regions=[
        ("maincpu, 0x040000", [pair(("ic76", "c2847f0d"), ("ic75", "dd8fdfce"))]),
        ("fgtile, 0x010000", [("ic35", "45d67683")]),
        ("bgtile, 0x180000 (3 files, plain)", [("u1.ic32", "b4960ba0"), ("u2.ic32", "99ee571d"), ("u3.ic32", "25720ffb")]),
        ("sprites, 0x100000 (ROM_LOAD16_BYTE pair, plain)", [pair(("u4.ic100", "6501b1fb"), ("u5.ic100", "8394e2ba"))]),
        ("oki1, 0x100000 (2 files)", [("bottom.ic30", "b5ef197f"), ("top.ic30", "ab50531d")]),
        ("oki2, 0x100000 (2 files)", [("top.ic27", "adb2f256"), ("bottom.ic27", "6ebeb9e4")]),
    ])
BJTWINPA = dict(
    id=16, year=1993, manufacturer="NMK", rot=True, switches="FF,FF", dips=BJTWIN_DIPS,
    regions=[
        ("maincpu, 0x040000", [pair(("ic76.bin", "81106d1e"), ("ic75.bin", "7c99b97f"))]),
        ("NMK-215 protection MCU ROM, 0x002000 (read into the MCU from SDRAM after reset)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x010000", [("ic35.bin", "aa13df7c")]),
        ("bgtile, 0x180000 (3 files, NMK214-scrambled)", [("ic32_1.bin", "e2d2b331"), ("ic32_2.bin", "28a3a845"), ("ic32_3.bin", "ecce80c9")]),
        ("sprites, 0x100000 (ROM_LOAD16_BYTE pair, NMK214-scrambled)", [pair(("ic100_1.bin", "2ea7e460"), ("ic100_2.bin", "ec85e1b7"))]),
        ("oki1, 0x100000 (2 files)", [("bottom.ic30", "b5ef197f"), ("top.ic30", "ab50531d")]),
        ("oki2, 0x100000 (2 files)", [("top.ic27", "adb2f256"), ("bottom.ic27", "6ebeb9e4")]),
    ])
SABOTENB_DIPS = [
    ('0', "Flip Screen", "On,Off"), ('1', "Language", "English,Japanese"),
    ('2,3', "Difficulty", "Hardest,Hard,Easy,Normal"), ('4', "Unused (SW1:4)", "On,Off"), ('5', "Unused (SW1:3)", "On,Off"),
    ('6,7', "Lives", "1,2,4,3"),
    ('8', "Unused (SW2:8)", "On,Off"), ('9', "Demo Sounds", "Off,On"),
    ('10,12', "Coin B", COIN8_FREE), ('13,15', "Coin A", COIN8_FREE),
]
SABOTENB = dict(
    id=17, year=1992, manufacturer="NMK / Tecmo", rot=False, switches="FF,FF", dips=SABOTENB_DIPS,
    regions=[
        ("maincpu, 0x080000", [pair(("ic76.sb1", "b2b0b2cf"), ("ic75.sb2", "367e87b7"))]),
        ("NMK-215 protection MCU ROM, 0x002000 (read into the MCU from SDRAM after reset)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x010000 (8x8, bank 0)", [("ic35.sb3", "eb7bc99d")]),
        ("bgtile, 0x200000 (8x8, bank 1, NMK214-scrambled)", [("ic32.sb4", "24c62205")]),
        ("sprites, 0x200000 (ROM_LOAD16_WORD_SWAP, NMK214-scrambled)", [("ic100.sb5", "b20f166e")]),
        ("oki1, 0x100000 (NMK112-banked)", [("ic30.sb6", "288407af")]),
        ("oki2, 0x100000 (NMK112-banked)", [("ic27.sb7", "43e33a7e")]),
    ])
CACTUS = dict(
    id=18, year=1992, manufacturer="bootleg", rot=False, switches="FF,FF", dips=SABOTENB_DIPS,
    regions=[
        ("maincpu, 0x080000", [pair(("02.bin", "15b2ff2f"), ("01.bin", "5b8ba46a"))]),
        ("fgtile, 0x010000 (sabotenb's ic35.sb3 — cactus.zip has no separate copy)", [("ic35.sb3", "eb7bc99d")]),
        ("bgtile, 0x200000 (2 files; sabotenb's data, descrambled with the NMK-215's fixed configs)", [("s-05.bin", "fce962b9"), ("s-06.bin", "16768fbc")]),
        ("sprites, 0x200000 (ROM_LOAD16_BYTE pair)", [pair(("s-04.bin", "f823885e"), ("s-03.bin", "bc1781b8"))]),
        ("oki1, 0x100000 (sabotenb's ic30.sb6, same data as the driver's s-01.bin)", [("ic30.sb6", "288407af")]),
        ("oki2, 0x100000 (sabotenb's ic27.sb7)", [("ic27.sb7", "43e33a7e")]),
    ])
NOURYOKU_DIPS = [
    ('0,1', "Life Decrease Speed", "Very Fast,Fast,Slow,Normal"), ('2,3', "Difficulty", "Hardest,Hard,Easy,Normal"),
    ('4', "Free Play", "On,Off"), ('5,7', "Coinage", "2C_3C,4C_1C,1C_3C,2C_1C,1C_4C,3C_1C,1C_2C,1C_1C"),
    ('8', "Unused (SW2:8)", "On,Off"), ('9', "Unused (SW2:7)", "On,Off"), ('10', "Unused (SW2:6)", "On,Off"),
    ('11', "Unused (SW2:5)", "On,Off"), ('12', "Unused (SW2:4)", "On,Off"), ('13', "Flip Screen", "On,Off"),
    ('14', "Demo Sounds", "Off,On"), ('15', "Service Mode", "On,Off"),
]
NOURYOKU = dict(
    id=17, year=1995, manufacturer="Tecmo", rot=False, switches="FF,FF", dips=NOURYOKU_DIPS,
    regions=[
        ("maincpu, 0x080000", [pair(("ic76.1", "26075988"), ("ic75.2", "75ab82cd"))]),
        ("NMK-215 protection MCU ROM, 0x002000 (read into the MCU from SDRAM after reset)", [("nmk-215.bin", "d355a06f")]),
        ("fgtile, 0x010000 (8x8, bank 0)", [("ic35.3", "03d0c3b1")]),
        ("bgtile, 0x200000 (8x8, bank 1, NMK214-scrambled)", [("ic32.4", "88d454fd")]),
        ("sprites, 0x200000 (ROM_LOAD16_WORD_SWAP, NMK214-scrambled)", [("ic100.5", "24d3e24e")]),
        ("oki1, 0x100000 (NMK112-banked)", [("ic30.6", "feea34f4")]),
        ("oki2, 0x100000 (NMK112-banked)", [("ic27.7", "8a69fded")]),
    ])
NOURYOKUP = dict(
    id=19, year=1995, manufacturer="Tecmo", rot=False, switches="FF,FF", dips=NOURYOKU_DIPS,
    regions=[
        ("maincpu, 0x080000", [pair(("ic76.1", "26075988"), ("ic75.2", "75ab82cd"))]),
        ("fgtile, 0x010000", [("ic35.3", "03d0c3b1")]),
        ("bgtile, 0x200000 (4 files, plain)", [("bg0.u1.ic32", "1fec8e14"), ("bg1.u2.ic32", "7b8ea3f0"), ("bg2.u3.ic32", "6f4eb408"), ("bg3.u4.ic32", "dea8c120")]),
        ("sprites, 0x200000 (two ROM_LOAD16_BYTE pairs, plain)", [pair(("obj0even.u7.ic100", "7966ce07"), ("obj0odd.u6.ic100", "d4913a08")),
                                                                    pair(("obj1even.u9.ic100", "e01567e8"), ("obj1odd.u8.ic100", "4a383085"))]),
        ("oki1, 0x100000 (2 files)", [("soundpcm0.bottom.ic30", "34ded136"), ("soundpcm1.top.ic30", "a8d2abf7")]),
        ("oki2, 0x100000 (2 files)", [("soundpcm2.top.ic27", "29d0a15d"), ("soundpcm3.bottom.ic27", "c764e749")]),
    ])
THARRIER = dict(
    id=20, year=1989, manufacturer="UPL", rot=True, switches="FF,FF",
    # One 16-bit DSW port: SW2 in the low byte (switch byte 0), SW1 in the high byte (byte 1).
    dips=[
        ('0', "Unknown (SW2:8)", "On,Off"), ('1', "Demo Sounds", "Off,On"),
        ('2,4', "Coin B", COIN8_FREE), ('5,7', "Coin A", COIN8_FREE),
        ('8', "Cabinet", "Cocktail,Upright"), ('9', "Unknown (SW1:7)", "On,Off"),
        ('10,11', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('12,13', "Bonus Life", "200k 500k & 1 2 3 5 Mil,None,200k and 1 Mil,200k"),
        ('14,15', "Lives", "5,2,4,3"),
    ],
    regions=[
        ("maincpu, 0x040000", [pair(("2.18b", "f3887a44"), ("3.21b", "65c247f6"))]),
        ("Z80 sound program, 0x010000", [("12.4l", "b959f837")]),
        ("fgtile, 0x010000", [("1.13b", "005c26c3")]),
        ("bgtile, 0x080000", [("89050-4.16f", "64d7d687")]),
        ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("89050-13.16d", "24db3fa4"), ("89050-17.16e", "7f715421"))]),
        ("oki1, 0x080000", [("89050-8.4j", "11ee4c39")]),
        ("oki2, 0x080000", [("89050-10.14j", "893552ab")]),
    ])
VANDYKEB = dict(VANDYKE, id=21, manufacturer="bootleg",
    regions=[
        ("maincpu, 0x040000", [pair(("2.bin", "9c269702"), ("1.bin", "dd6303a1"))]),
        ("fgtile, 0x010000 (vandyke's vdk-3.222)", [("vdk-3.222", "5a547c1b")]),
        ("bgtile, 0x080000 (2 files)", [("4.bin", "4ba4138d"), ("5.bin", "9a1ac697")]),
        ("sprites, 0x180000 (four ROM_LOAD16_BYTE pairs)", [pair(("13.bin", "bb561871"), ("17.bin", "346e3b66")), pair(("12.bin", "cdef9b17"), ("16.bin", "beda678c")),
                                                            pair(("11.bin", "823185d9"), ("15.bin", "149f3247")), pair(("10.bin", "388b1abc"), ("14.bin", "32eeba37"))]),
        ("oki1, 0x080000 (4 files; never played — the board has no sound CPU)", [("9.bin", "56bf774f"), ("8.bin", "89851fcf"), ("7.bin", "d7bf0f6a"), ("6.bin", "a7fcf709")]),
    ])

# mustangb3 (Lettering bootleg, 2026-09-12): mustang's game with the
# Task Force Harrier-style Z80 + YM2203 sound board (tharrier_sound_map,
# the OKI bank writes unmapped: 0x20000 sample ROMs), 8 MHz 68000, fixed-
# scanline IRQs and a PC-keyed read at 0x080006 (gunnail_core.sv id 22).
# Its GFX ROMs are not dumped; MAME uses the parent's (BAD_DUMP), so the
# .mra takes them from mustang.zip.
MUSTANGB3 = dict(MUSTANG, id=22, manufacturer="bootleg (Lettering)",
    regions=[
        ("maincpu, 0x040000", [pair(("u2.bin", "1c6c0aaf"), ("u1.bin", "e954d6da"))]),
        ("Z80 sound program, 0x010000", [("u14.bin", "26041abd")]),
        ("fgtile, 0x020000 (mustang's, undumped on this board)", [("90058-1", "81ccfcad")]),
        ("bgtile, 0x080000 (mustang's)", [("90058-4", "a07a2002")]),
        ("sprites, 0x100000 (mustang's ROM_LOAD16_BYTE pair)", [pair(("90058-8", "560bff04"), ("90058-9", "b9d72a03"))]),
        ("oki1, 0x020000 (unbanked)", [("u13.bin", "90961f37")]),
        ("oki2, 0x020000 (unbanked)", [("u12.bin", "0a28eaca")]),
    ])

# ---------------------------------------------------------------------------
# Afega boards (Family H, 2026-09-13): gunnail_core.sv ids 23-43, one per
# distinct configuration (decryptcode table, screen_update variant, ROM
# sizes); every set below carries its own region list transcribed from
# its ROM_START. One 16-bit DSW port at 0x080004: bits 0-7 = SW2 (switch
# byte 0), bits 8-15 = SW1 (byte 1), as mustang. The program ROM pairs are
# streamed raw (the core un-scrambles the address lines per fetch); 8bpp
# BG regions are their two 4bpp halves back to back (region order). The
# generator substitutes the parent's file name for a part a split clone
# zip omits (looked up by CRC) — see resolve_name().
COIN_AFEGA = "4C_1C,2C_3C,2C_1C,1C_2C,3C_1C,1C_3C,3C_2C,1C_1C"
COIN_POPS = "4C_1C,3C_1C,2C_1C,3C_2C,2C_3C,1C_3C,1C_2C,1C_1C"
COIN_BUBL = "Disabled,1C_4C,3C_1C,1C_2C,4C_1C,1C_3C,2C_1C,1C_1C"
STAGGER1_DIPS = [
    ('0', "Service Mode", "On,Off"), ('1', "Demo Sounds", "Off,On"),
    ('2', "Unused (SW2:6)", "On,Off"), ('3', "Unused (SW2:5)", "On,Off"), ('4', "Unused (SW2:4)", "On,Off"), ('5', "Unused (SW2:3)", "On,Off"),
    ('6,7', "Lives", "1,5,2,3"), ('8,9', "Flip Screen", "On,Vertically,Horizontally,Off"), ('10', "Unused (SW1:6)", "On,Off"),
    ('11,12', "Difficulty", "Hardest,Easy,Hard,Normal"), ('13,15', "Coinage", COIN_AFEGA)]
REDHAWKB_DIPS = [  # "probably just redhawk but inverted" — every switch reads active high, defaults 0
    ('0', "Unused (SW2:8)", "Off,On"), ('1', "Demo Sounds", "On,Off"),
    ('2', "Unused (SW2:6)", "Off,On"), ('3', "Unused (SW2:5)", "Off,On"), ('4', "Unused (SW2:4)", "Off,On"), ('5', "Unused (SW2:3)", "Off,On"),
    ('6,7', "Lives", "3,2,5,1"), ('8,9', "Flip Screen", "Off,Horizontally,Vertically,On"), ('10', "Unused (SW1:6)", "Off,On"),
    ('11,12', "Difficulty", "Normal,Hard,Easy,Hardest"), ('13,15', "Coinage", "1C_1C,3C_2C,1C_3C,3C_1C,1C_2C,2C_1C,2C_3C,4C_1C")]
GRDNSTRM_DIPS = [
    ('0', "Service Mode", "On,Off"), ('1', "Demo Sounds", "Off,On"), ('2', "Free Play", "On,Off"), ('3', "Bombs", "3,2"),
    ('4', "Unused (SW1:4)", "On,Off"), ('5', "Unused (SW1:3)", "On,Off"), ('6,7', "Lives", "1,5,2,3"),
    ('8', "Mirror Screen", "On,Off"), ('9', "Flip Screen", "On,Off"), ('10', "Unused (SW2:6)", "On,Off"),
    ('11,12', "Difficulty", "Hardest,Easy,Hard,Normal"), ('13,15', "Coinage", COIN_AFEGA)]
GRDNSTRK_DIPS = [d if d[0] not in ('8', '9') else (d[0], "Flip Screen" if d[0] == '8' else "Mirror Screen", "On,Off") for d in GRDNSTRM_DIPS]
POPSPOPS_DIPS = [
    ('0', "Service Mode", "On,Off"), ('1', "Demo Sounds", "Off,On"), ('2', "Unknown (tells the answers)", "On,Off"),
    ('3', "Unknown (SW:4)", "On,Off"), ('4', "Unknown (SW:5)", "On,Off"), ('5', "Unknown (SW:6)", "On,Off"), ('6', "Free Play", "On,Off"),
    ('7', "Unknown (SW:8)", "On,Off"), ('8', "Unknown (SW:9)", "On,Off"), ('9', "Unknown (SW:10)", "On,Off"), ('10', "Unknown (SW:11)", "On,Off"),
    ('11,12', "Difficulty", "Hardest,Hard,Easy,Normal"), ('13,15', "Coinage", COIN_POPS)]
BUBL2000_DIPS = [
    ('0', "Unused (SW2:8)", "On,Off"), ('1', "Unused (SW2:7)", "On,Off"), ('2,3', "Difficulty", "Hardest,Hard,Easy,Normal"),
    ('4', "Unused (SW2:4)", "On,Off"), ('5', "Unused (SW2:3)", "On,Off"), ('6,7', "Free Credit", "1500k,1000k,500k,800k"),
    ('8', "Unused (SW1:8)", "On,Off"), ('9', "Demo Sounds", "Off,On"), ('10,12', "Coin B", COIN_BUBL), ('13,15', "Coin A", COIN_BUBL)]
BUBL2000A_DIPS = [
    ('0', "Unused (SW1:8)", "On,Off"), ('1', "Unused (SW1:7)", "On,Off"), ('2,4', "Coin B", COIN_BUBL), ('5,7', "Coin A", COIN_BUBL),
    ('8', "Unused (SW2:8)", "On,Off"), ('9', "Unused (SW2:7)", "On,Off"), ('10,11', "Difficulty", "Hardest,Hard,Easy,Normal"),
    ('12', "Unused (SW2:4)", "On,Off"), ('13', "Unused (SW2:3)", "On,Off"), ('14,15', "Free Credit", "1500k,1000k,500k,800k")]
MANGCHI_DIPS = [
    ('0', "DSWS", "On,Off"), ('1', "Demo Sounds", "Off,On"), ('2', "Unknown (SW:3)", "On,Off"), ('3,4', "Vs Rounds", "5,4,3,2"),
    ('5', "Unknown (SW:6)", "On,Off"), ('6', "Free Play", "On,Off"), ('7', "Unknown (SW:8)", "On,Off"), ('8', "Unknown (SW:9)", "On,Off"),
    ('9', "Unknown (SW:10)", "On,Off"), ('10', "Unknown (SW:11)", "On,Off"), ('11,12', "Difficulty", "Hardest,Easy,Hard,Normal"), ('13,15', "Coinage", COIN_POPS)]
FIREHAWK_DIPS = [
    ('0', "Service Mode", "On,Off"), ('1,3', "Difficulty", "Hard,Hard,Hardest,Very_Easy,Easy,Easy,Very_Hard,Normal"),
    ('4', "Demo Sounds", "Off,On"), ('5', "Number of Bombs", "3,2"), ('6,7', "Lives", "1,4,2,3"), ('8', "Unknown (SW2:8)", "On,Off"),
    ('9', "Region", "China,World"), ('10', "Free Play", "On,Off"), ('11,12', "Continue Coins", "4 Coins,2 Coins,3 Coins,1 Coin"),
    ('13,15', "Coinage", COIN_AFEGA)]
SPEC2K_DIPS = [
    ('0', "Service Mode", "On,Off"), ('1', "Demo Sounds", "Off,On"), ('2', "Free Play", "On,Off"), ('3', "Number of Bombs", "3,2"),
    ('4', "Copyright Notice", "Off,On"), ('5', "Unknown (SW1:3)", "On,Off"), ('6,7', "Lives", "1,5,2,3"),
    ('8', "Unknown (SW2:8)", "On,Off"), ('9', "Unknown (SW2:7)", "On,Off"), ('10', "Unknown (SW2:6)", "On,Off"),
    ('11,12', "Difficulty", "Hardest,Easy,Hard,Normal"), ('13,15', "Coinage", COIN_AFEGA)]

def afega(id, year, manufacturer, rot, dips, regions, switches="FF,FF", bg8=False):
    return dict(id=id, year=year, manufacturer=manufacturer, rot=rot, switches=switches, dips=dips, regions=regions, afega=True, bg8=bg8)

Z80 = "Z80 sound program, 0x010000"
RH = lambda *a: afega(*a)  # noqa
STAGGER1 = afega(23, 1998, "Afega", True, STAGGER1_DIPS, [
    ("maincpu, 0x040000 (address-scrambled: none)", [pair(("2.bin", "8555929b"), ("3.bin", "5b0b63ac"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4.bin", "46463d36")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7.bin", "048f7683"), ("6.bin", "051d4a77"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKE = afega(23, 1997, "Afega (Excellent Co. license)", True, STAGGER1_DIPS, [
    ("maincpu, 0x040000", [pair(("rhawk2.bin", "6d2e23b4"), ("rhawk3.bin", "5e0d6188"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("rhawk4.bin", "d79aa288")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("rhawk7.bin", "0264ef54"), ("rhawk6.bin", "3f980ab6"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKK = afega(23, 1997, "Afega", True, STAGGER1_DIPS, [
    ("maincpu, 0x040000", [pair(("2", "8c02e81d"), ("3", "ab3597ee"))]),
    (Z80, [("1", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4", "6255d6a1")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7", "f4fa8211"), ("6", "6a0b8224"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKC = afega(23, 1997, "Afega (Zhuojia Co. license)", True, STAGGER1_DIPS, [
    ("maincpu, 0x040000", [pair(("afega_2.bin", "34356a0f"), ("afega_3.bin", "cbaa0229"))]),
    (Z80, [("afega_1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("afega_4.bin", "d6427b8a")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("afega_7.bin", "45d000e6"), ("afega_6.bin", "5a505a56"))]),
    ("oki1, 0x040000", [("afega_5.bin", "e911ce33")])])
REDHAWK = afega(24, 1997, "Afega (New Vision Ent. license)", True, STAGGER1_DIPS, [
    ("maincpu, 0x040000 (address lines 13-17 scrambled: init_redhawk, decoded per fetch)", [pair(("2", "3ef5f326"), ("3", "9b3a10ef"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4", "d6427b8a")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7", "66a8976d"), ("6", "61560164"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKI = afega(25, 1997, "Afega (Hae Dong Corp license)", False, STAGGER1_DIPS, [
    ("maincpu, 0x040000 (init_redhawki scramble)", [pair(("rhit-2.bin", "30cade0e"), ("rhit-3.bin", "37dbb3c2"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("rhit-4.bin", "aafb3cc4")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("rhit-7.bin", "bcb367c7"), ("rhit-6.bin", "7cbd5c60"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKS = afega(26, 1997, "Afega (Hae Dong Corp license)", False, STAGGER1_DIPS, [
    ("maincpu, 0x040000", [pair(("2.bin", "8b427ef8"), ("3.bin", "117e3813"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4.bin", "03a8d952")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7.bin", "5c5b5fa1"), ("6.bin", "aa6564e6"))]),
    ("oki1, 0x040000", [("5.bin", "e911ce33")])])
REDHAWKSA = afega(27, 1997, "Afega (Hae Dong Corp license)", False, STAGGER1_DIPS, [
    ("maincpu, 0x040000 (init_redhawksa scramble)", [pair(("2.bin", "0e428cbb"), ("3.bin", "e944627f"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4.bin", "aafb3cc4")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7.bin", "1a8c8560"), ("6.bin", "533cb5f2"))]),
    ("oki1, 0x040000", [("5.bin", "e911ce33")])])
REDHAWKG = afega(28, 1997, "Afega", False, STAGGER1_DIPS, [
    ("maincpu, 0x040000 (init_redhawkg scramble)", [pair(("2.bin", "ccd459eb"), ("3.bin", "483802fd"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp)", [("4.bin", "aafb3cc4")]),
    ("sprites, 0x100000 (ROM_LOAD16_BYTE pair)", [pair(("7.bin", "a28c8454"), ("6.bin", "710c9e3c"))]),
    ("oki1, 0x040000", [("5", "e911ce33")])])
REDHAWKB = afega(29, 1997, "bootleg (Vince)", False, REDHAWKB_DIPS, [
    ("maincpu, 0x040000", [pair(("rhb-1.bin", "e733ea07"), ("rhb-2.bin", "f9fa5684"))]),
    (Z80, [("1.bin", "5d8cf28e")]),
    ("bgtile, 0x080000 (4bpp, packed_lsb)", [("rhb-5.bin", "d0eaf6f2")]),
    ("sprites, 0x100000 (two plain files, packed_lsb)", [("rhb-3.bin", "0318d68b"), ("rhb-4.bin", "ba21c1ef")]),
    ("oki1, 0x040000", [("5", "e911ce33")])], switches="00,00")
GS_BG = ("bgtile, 0x400000 (8bpp: two 4bpp halves)", [("afega_af1-b2.uc8", "d68588c2"), ("afega_af1-b1.uc3", "f8b200a8")])
GRDNSTRM = afega(30, 1998, "Afega (Apples Industries license)", False, GRDNSTRM_DIPS, [
    ("maincpu, 0x080000", [pair(("afega4.u112", "2244713a"), ("afega5.u107", "5815c806"))]),
    (Z80, [("afega7.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("afega1.u4", "9e7ef086")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega3.uc13", "0218017c")]),
    ("oki1, 0x040000", [("afega1.u95", "e911ce33")])], bg8=True)
GRDNSTRMK = afega(31, 1998, "Afega", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrm scramble)", [pair(("gst-04.u112", "922c931a"), ("gst-05.u107", "d22ca2dc"))]),
    (Z80, [("afega7.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("gst-03.u4", "a1347297")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega_af1-sp.uc13", "7d4d4985")]),
    ("oki1, 0x040000", [("afega1.u95", "e911ce33")])], bg8=True)
GRDNSTRMV = afega(31, 1998, "Afega (Apples Industries license)", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrm scramble)", [pair(("afega2.u112", "16d41050"), ("afega3.u107", "05920a99"))]),
    (Z80, [("afega7.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("afega1.u4", "9e7ef086")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega6.uc13", "9b54ff84")]),
    ("oki1, 0x040000", [("afega1.u95", "e911ce33")])], bg8=True)
GRDNSTRMJ = afega(32, 1998, "Afega", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrmg scramble)", [pair(("afega_3.u112", "e51a35fb"), ("afega_4.u107", "cb10aa54"))]),
    (Z80, [("afega7.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("gst-03.u4", "a1347297")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega_af1-sp.uc13", "7d4d4985")]),
    ("oki1, 0x040000", [("afega1.u95", "e911ce33")])], bg8=True)
GRDNSTRMG = afega(33, 1998, "Afega", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrmg scramble; uc9 = even MAME offsets)", [pair(("gs6_c2.uc9", "ea363e4d"), ("gs5_c1.uc1", "c0263e4a"))]),
    (Z80, [("gs1_s1.uc14", "5d8cf28e")]),
    ("fgtile, 0x010000", [("gs3_t1.uc2", "88c423ef")]),
    ("bgtile, 0x200000 (8bpp: two 4bpp halves, four files)", [("gs10_cr5.uc15", "2c8c23e3"), ("gs4_cr7.uc19", "c3f6c908"), ("gs8_cr1.uc6", "dc0125f0"), ("gs9_cr3.uc12", "d8a0636b")]),
    ("sprites, 0x200000 (two ROM_LOAD16_BYTE pairs)", [pair(("gs7_br1.uc3", "e6794265"), ("gs8_br3.uc10", "7b42a57a")), pair(("gs9_br2.uc4", "4d2c220b"), ("gs10_br4.uc11", "1d3b57e1"))]),
    ("oki1, 0x040000", [("gs2_s2.uc18", "e911ce33")])], bg8=True)
GRDNSTRMAU = afega(34, 1998, "Afega", False, GRDNSTRM_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrmau scramble)", [pair(("uc9_27c020.10", "548932b4"), ("uc1_27c020.9", "269e2fbc"))]),
    (Z80, [("uc14_27c512.8", "5d8cf28e")]),
    ("fgtile, 0x010000", [("uc2_27c512.9", "b38d8446")]),
    ("bgtile, 0x200000 (8bpp: two 4bpp halves, four files)", [("uc15_27c040.10", "0822f7e0"), ("uc19_27c040.8", "fa078e35"), ("uc6_27c040.9", "ec288b95"), ("uc12_27c040.10", "a9ceec33")]),
    ("sprites, 0x200000 (two ROM_LOAD16_BYTE pairs)", [pair(("uc3_27c040.8", "9fc36932"), ("uc10_27c040.9", "6e809d09")), pair(("uc4_27c040.10", "73bd6451"), ("uc11_27c040.8", "e699a3c9"))]),
    ("oki1, 0x040000", [("uc18_27c020.9", "e911ce33")])], bg8=True)
REDFOXWP2 = afega(35, 1998, "Afega", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000", [pair(("u112", "3f31600b"), ("u107", "daa44ab4"))]),
    (Z80, [("u92", "864b55c2")]),
    ("fgtile, 0x010000", [("u4", "19239401")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega_af1-sp.uc13", "7d4d4985")]),
    ("oki1, 0x040000", [("afega1.u95", "e911ce33")])], bg8=True)
REDFOXWP2A = afega(36, 1998, "Afega", True, GRDNSTRK_DIPS, [
    ("maincpu, 0x080000 (init_redfoxwp2a scramble)", [pair(("afega_4.u112", "e6e6682a"), ("afega_5.u107", "2faa2ed6"))]),
    (Z80, [("afega_1.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("afega_3.u4", "64608687")]), GS_BG,
    ("sprites, 0x200000 (plain)", [("afega_af1-sp.uc13", "7d4d4985")]),
    ("oki1, 0x040000", [("afega_2.u95", "e911ce33")])], bg8=True)
POPSPOPS = afega(37, 1999, "Afega", False, POPSPOPS_DIPS, [
    ("maincpu, 0x080000 (init_grdnstrm scramble)", [pair(("afega4.u112", "db191762"), ("afega5.u107", "17e0c48b"))]),
    (Z80, [("afega1.u92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("afega3.u4", "f39dd5d2")]),
    ("bgtile, 0x400000 (8bpp: two 4bpp halves); no sprite ROM on this board", [("afega6.uc8", "6d506c97"), ("afega7.uc3", "02d7f9de")]),
    ("oki1, 0x040000", [("afega2.u95", "ecd8eeac")])], switches="FB,FF", bg8=True)
MANGCHI = afega(38, 2000, "Afega", False, MANGCHI_DIPS, [
    ("maincpu, 0x080000 (init_bubl2000 scramble)", [pair(("afega9.u112", "0b1517a5"), ("afega10.u107", "b1d0f33d"))]),
    (Z80, [("sound.u92", "bec4f9aa")]),
    ("bgtile, 0x100000 (8bpp: two 4bpp halves); no 8x8 ROM", [("afega5.uc6", "c73261e0"), ("afega4.uc1", "73940917")]),
    ("sprites, 0x080000 (ROM_LOAD16_BYTE pair)", [pair(("afega6.uc11", "979efc30"), ("afega7.uc14", "c5cbcc38"))]),
    ("oki1, 0x040000", [("afega2.u95", "78c8c1f9")])], bg8=True)
BUBL_TAIL = [
    (Z80, [("rom01.92", "5d8cf28e")]),
    ("fgtile, 0x010000", [("rom03.4", "f4c15588")]),
    ("bgtile, 0x300000 (8bpp: two 4bpp halves, six files)", [("rom06.6", "ac1aabf5"), ("rom07.9", "69aff769"), ("rom13.7", "3a5b7226"), ("rom04.1", "46acd054"), ("rom05.3", "37deb6a1"), ("rom12.2", "1fdc59dd")]),
    ("sprites, 0x080000 (ROM_LOAD16_BYTE pair)", [pair(("rom08.11", "519dfd82"), ("rom09.14", "04fcb5c6"))]),
    ("oki1, 0x040000", [("rom02.95", "859a86e5")])]
BUBL2000 = afega(39, 1998, "Afega (Tuning license)", False, BUBL2000_DIPS,
    [("maincpu, 0x040000 (init_bubl2000 scramble)", [pair(("rom10.112", "87f960d7"), ("rom11.107", "b386041a"))])] + BUBL_TAIL, bg8=True)
BUBL2000A = afega(39, 1998, "Afega (Tuning license)", False, BUBL2000A_DIPS,
    [("maincpu, 0x040000 (init_bubl2000 scramble)", [pair(("b-2000_n_v1.2.112", "da28624b"), ("b-2000_n_v1.2.107", "c766c1fb"))])] + BUBL_TAIL, bg8=True)
HOTBUBL = afega(39, 1998, "Afega (Pandora license)", False, BUBL2000_DIPS, [
    ("maincpu, 0x040000 (init_bubl2000 scramble; uc9 = even MAME offsets)", [pair(("afega9.c2.uc9", "4537c6d9"), ("afega8.c1.uc1", "d1e72a31"))]),
    (Z80, [("afega8.s1.uc14", "5d8cf28e")]),
    ("fgtile, 0x010000", [("afega9.t1.uc2", "ce683a93")]),
    ("bgtile, 0x300000 (8bpp: two 4bpp halves, six files in region order)", [("afega10.cr5.uc15", "65bd5159"), ("afega10.cr7.uc19", "a89d9ce4"), ("afega9.cr6.uc16", "99d6523c"), ("afega8.cr1.uc6", "fc9101d2"), ("afega9.cr3.uc12", "c841a4f6"), ("afega9.cr2.uc7", "27ad6fc8")]),
    ("sprites, 0x080000 (ROM_LOAD16_BYTE pair)", [pair(("afega10.br1.uc3", "7e132eff"), ("afega8.br3.uc10", "22707728"))]),
    ("oki1, 0x040000", [("afega8.s2.uc18", "401c980f")])], bg8=True)
HOTBUBLA = afega(43, 1998, "Afega (Pandora license)", False, BUBL2000_DIPS, [
    ("maincpu, 0x080000 (init_bubl2000 scramble; 0x40000 files, halves identical; uc9 = even MAME offsets)", [pair(("7_c2.uc9", "74eb11c3"), ("6_c1.uc1", "7c65bf47"))]),
    (Z80, [("1_s1.uc14", "5d8cf28e")]),
    ("fgtile, 0x010000", [("2_t1.uc2", "ce683a93")]),
    ("bgtile, 0x300000 (8bpp: two 4bpp halves, six files in region order)", [("2_cr5.uc15", "dd7e92de"), ("5_cr7.uc19", "d293f1d0"), ("5_cr6.uc16", "324429c5"), ("8_cr1.uc6", "7e2840b4"), ("10_cr3.uc12", "312c38d8"), ("9_cr2.uc7", "c5516087")]),
    ("sprites, 0x080000 (ROM_LOAD16_BYTE pair)", [pair(("8_br1.uc3", "7e132eff"), ("9_br3.uc10", "22707728"))]),
    ("oki1, 0x040000", [("1_s2.uc18", "401c980f")])], bg8=True)
FIREHAWK = afega(40, 2001, "ESD", False, FIREHAWK_DIPS, [
    ("maincpu, 0x100000 (firehawk_map; u60 = even MAME offsets)", [pair(("fhawk_p2.u60", "9f35d245"), ("fhawk_p1.u59", "d6d71a50"))]),
    ("Z80 sound program, 0x020000", [("fhawk_s1.u40", "c6609c39")]),
    ("bgtile, 0x400000 (8bpp: two 4bpp halves); no 8x8 ROM", [("fhawk_g1.uc6", "2ab0b06b"), ("fhawk_g2.uc5", "d11bfa20")]),
    ("sprites, 0x200000 (plain)", [("fhawk_g3.uc2", "cae72ff4")]),
    ("oki1, 0x040000", [("fhawk_s2.u36", "d16aaaad")]),
    ("oki2, 0x040000", [("fhawk_s3.u41", "3fdcfac2")])], bg8=True)
SPEC2K = afega(41, 2000, "Yona Tech", True, SPEC2K_DIPS, [
    ("maincpu, 0x080000 (init_spec2k scramble)", [pair(("u124", "dbd6f65d"), ("u120", "be53e243"))]),
    (Z80, [("u103", "f4e4fb10")]),
    ("fgtile, 0x020000", [("u3", "921503b8")]),
    ("bgtile, 0x400000 (8bpp: two 4bpp halves)", [("uc3", "1d087122"), ("uc2", "998dc05c")]),
    ("sprites, 0x200000 (plain)", [("uc1", "3139a213")]),
    ("oki1, 0x040000", [("u101", "d16aaaad")]),
    ("oki2, 0x080000 (two banks, Z80 0xFFF2)", [("u106", "65d61f3a")])], bg8=True)
SPEC2KH = afega(42, 2000, "Yona Tech", False, SPEC2K_DIPS, [
    ("maincpu, 0x080000 (init_spec2k scramble)", [pair(("yonatech5.u124", "72ab5c05"), ("yonatech6.u120", "7e44bd9c"))]),
    (Z80, [("yonatech1.u103", "ef5acda7")]),
    ("fgtile, 0x020000", [("yonatech4.u3", "5626b08e")]),
    ("bgtile, 0x400000 (8bpp: two 4bpp halves)", [("u153.bin", "a00bbf8f"), ("u152.bin", "f6423fab")]),
    ("sprites, 0x200000 (plain)", [("u154.bin", "f77b764e")]),
    ("oki1, 0x020000", [("yonatech2.u101", "4160f172")]),
    ("oki2, 0x080000 (two banks, Z80 0xFFF2)", [("yonatech3.u106", "6644c404")])], bg8=True)

# setname, description, GAME() line, parent spec, parent setname (for the zip
# search list) and region overrides: {old part name: (new name, crc)}.
SETS = [
    ("gunnail",     "GunNail (28th May. 1992)",                                   10732, GUNNAIL,  None, {}),
    ("gunnailp",    "GunNail (location test)",                                     10733, dict(GUNNAIL, year=1992, manufacturer="NMK"), "gunnail",
     {"pair:3e.u131": ("3.u132", "93570f03"), "1.u21": ("1.u21", "bdf427e4")}),
    ("macross",     "Super Spacefortress Macross / Chou-Jikuu Yousai Macross",     10730, MACROSS,  None, {}),
    ("blkheart",    "Black Heart",                                                 10713, BLKHEART, None, {}),
    ("blkheartj",   "Black Heart (Japan)",                                         10714, BLKHEART, "blkheart",
     {"blkhrt.7": ("7.bin", "e0a5c667"), "blkhrt.6": ("6.bin", "7cce45e8")}),
    ("mustang",     "US AAF Mustang (25th May. 1990)",                             10702, MUSTANG,  None, {}),
    ("mustangs",    "US AAF Mustang (25th May. 1990 / Seoul Trading)",             10703, MUSTANGS, "mustang",
     {"2.bin": ("90058-2", "833aa458"), "3.bin": ("90058-3", "e4b80f06")}),
    ("bioship",     "Bio-ship Paladin",                                            10705, BIOSHIP,  None, {}),
    ("sbsgomo",     "Space Battle Ship Gomorrah (Japan)",                          10706, dict(BIOSHIP, manufacturer="UPL"), "bioship",
     {"2.ic14": ("11.ic14", "7916150b"), "1.ic15": ("10.ic15", "1d7accb8"), "7": ("7.ic46", "f2b77f80")}),
    ("vandyke",     "Vandyke (Japan)",                                             10708, VANDYKE,  None, {}),
    ("vandykejal",  "Vandyke (Jaleco, set 1)",                                     10709, dict(VANDYKE, manufacturer="UPL (Jaleco license)"), "vandyke",
     {"vdk-2.15": ("jaleco2.15", "170e4d2e")}),
    ("vandykejal2", "Vandyke (Jaleco, set 2)",                                     10710, dict(VANDYKE, manufacturer="UPL (Jaleco license)"), "vandyke",
     {"vdk-1.16": ("vdk-even.16", "cde05a84"), "vdk-2.15": ("vdk-odd.15", "0f6fea40")}),
    ("acrobatm",    "Acrobat Mission",                                             10716, ACROBATM, None, {}),
    ("strahl",      "Koutetsu Yousai Strahl (World)",                              10718, STRAHL,   None, {}),
    ("strahlj",     "Koutetsu Yousai Strahl (Japan set 1)",                        10719, STRAHL,   "strahl",
     {"strahl-02.ic82": ("strahl-2.82", "c9d008ae"), "strahl-01.ic83": ("strahl-1.83", "afc3c4d6")}),
    ("strahlja",    "Koutetsu Yousai Strahl (Japan set 2)",                        10720, STRAHL,   "strahl",
     {"strahl-02.ic82": ("rom2", "f80a22ef"), "strahl-01.ic83": ("rom1", "802ecbfc")}),
    ("tdragon",     "Thunder Dragon (8th Jan. 1992, unprotected)",                 10722, TDRAGON,  None, {}),
    ("tdragon1",    "Thunder Dragon (4th Jun. 1991, protected)",                   10723, TDRAGON1, "tdragon", {}),
    ("hachamf",     "Hacha Mecha Fighter (19th Sep. 1991, protected, set 1)",      10725, HACHAMF,  None, {}),
    ("hachamfa",    "Hacha Mecha Fighter (19th Sep. 1991, protected, set 2)",      10726, HACHAMF,  "hachamf",
     {"7.93": ("7.ic93", "f437e52b"), "6.94": ("6.ic94", "60d340d0"), "5.95": ("5.ic95", "a2c1e25d")}),
    ("hachamfp",    "Hacha Mecha Fighter (Location Test Prototype, 19th Sep. 1991)", 10728, HACHAMFP, "hachamf", {}),
    ("hachamfb",    "Hacha Mecha Fighter (19th Sep. 1991, unprotected, bootleg Thunder Dragon conversion)", 10727, HACHAMFB, "hachamf", {}),
    ("bjtwin",      "Bombjack Twin (set 1)",                                       10755, BJTWIN,   None, {}),
    ("bjtwina",     "Bombjack Twin (set 2)",                                       10756, BJTWIN,   "bjtwin",
     {"93087-1.bin": ("93087.1", "c82b3d8e"), "93087-2.bin": ("93087.2", "9be1ec47")}),
    ("bjtwinp",     "Bombjack Twin (prototype? with adult pictures, set 1)",       10757, BJTWINP,  "bjtwin", {}),
    ("bjtwinpa",    "Bombjack Twin (prototype? with adult pictures, set 2)",       10758, BJTWINPA, "bjtwin", {}),
    ("sabotenb",    "Saboten Bombers (set 1)",                                     10751, SABOTENB, None, {}),
    ("sabotenba",   "Saboten Bombers (set 2)",                                     10752, SABOTENB, "sabotenb",
     {"ic76.sb1": ("sb1.76", "df6f65e2"), "ic75.sb2": ("sb2.75", "0d2c1ab8")}),
    ("cactus",      "Cactus (bootleg of Saboten Bombers)",                         10753, CACTUS,   "sabotenb", {}),
    ("nouryoku",    "Nouryoku Koujou Iinkai",                                      10760, NOURYOKU, None, {}),
    ("nouryokup",   "Nouryoku Koujou Iinkai (prototype)",                          10761, NOURYOKUP, "nouryoku", {}),
    ("mustangb3",   "US AAF Mustang (Lettering bootleg)",                          10791, MUSTANGB3, "mustang", {}),
    ("tharrier",    "Task Force Harrier",                                          10699, THARRIER, None, {}),
    ("tharrieru",   "Task Force Harrier (US)",                                     10700, THARRIER, "tharrier",
     {"2.18b": ("u_2.18b", "78923aaa"), "3.21b": ("u_3.21b", "99cea259"), "1.13b": ("1.13b", "c7402e4a")}),
    ("vandykeb",    "Vandyke (bootleg with PIC16c57)",                             10711, VANDYKEB, "vandyke", {}),
    # Afega (Family H)
    ("stagger1",    "Stagger I (Japan)",                                           10815, STAGGER1, None, {}),
    ("redhawk",     "Red Hawk (USA, Canada & South America)",                      10816, REDHAWK, "stagger1", {}),
    ("redhawki",    "Red Hawk (horizontal, Italy)",                                10817, REDHAWKI, "stagger1", {}),
    ("redhawks",    "Red Hawk (horizontal, Spain, set 1)",                         10818, REDHAWKS, "stagger1", {}),
    ("redhawksa",   "Red Hawk (horizontal, Spain, set 2)",                         10819, REDHAWKSA, "stagger1", {}),
    ("redhawkg",    "Red Hawk (horizontal, Greece)",                               10820, REDHAWKG, "stagger1", {}),
    ("redhawke",    "Red Hawk (Excellent Co., Ltd)",                               10821, REDHAWKE, "stagger1", {}),
    ("redhawkk",    "Red Hawk (Korea)",                                            10822, REDHAWKK, "stagger1", {}),
    ("redhawkc",    "Red Hawk (China & Hong Kong)",                                10823, REDHAWKC, "stagger1", {}),
    ("redhawkb",    "Red Hawk (horizontal, bootleg)",                              10824, REDHAWKB, "stagger1", {}),
    ("grdnstrm",    "Guardian Storm (horizontal, not encrypted)",                  10826, GRDNSTRM, None, {}),
    ("grdnstrmv",   "Guardian Storm (vertical)",                                   10827, GRDNSTRMV, "grdnstrm", {}),
    ("grdnstrmj",   "Sen Jing - Guardian Storm (Japan)",                           10828, GRDNSTRMJ, "grdnstrm", {}),
    ("grdnstrmk",   "Jeon Sin - Guardian Storm (Korea)",                           10829, GRDNSTRMK, "grdnstrm", {}),
    ("redfoxwp2",   "Hong Hu Zhanji II (China, set 1)",                            10830, REDFOXWP2, "grdnstrm", {}),
    ("redfoxwp2a",  "Hong Hu Zhanji II (China, set 2)",                            10831, REDFOXWP2A, "grdnstrm", {}),
    ("grdnstrmg",   "Guardian Storm (Germany)",                                    10832, GRDNSTRMG, "grdnstrm", {}),
    ("grdnstrmau",  "Guardian Storm (horizontal, Australia)",                      10833, GRDNSTRMAU, "grdnstrm", {}),
    ("bubl2000",    "Bubble 2000",                                                 10836, BUBL2000, None, {}),
    ("bubl2000a",   "Bubble 2000 V1.2",                                            10837, BUBL2000A, "bubl2000", {}),
    ("hotbubl",     "Hot Bubble (Korea, with adult pictures)",                     10838, HOTBUBL, "bubl2000", {}),
    ("hotbubla",    "Hot Bubble (Korea)",                                          10839, HOTBUBLA, "bubl2000", {}),
    ("popspops",    "Pop's Pop's",                                                 10841, POPSPOPS, None, {}),
    ("mangchi",     "Mang-Chi",                                                    10843, MANGCHI, None, {}),
    ("spec2k",      "Spectrum 2000 (vertical, Korea)",                             10846, SPEC2K, None, {}),
    ("spec2kh",     "Spectrum 2000 (horizontal, buggy) (Europe)",                  10847, SPEC2KH, "spec2k", {}),
    ("firehawk",    "Fire Hawk (World) / Huohu Chuanshuo (China) (horizontal)",    10848, FIREHAWK, "spec2k", {}),
]


_ZIP_CACHE = {}
def _zip_index(setname, parent):
    """{name: crc} over the set's zips (set, parent, nmk004) and {crc: name} over the parent's."""
    key = (setname, parent)
    if key not in _ZIP_CACHE:
        import zipfile
        roms = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mame_roms")
        names, bycrc = {}, {}
        for z in [setname + ".zip"] + ([parent + ".zip"] if parent else []):
            p = os.path.join(roms, z)
            if not os.path.exists(p):
                continue
            for i in zipfile.ZipFile(p).infolist():
                names.setdefault(i.filename, "%08x" % i.CRC)
                bycrc.setdefault("%08x" % i.CRC, i.filename)
        _ZIP_CACHE[key] = (names, bycrc)
    return _ZIP_CACHE[key]

_RESOLVE = None  # (setname, parent) of the set being generated, see main()
def resolve_name(name, crc):
    """A split clone zip omits the files identical to its parent's; the .mra
    (MiSTer matches by name) then needs the PARENT's name for that file."""
    if _RESOLVE is None:
        return name
    names, bycrc = _zip_index(*_RESOLVE)
    if name in names or crc not in bycrc:
        return name
    return bycrc[crc]

def part_lines(parts, overrides):
    out = []
    for p in parts:
        if p[0] == "pair":
            even, odd = p[1], p[2]
            if "pair:" + even[0] in overrides:  # a clone replaced the pair with one WORD_SWAP file
                n, c = overrides["pair:" + even[0]]
                out.append(f'    <part crc="{c}" name="{n}"/>\n')
                continue
            even = overrides.get(even[0], even)
            odd = overrides.get(odd[0], odd)
            out.append('    <interleave output="16">\n')
            out.append(f'      <part crc="{odd[1]}" name="{resolve_name(odd[0], odd[1])}" map="01"/>\n')
            out.append(f'      <part crc="{even[1]}" name="{resolve_name(even[0], even[1])}" map="10"/>\n')
            out.append('    </interleave>\n')
        elif p[0] == "slice":
            _, n, c, off, ln = p
            n, c = overrides.get(n, (n, c))
            out.append(f'    <part crc="{c}" name="{n}" offset="0x{off:05X}" length="0x{ln:05X}"/>\n')
        elif p[0] == "fill":
            out.append(f'    <part repeat="0x{p[1]:X}">00</part>\n')
        else:
            n, c = overrides.get(p[0], p)
            out.append(f'    <part crc="{c}" name="{resolve_name(n, c)}"/>\n')
    return "".join(out)


def mra(setname, desc, game_line, spec, parent, overrides):
    zips = [setname + ".zip"] + ([parent + ".zip"] if parent else []) + ["nmk004.zip"]
    out = []
    out.append(f"""<!--
  {desc} — NMK16 "Gunnail" rbf (rtl/gunnail/gunnail_core.sv game id {spec['id']}).
  {'Clone of ' + parent + '; files it shares with the parent are looked up in the parent zip.' if parent else 'Parent set.'}

  Transcribed from mame/src/mame/nmk/nmk16.cpp: GAME(... {setname} ...)
  line {game_line}, ROM_START({setname}), its INPUT_PORTS_START DIP tables.
  ROM part order = the core's per-game SDRAM layout (contiguous — the
  loader streams the parts back to back). The nmk_irq timing PROMs are
  fixed at synthesis and not downloaded. Generated by
  tools/gen_gunnail_mra.py.
-->
<misterromdescription>
  <name>{desc}</name>
  <mratimestamp>202609110000</mratimestamp>
  <mameversion>0270</mameversion>
  <setname>{setname}</setname>
  <year>{spec['year']}</year>
  <manufacturer>{spec['manufacturer']}</manufacturer>
  <category>Shooter</category>
  <rbf>Gunnail</rbf>
""")
    if spec["rot"]:
        out.append("\n  <!-- ROT270 in nmk16.cpp -->\n  <rotation>1</rotation>\n")
    out.append(f"""
  <!-- DSW1, DSW2 (defaults from the PORT_DIPNAME default values; ids in
       bit-value order, value 0 first), then the game-id byte the core
       selects the board with. -->
  <switches default="{spec['switches']},{spec['id']:02X}">
""")
    for bits, name, ids in spec["dips"]:
        out.append(f'    <dip bits="{bits}" name="{name}" ids="{ids}"/>\n')
    out.append("  </switches>\n\n")
    out.append(f'  <buttons names="{BUTTONS[0]}" default="{BUTTONS[1]}"/>\n\n')
    out.append(f'  <rom index="0" zip="{"|".join(zips)}" md5="none">\n')
    for comment, parts in spec["regions"]:
        out.append(f"    <!-- {comment} -->\n")
        out.append(part_lines(parts, overrides))
    out.append("  </rom>\n</misterromdescription>\n")
    return "".join(out)


def ioctl_args(setname):
    """mk_ioctl_stream.py arguments for a set's hardware-sim download stream
    (the same layout as the .mra): region offsets from the zip member sizes."""
    import zipfile
    global _RESOLVE
    entry = [e for e in SETS if e[0] == setname][0]
    _, _, _, spec, parent, overrides = entry
    _RESOLVE = (setname, parent)  # parent-name substitution for split clone zips, as in the .mra
    zips = [setname + ".zip"] + ([parent + ".zip"] if parent else []) + ["nmk004.zip"]
    roms = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mame_roms")
    zf = [zipfile.ZipFile(os.path.join(roms, z)) for z in zips]
    def size(name):
        for z in zf:
            if name in z.namelist():
                return z.getinfo(name).file_size
        raise SystemExit(f"{name} not in {zips}")
    args = [f"--zip mame_roms/{z}" for z in zips]
    off = 0
    for comment, parts in spec["regions"]:
        elems, ln = [], 0
        for p in parts:
            if p[0] == "pair":
                even, odd = p[1], p[2]
                if "pair:" + even[0] in overrides:
                    n = overrides["pair:" + even[0]][0]; elems.append(n); ln += size(n); continue
                even = overrides.get(even[0], even); odd = overrides.get(odd[0], odd)
                en, on = resolve_name(even[0], even[1]), resolve_name(odd[0], odd[1])
                elems.append(f"{on}+{en}"); ln += size(en) + size(on)
            elif p[0] == "slice":
                n = overrides.get(p[1], (p[1], p[2]))[0]
                elems.append(f"{n}@0x{p[3]:X}/0x{p[4]:X}"); ln += p[4]
            elif p[0] == "fill":
                elems.append(f"zero/0x{p[1]:X}"); ln += p[1]
            else:
                n, c = overrides.get(p[0], p); n = resolve_name(n, c); elems.append(n); ln += size(n)
        args.append(f"--region 0x{off:06X}:{','.join(elems)}")
        off += ln
    return " ".join(args)


def sim_roms(setname, outdir):
    """Write the HW_ROMS=0 reference-sim hex files for a set from its zips:
    <set>_maincpu.hex (16-bit words, MAME region order), and byte hex files
    for audiocpu, fgtile, bgtile (+ bg2tile = the second half of an 8bpp
    region), sprites (region order), oki1, oki2. Absent regions get a
    small all-FF file so $readmemh has something to open."""
    import zipfile
    global _RESOLVE
    entry = [e for e in SETS if e[0] == setname][0]
    _, _, _, spec, parent, overrides = entry
    _RESOLVE = (setname, parent)
    roms = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mame_roms")
    zf = [zipfile.ZipFile(os.path.join(roms, z)) for z in [setname + ".zip"] + ([parent + ".zip"] if parent else []) + ["nmk004.zip"]
          if os.path.exists(os.path.join(roms, z))]
    def rd(name, crc):
        name = resolve_name(overrides.get(name, (name, crc))[0], overrides.get(name, (name, crc))[1])
        for z in zf:
            if name in z.namelist():
                return z.read(name)
        raise SystemExit(f"{name} not found for {setname}")
    regions = {}
    for comment, parts in spec["regions"]:
        kind = comment.split(",")[0].split(" ")[0]
        if kind == "Z80" or kind == "NMK004" and "external" in comment: kind = "audiocpu"
        buf = bytearray()
        for p in parts:
            if p[0] == "pair":
                e, o = rd(p[1][0], p[1][1]), rd(p[2][0], p[2][1])
                b = bytearray(len(e) * 2); b[0::2] = e; b[1::2] = o; buf += b
            elif p[0] == "slice":
                buf += rd(p[1], p[2])[p[3]:p[3] + p[4]]
            elif p[0] == "fill":
                buf += bytes(p[1])
            else:
                buf += rd(p[0], p[1])
        regions[kind] = bytes(buf)
    os.makedirs(outdir, exist_ok=True)
    def wbytes(kind, data):
        with open(os.path.join(outdir, f"{setname}_{kind}.hex"), "w") as f:
            f.write("".join("%02x\n" % b for b in data))
    m = regions["maincpu"]
    with open(os.path.join(outdir, f"{setname}_maincpu.hex"), "w") as f:
        f.write("".join("%02x%02x\n" % (m[i], m[i + 1]) for i in range(0, len(m), 2)))
    for kind in ("audiocpu", "fgtile", "bgtile", "sprites", "oki1", "oki2"):
        data = regions.get(kind)
        if data is None:
            data = bytes([0xFF]) * (0x10000 if kind in ("fgtile", "audiocpu") else 0x1000)
        wbytes(kind, data)
    if spec.get("bg8"):
        b = regions["bgtile"]
        wbytes("bgtile", b[:len(b) // 2])
        wbytes("bg2tile", b[len(b) // 2:])
    print("wrote", setname, "sim roms to", outdir, {k: hex(len(v)) for k, v in regions.items()})


def main():
    import sys
    global _RESOLVE
    if len(sys.argv) > 2 and sys.argv[1] == "--ioctl":
        print(ioctl_args(sys.argv[2]))
        return
    if len(sys.argv) > 3 and sys.argv[1] == "--simroms":
        sim_roms(sys.argv[2], sys.argv[3])
        return
    for setname, desc, line, spec, parent, overrides in SETS:
        _RESOLVE = (setname, parent)
        # exFAT/FAT (the MiSTer SD card) reject '?' and '/' in file names — the
        # bjtwinp/bjtwinpa .mra files silently failed to copy with MAME's title.
        fname = desc.replace(" / ", " - ").replace("/", "-").replace("?", "") + ".mra"
        path = os.path.join(RELEASES, fname)
        with open(path, "w") as f:
            f.write(mra(setname, desc, line, spec, parent, overrides))
        print("wrote", fname)


if __name__ == "__main__":
    main()
