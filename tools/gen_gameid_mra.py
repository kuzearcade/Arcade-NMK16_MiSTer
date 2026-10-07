#!/usr/bin/env python3
"""Add the early game id, <rom index="2">, to each .mra (NMK-41).

The Gunnail, Afega and Macross2 cores pick the game -- and with it the
video timing (gunnail_core's 384-px or 256-px line, Many Block's window,
Power Instinct's 320-px line) -- from the <switches> third byte. Main_MiSTer
sends the switches only after every <rom>, so the core ran the load as the
idle-0xFF game and changed its timing when they arrived: the hsync (or the
vsync) moved, and a CRT re-locked at the end of every load. Main_MiSTer
sends each <rom> as the parser closes it, in file order, so a one-byte
<rom index="2"> placed ahead of <rom index="0"> reaches the core before the
ROM. It carries the switches' third byte, bits 5:0 (the game select; bit 6,
the Autofire unlock, stays a switches-only flag).

Raphero's core has one video timing for every set and reads no game id, so
its .mra files are left alone. The step is idempotent: an existing block is
rewritten from the current switches. Run it after the base generators,
gen_hiscore_mra.py and gen_cheats_mra.py, before gen_autofire_mra.py:
    python3 tools/gen_gameid_mra.py
"""
import glob, os, re, sys

RBFS = {'NMK16_Gunnail', 'NMK16_Afega', 'NMK16_Macross2'}
BLOCK = re.compile(r'[ \t]*<!-- Game id \(NMK-41\).*?</rom>\n\n?', re.S)

def block(gid):
    return ('  <!-- Game id (NMK-41): the <switches> third byte, sent ahead of the ROM\n'
            '       so the core starts the load in this game\'s video timing. -->\n'
            f'  <rom index="2" md5="none">\n    <part>{gid:02X}</part>\n  </rom>\n\n')

def main(root):
    changed = 0
    files = sorted(glob.glob(os.path.join(root, '**', '*.mra'), recursive=True))
    for path in files:
        t = open(path, encoding='utf-8').read()
        rbf = re.search(r'<rbf>([^<]*)</rbf>', t)
        if not rbf or rbf.group(1).strip() not in RBFS:
            continue
        sw = re.findall(r'^[ \t]*<switches default="([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2})"', t, re.M)
        if len(sw) != 1:
            sys.exit(f'{path}: expected one three-byte <switches default=...>, found {len(sw)}')
        gid = int(sw[0][2], 16) & 0x3F
        u = BLOCK.sub('', t)
        m = re.search(r'^[ \t]*<rom index="0"', u, re.M)
        if not m:
            sys.exit(f'{path}: no <rom index="0">')
        at = m.start()
        # keep a comment that introduces the ROM next to it: go above it
        c = re.search(r'^[ \t]*<!--(?:(?!<!--).)*?-->\n\Z', u[:at], re.M | re.S)
        if c:
            at = c.start()
        u = u[:at] + block(gid) + u[at:]
        if u != t:
            open(path, 'w', encoding='utf-8').write(u)
            changed += 1
    print(f'{changed} of {len(files)} .mra files written')

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'releases')
