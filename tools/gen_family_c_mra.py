#!/usr/bin/env python3
"""Generate the Family C ("Macross2" rbf) clone .mra files.

The two parents (tdragon2, macross2) are hand-authored in releases/ with
their full derivation notes; this script writes their clones from the
table below, transcribed from mame/src/mame/nmk/nmk16.cpp's GAME() and
ROM_START blocks. Every clone shares the parent's machine config, DIPs
and buttons; only the ROM parts and the description differ. The ROM
part order is the shared core's fixed SDRAM layout (docs/hw-bringup.md):
maincpu, audiocpu, fgtile, bgtile, sprites (2 parts), oki1, oki2. The
nmk_irq timing PROMs are fixed at synthesis and not downloaded.

File names follow the MAME description; "/" cannot appear in a file
name, so it becomes " - ". Run from the repo root:
    python3 tools/gen_family_c_mra.py
"""
import os

RELEASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "releases")

# Parent-specific blocks (identical to the hand-authored parent .mra files).
TDRAGON2 = dict(
    manufacturer="NMK", rotation="1", switches="F7,FF,00",
    dips=[
        ('0', "Service Mode", "On,Off"),
        ('1', "Demo Sounds", "Off,On"),
        ('2', "Flip Screen", "On,Off"),
        ('3', "Unused", "Off,On"),
        ('4,5', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('6,7', "Lives", "1,2,4,3"),
        ('8,11', "Coin B", "5C_3C,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"),
        ('12,15', "Coin A", "Free_Play,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"),
    ],
    buttons=("Button 1,Button 2,Button 3,Button 4,Start,Coin", "Y,B,A,X,Start,R"),
    shared=[  # (crc, name, region comment) for the parts every tdragon2 set shares
        ("b870be61", "5.bin", "audiocpu, 0x020000 @ 0x080000"),
        ("d488aafa", "1.bin", "fgtile, 0x020000 @ 0x0A0000"),
        ("f968c65d", "ww930914.2", "bgtile, 0x200000 @ 0x0C0000"),
        ("b98873cb", "ww930917.7", "sprites, 0x400000 @ 0x2C0000 (2 files, ROM_LOAD16_WORD_SWAP)"),
        ("baee84b2", "ww930918.8", None),
        ("07c35fe6", "ww930916.4", "oki1, 0x200000 @ 0x6C0000"),
        ("82025bab", "ww930915.3", "oki2, 0x200000 @ 0x8C0000"),
    ],
)
MACROSS2 = dict(
    manufacturer="Banpresto", rotation=None, switches="F7,FF,01",
    dips=[
        ('0', "Service Mode", "On,Off"),
        ('1', "Demo Sounds", "Off,On"),
        ('2', "Flip Screen", "On,Off"),
        ('3', "Language", "English,Japanese"),
        ('4,5', "Difficulty", "Hardest,Easy,Hard,Normal"),
        ('6', "Unknown (SW1:2)", "On,Off"),
        ('7', "Unknown (SW1:1)", "On,Off"),
        ('8,11', "Coin B", "5C_3C,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"),
        ('12,15', "Coin A", "Free_Play,2C_1C,3C_2C,1C_4C,4C_1C,1C_6C,2C_5C,1C_2C,4C_3C,1C_7C,3C_1C,1C_3C,3C_4C,1C_5C,2C_3C,1C_1C"),
    ],
    # 6 entries (including the placeholders "Button 3"/"Button 4" this
    # game has no use for), matching the shared core's fixed CONF_STR
    # "J1,Button 1,Button 2,Button 3,Button 4,Start,Coin;" (Power Instinct
    # has four buttons): MiSTer's default gamepad mapping is positional
    # against THIS list, so a shorter one shifts Start/Coin and breaks
    # gamepad Coin (found and fixed 2026-09-10, see docs/hw-bringup.md).
    buttons=("Button 1,Button 2,Button 3,Button 4,Start,Coin", "Y,B,A,X,Start,R"),
    shared=[
        ("b4aa8ac7", "mcrs2j.2", "audiocpu, 0x020000 @ 0x080000"),
        ("c7417410", "mcrs2j.1", "fgtile, 0x020000 @ 0x0A0000"),
        ("c4d77ff0", "bp932an.a04", "bgtile, 0x200000 @ 0x0C0000"),
        ("aa1b21b9", "bp932an.a07", "sprites, 0x400000 @ 0x2C0000 (2 files, ROM_LOAD16_WORD_SWAP)"),
        ("67eb2901", "bp932an.a08", None),
        ("ef0ffec0", "bp932an.a06", "oki1, 0x200000 @ 0x6C0000"),
        ("b5335abb", "bp932an.a05", "oki2, 0x100000 (game's own size; the shared map's slot is 0x200000)"),
    ],
)

POWERINS = dict(
    manufacturer="Atlus", rotation=None, switches="FF,FB,02", category="Fighting",
    maincpu_comment="maincpu, 0x100000 @ 0x000000 (2 files, ROM_LOAD16_WORD_SWAP)",
    dips=[
        ('0', "Free Play", "On,Off"),
        ('1,3', "Coin B", "2C_1C (1 to cont.),1C_4C,3C_1C,1C_2C,4C_1C,1C_3C,2C_1C,1C_1C"),
        ('4,6', "Coin A", "2C_1C (1 to cont.),1C_4C,3C_1C,1C_2C,4C_1C,1C_3C,2C_1C,1C_1C"),
        ('7', "Flip Screen", "On,Off"),
        ('8', "Coin Chutes", "2 Chutes,1 Chute"),
        ('9', "Join In Mode", "On,Off"),
        ('10', "Demo Sounds", "On,Off"),
        ('11', "Allow Continue", "Off,On"),
        ('12', "Blood Color", "Blue,Red"),
        ('13', "Game Time", "Short,Normal"),
        ('14,15', "Difficulty", "Hardest,Easy,Hard,Normal"),
    ],
    buttons=("Button 1,Button 2,Button 3,Button 4,Start,Coin", "Y,B,A,X,Start,R"),
    # powerins' SDRAM layout (tdragon2_core.sv BASE_WORD_* with game_powerins=1)
    shared=[
        ("d3d7a782", "93095-4.u109", None),
        ("4b123cc6", "93095-2.u90", "audiocpu, 0x020000 @ 0x100000"),
        ("6a579ee0", "93095-1.u15", "fgtile, 0x020000 @ 0x120000"),
        ("b1371808", "93095-5.u16", "bgtile, 0x280000 @ 0x140000 (3 files)"),
        ("29c85d80", "93095-6.u17", None),
        ("2dd76149", "93095-7.u18", None),
        ("35f3c2a3", "93095-12.u116", "sprites, 0x800000 @ 0x3C0000 (8 files, ROM_LOAD16_WORD_SWAP)"),
        ("1ebd45da", "93095-13.u117", None),
        ("760d871b", "93095-14.u118", None),
        ("d011be88", "93095-15.u119", None),
        ("a9c16c9c", "93095-16.u120", None),
        ("51b57288", "93095-17.u121", None),
        ("b135e3f2", "93095-18.u122", None),
        ("67695537", "93095-19.u123", None),
        ("329ac6c5", "93095-10.u48", "oki1, 0x200000 @ 0xBC0000 (2 files)"),
        ("75d6097c", "93095-11.u49", None),
        ("f019bedb", "93095-8.u46", "oki2, 0x200000 @ 0xDC0000 (2 files)"),
        ("adc83765", "93095-9.u47", None),
    ],
)

# The two prototype sets use a different board layout (OS93089 SUB
# daughterboard): the same regions and sizes, but the BG tiles in five
# 0x80000 files, each OKI in four, and the sprites as eight
# ROM_LOAD16_BYTE pairs (fo = odd MAME offsets, fe = even). The core's
# SDRAM image is the parent's raw ROM_LOAD16_WORD_SWAP file order (it
# rebuilds words by byte parity and reads sprite bytes with the address
# bit 0 inverted), which for a byte pair means the odd-offset chip on
# even stream addresses: the same <interleave> convention releases/
# GunNail (28th May. 1992).mra uses for its maincpu pair, verified on
# hardware there. Entries of the form ("interleave", [(crc, name, map),
# ...], comment) emit an <interleave output="16"> block.
POWERINSP = dict(
    manufacturer="Atlus", rotation=None, switches="FF,FB,02", category="Fighting",
    zip_parent="powerins",
    maincpu_comment="maincpu, 0x100000 @ 0x000000 (2 files, ROM_LOAD16_WORD_SWAP)",
    dips=[d if d[0] != '8' else ('8', "Unknown (SW2:8)", "On,Off") for d in POWERINS["dips"]],
    buttons=POWERINS["buttons"],
    shared=[
        ("9c0f23cf", "4.p000.v3.8.u117.27c4096", None),
        ("4b123cc6", "2.sound 9.20.u74.27c1001", "audiocpu, 0x020000 @ 0x100000"),
        ("6a579ee0", "1.text 1080.u16.27c010", "fgtile, 0x020000 @ 0x120000"),
        ("1975b4b8", "ba0.s0.27c040", "bgtile, 0x280000 @ 0x140000 (5 files)"),
        ("376e4919", "ba1.s1.27c040", None),
        ("0d5ff532", "ba2.s2.27c040", None),
        ("99b25791", "ba3.s3.27c040", None),
        ("2dd76149", "ba4.s4.27c040", None),
        ("interleave", [("8b9b89c9", "fo0.mo0.27c040", "01"), ("4d127bdf", "fe0.me0.27c040", "10")], "sprites, 0x800000 @ 0x3C0000 (8 ROM_LOAD16_BYTE pairs: fo = odd MAME offsets on even stream addresses, fe on odd)"),
        ("interleave", [("298eb50e", "fo1.mo1.27c040", "01"), ("57e6d283", "fe1.me1.27c040", "10")], None),
        ("interleave", [("fb184167", "fo2.mo2.27c040", "01"), ("1b752a4d", "fe2.me2.27c040", "10")], None),
        ("interleave", [("2f26ba7b", "fo3.mo3.27c040", "01"), ("0263d89b", "fe3.me3.27c040", "10")], None),
        ("interleave", [("c4633294", "fo4.mo4.27c040", "01"), ("5e4b5655", "fe4.me4.27c040", "10")], None),
        ("interleave", [("4d4b0e4e", "fo5.mo5.27c040", "01"), ("7e9f2d2b", "fe5.me5.27c040", "10")], None),
        ("interleave", [("0e7671f2", "fo6.mo6.27c040", "01"), ("ee59b1ec", "fe6.me6.27c040", "10")], None),
        ("interleave", [("9ab1998c", "fo7.mo7.27c040", "01"), ("1ab0c88a", "fe7.me7.27c040", "10")], None),
        ("8cd6824e", "ao0.ad00.27c040", "oki1, 0x200000 @ 0xBC0000 (4 files)"),
        ("e31ae04d", "ao1.ad01.27c040", None),
        ("c4c9f599", "ao2.ad02.27c040", None),
        ("f0a9f0e1", "ao3.ad03.27c040", None),
        ("62557502", "ad10.ad10.27c040", "oki2, 0x200000 @ 0xDC0000 (4 files)"),
        ("dbc86bd7", "ad11.ad11.27c040", None),
        ("5839a2bd", "ad12.ad12.27c040", None),
        ("446f9dc3", "ad13.ad13.27c040", None),
    ],
)

# setname, parent, description, GAME() line, ROM_START line range, maincpu part, overrides of shared parts[, dip overrides]
CLONES = [
    ("macross2g", "macross2", "Super Spacefortress Macross II / Chou-Jikuu Yousai Macross II (Gamest review build)",
     10737, ("151f9d39", "3.u11"), {}),
    ("macross2k", "macross2", "Macross II (Korea)",
     10738, ("1506fcfc", "1.3"), {"mcrs2j.1": ("372dfa11", "2.1")}),
    ("tdragon2a", "tdragon2", "Thunder Dragon 2 (1st Oct. 1993)",
     10741, ("310d6bca", "6.bin"), {}),
    ("bigbang", "tdragon2", "Big Bang (9th Nov. 1993, set 1)",
     10742, ("28e5957a", "eprom.3"), {}),
    ("bigbanga", "tdragon2", "Big Bang (9th Nov. 1993, set 2)",
     10743, ("c79966d1", "3.u117"), {}),
    # powerinsj: INPUT_PORTS_START(powerinj) only turns DSW2:8 into "Unknown".
    # (powerinspu/powerinspj, the prototypes, use a different board layout —
    # ROM_LOAD16_BYTE sprite pairs and split BG/OKI files — and are not
    # generated here.)
    ("powerinsj", "powerins", "Gouketsuji Ichizoku (Japan)",
     10765, ("3050a3fb", "93095-3j.u108"), {},
     {'8': ("Unknown (SW2:8)", "On,Off")}),
    # Prototypes (INPUT_PORTS powerinj): the second maincpu file has the same
    # CRC in both sets under different names.
    ("powerinspu", "powerinsp", "Power Instinct (USA, prototype)",
     10766, ("d1dd5a3f", "3.p000.v4.0a.u116.27c240"), {}),
    ("powerinspj", "powerinsp", "Gouketsuji Ichizoku (Japan, prototype)",
     10767, ("4ea18490", "3.p000.pc_j_12-1_155e.u116"),
     {"4.p000.v3.8.u117.27c4096": ("9c0f23cf", "4.p000.f_p4.u117")}),
]

PARENTS = {"tdragon2": TDRAGON2, "macross2": MACROSS2, "powerins": POWERINS, "powerinsp": POWERINSP}


def mra(setname, parent, desc, game_line, maincpu, overrides, dip_overrides=None):
    p = PARENTS[parent]
    dip_overrides = dip_overrides or {}
    out = []
    out.append(f"""<!--
  {desc} — clone of {parent} on the shared Family C "Macross2" rbf.
  Generated by tools/gen_family_c_mra.py from mame/src/mame/nmk/
  nmk16.cpp: GAME(... {setname} ...) line {game_line}, ROM_START({setname}).
  Machine config, DIP switches and buttons are the parent's (see the
  hand-authored parent .mra for the full derivation); only the ROM
  parts differ. Files shared with the parent are looked up in the
  parent's zip as well (zip="{setname}.zip|{p.get("zip_parent", parent)}.zip").
-->
<misterromdescription>
  <name>{desc}</name>
  <mratimestamp>202609090000</mratimestamp>
  <mameversion>0270</mameversion>
  <setname>{setname}</setname>
  <year>1993</year>
  <manufacturer>{p['manufacturer']}</manufacturer>
  <category>{p.get('category', 'Shooter')}</category>
  <rbf>Macross2</rbf>
""")
    if p["rotation"]:
        out.append(f"\n  <!-- ROT270 in nmk16.cpp -->\n  <rotation>{p['rotation']}</rotation>\n")
    out.append(f"""
  <!-- DSW1/DSW2 defaults and the hidden game-select third byte, as the parent. -->
  <switches default="{p['switches']}">
""")
    for bits, name, ids in p["dips"]:
        if bits in dip_overrides:
            name, ids = dip_overrides[bits]
        out.append(f'    <dip bits="{bits}" name="{name}" ids="{ids}"/>\n')
    out.append("  </switches>\n\n")
    names, default = p["buttons"]
    out.append(f'  <buttons names="{names}" default="{default}"/>\n\n')
    out.append(f'  <rom index="0" zip="{setname}.zip|{p.get("zip_parent", parent)}.zip" md5="none">\n')
    out.append(f"    <!-- {p.get('maincpu_comment', 'maincpu, 0x080000 @ 0x000000')} -->\n")
    out.append(f'    <part crc="{maincpu[0]}" name="{maincpu[1]}"/>\n')
    for crc, name, comment in p["shared"]:
        if comment:
            out.append(f"    <!-- {comment} -->\n")
        if crc == "interleave":
            out.append('    <interleave output="16">\n')
            for icrc, iname, imap in name:
                out.append(f'      <part crc="{icrc}" name="{iname}" map="{imap}"/>\n')
            out.append('    </interleave>\n')
            continue
        if name in overrides:
            crc, name = overrides[name]
        out.append(f'    <part crc="{crc}" name="{name}"/>\n')
    out.append("  </rom>\n</misterromdescription>\n")
    return "".join(out)


def main():
    for entry in CLONES:
        setname, parent, desc, line, maincpu, overrides = entry[:6]
        dip_overrides = entry[6] if len(entry) > 6 else None
        fname = desc.replace(" / ", " - ").replace("/", "-") + ".mra"
        path = os.path.join(RELEASES, fname)
        with open(path, "w") as f:
            f.write(mra(setname, parent, desc, line, maincpu, overrides, dip_overrides))
        print("wrote", fname)


if __name__ == "__main__":
    main()
