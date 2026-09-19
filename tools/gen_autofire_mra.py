#!/usr/bin/env python3
"""Mirror releases/ into autofire_releases/ with the OSD Autofire menu unlocked.

Every core hides its "P1/P2 Autofire" options (CONF_STR `h1`) unless the
loaded .mra's own <switches> third byte has bit 6 set (autofire_unlock in
NMK16_*.sv). The shipped .mra files in releases/ never set it, so this
script writes a second tree, same layout (parents at the top,
`_alternatives/_<Parent>/` clones below), same file names, with bit 6 set
in that byte -- for the shoot-'em-ups only: the non-shmup sets listed in
EXCLUDED (and every clone under their `_alternatives` directory) are left
out entirely. Nothing else in the file changes, so the .mra keeps its
ROM parts, DIPs, buttons, hiscore and cheat tables byte for byte.

autofire_releases/ is git-ignored: it is a derived local tree. Re-run this
whenever anything in releases/ changes (the three gen_*_mra.py generators,
gen_hiscore_mra.py, gen_cheats_mra.py, or a hand edit):

    python3 tools/gen_autofire_mra.py          # rebuilds autofire_releases/
    python3 tools/gen_autofire_mra.py --check  # only reports what is stale

The output directory is wiped first so a set removed from releases/
disappears here too.

MiSTer caveat (seen on the board 2026-09-19): the firmware's arcade_sw_load
copies a saved config/dips/<mra name>.dip over the WHOLE switches value,
third byte included, so a game whose DIPs were ever changed in the OSD
keeps its old byte 2 and the Autofire options stay hidden until that file
is deleted or the OSD's System > "Reset settings" writes the defaults back
(the .dip is keyed by the .mra <name>, which these copies share with
releases/). With no .dip present the unlock takes effect at once.
"""
import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "releases")
DST = os.path.join(ROOT, "autofire_releases")

# Parent titles (as the releases/ file and `_alternatives/_<Parent>` directory
# names begin) that are not shoot-'em-ups: no autofire tree for them or for
# any clone filed under them. Matched as a prefix of the parent name, so
# "Bombjack Twin (set 1)" and "_Bombjack Twin" both qualify.
EXCLUDED = (
    "Bombjack Twin",
    "Bubble 2000",
    "Dolmen",
    "Mang-Chi",
    "Many Block",
    "Nouryoku Koujou Iinkai",
    "Pop's Pop's",
    "Power Instinct",
    "Puzzle World",
    "Saboten Bombers",
    "Tom Tom Magic",
)

AUTOFIRE_BIT = 0x40  # <switches> byte 2, bit 6 -> autofire_unlock

# The real element sits on its own line; header comments quote the tag
# mid-line (tdragon2, powerins) or with "..." (macross2) and must not match.
SWITCHES_RE = re.compile(
    r'^(\s*<switches default=")([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2})(")',
    re.MULTILINE,
)


def parent_of(rel):
    """Parent title for a releases-relative .mra path."""
    parts = rel.split(os.sep)
    if parts[0] == "_alternatives":
        return parts[1][1:]  # strip the leading underscore
    return os.path.splitext(parts[-1])[0]


def excluded(rel):
    p = parent_of(rel)
    return any(p.startswith(x) for x in EXCLUDED)


def transform(text, rel):
    hits = SWITCHES_RE.findall(text)
    if len(hits) != 1:
        raise SystemExit(f"{rel}: expected exactly one <switches default=\"a,b,c\"> line, found {len(hits)}")
    def repl(m):
        b2 = int(m.group(4), 16) | AUTOFIRE_BIT
        return f"{m.group(1)}{m.group(2)},{m.group(3)},{b2:02X}{m.group(5)}"
    out = SWITCHES_RE.sub(repl, text, count=1)
    note = ("  <!-- autofire_releases/ copy (tools/gen_autofire_mra.py): identical to\n"
            "       releases/ except that <switches> byte 2 has bit 6 set, which unhides\n"
            "       the P1/P2 Autofire options in the core's OSD. -->\n")
    # Put the note right above the element so a diff against releases/ shows one hunk.
    return re.sub(r'^(\s*<switches default=")', lambda m: note + m.group(0), out, count=1, flags=re.MULTILINE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report stale/missing files, write nothing")
    args = ap.parse_args()

    files = []
    for dp, _, fns in os.walk(SRC):
        for fn in fns:
            if fn.endswith(".mra"):
                files.append(os.path.relpath(os.path.join(dp, fn), SRC))
    files.sort()

    wanted = {}
    skipped = []
    for rel in files:
        if excluded(rel):
            skipped.append(rel)
            continue
        with open(os.path.join(SRC, rel), encoding="utf-8") as f:
            wanted[rel] = transform(f.read(), rel)

    if args.check:
        stale = 0
        for rel, text in wanted.items():
            p = os.path.join(DST, rel)
            if not os.path.exists(p) or open(p, encoding="utf-8").read() != text:
                print("STALE  ", rel); stale += 1
        for dp, _, fns in os.walk(DST):
            for fn in fns:
                rel = os.path.relpath(os.path.join(dp, fn), DST)
                if rel not in wanted:
                    print("EXTRA  ", rel); stale += 1
        print(f"{len(wanted)} wanted, {len(skipped)} excluded, {stale} stale/extra")
        sys.exit(1 if stale else 0)

    if os.path.isdir(DST):
        shutil.rmtree(DST)
    for rel, text in wanted.items():
        p = os.path.join(DST, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    print(f"wrote {len(wanted)} .mra into {os.path.relpath(DST, ROOT)}/ ({len(skipped)} excluded):")
    for rel in skipped:
        print("  excluded:", rel)


if __name__ == "__main__":
    main()
