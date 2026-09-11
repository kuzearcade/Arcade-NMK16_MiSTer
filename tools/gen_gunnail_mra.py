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
]


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
            out.append(f'      <part crc="{odd[1]}" name="{odd[0]}" map="01"/>\n')
            out.append(f'      <part crc="{even[1]}" name="{even[0]}" map="10"/>\n')
            out.append('    </interleave>\n')
        elif p[0] == "slice":
            _, n, c, off, ln = p
            n, c = overrides.get(n, (n, c))
            out.append(f'    <part crc="{c}" name="{n}" offset="0x{off:05X}" length="0x{ln:05X}"/>\n')
        elif p[0] == "fill":
            out.append(f'    <part repeat="0x{p[1]:X}">00</part>\n')
        else:
            n, c = overrides.get(p[0], p)
            out.append(f'    <part crc="{c}" name="{n}"/>\n')
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
    entry = [e for e in SETS if e[0] == setname][0]
    _, _, _, spec, parent, overrides = entry
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
                elems.append(f"{odd[0]}+{even[0]}"); ln += size(even[0]) + size(odd[0])
            elif p[0] == "slice":
                n = overrides.get(p[1], (p[1], p[2]))[0]
                elems.append(f"{n}@0x{p[3]:X}/0x{p[4]:X}"); ln += p[4]
            elif p[0] == "fill":
                elems.append(f"zero/0x{p[1]:X}"); ln += p[1]
            else:
                n = overrides.get(p[0], p)[0]; elems.append(n); ln += size(n)
        args.append(f"--region 0x{off:06X}:{','.join(elems)}")
        off += ln
    return " ".join(args)


def main():
    import sys
    if len(sys.argv) > 2 and sys.argv[1] == "--ioctl":
        print(ioctl_args(sys.argv[2]))
        return
    for setname, desc, line, spec, parent, overrides in SETS:
        # exFAT/FAT (the MiSTer SD card) reject '?' and '/' in file names — the
        # bjtwinp/bjtwinpa .mra files silently failed to copy with MAME's title.
        fname = desc.replace(" / ", " - ").replace("/", "-").replace("?", "") + ".mra"
        path = os.path.join(RELEASES, fname)
        with open(path, "w") as f:
            f.write(mra(setname, desc, line, spec, parent, overrides))
        print("wrote", fname)


if __name__ == "__main__":
    main()
