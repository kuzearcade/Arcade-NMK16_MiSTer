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
]

PARENTS = {"tdragon2": TDRAGON2, "macross2": MACROSS2, "powerins": POWERINS}


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
  parent's zip as well (zip="{setname}.zip|{parent}.zip").
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
    out.append(f'  <rom index="0" zip="{setname}.zip|{parent}.zip" md5="none">\n')
    out.append(f"    <!-- {p.get('maincpu_comment', 'maincpu, 0x080000 @ 0x000000')} -->\n")
    out.append(f'    <part crc="{maincpu[0]}" name="{maincpu[1]}"/>\n')
    for crc, name, comment in p["shared"]:
        if name in overrides:
            crc, name = overrides[name]
        if comment:
            out.append(f"    <!-- {comment} -->\n")
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
