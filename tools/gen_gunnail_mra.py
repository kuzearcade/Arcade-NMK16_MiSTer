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
    12 mustangs. ids are listed in bit-value order (value 0 first).
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
        fname = desc.replace(" / ", " - ").replace("/", "-") + ".mra"
        path = os.path.join(RELEASES, fname)
        with open(path, "w") as f:
            f.write(mra(setname, desc, line, spec, parent, overrides))
        print("wrote", fname)


if __name__ == "__main__":
    main()
