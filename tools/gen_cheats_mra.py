#!/usr/bin/env python3
"""Add a <rom index="5"> cheat table to each .mra, from Pugsy's MAME cheat XML.

MiSTer's CONF_STR is compiled into the core and shared by every game on that
.rbf, so a per-game menu of cheat NAMES is not expressible. Instead the core
carries seven fixed, well-known slots and each .mra supplies that game's
addresses for them. Slots a game has no cheat for are hidden in the OSD via
status_menumask.

Pugsy writes the same poke in several forms -- maincpu.pb@ (program byte),
maincpu.rb@ (direct byte) and maincpu.pw@ (program word). They all mean "write
this value at this 68000 address", and accepting all three lifts coverage from
52 to 82 of our 94 sets. Cheats with a <parameter> (user-selected value) are
skipped: they need UI the OSD cannot give them.

Table layout, big-endian, 8 bytes per record, 2 records per slot, 7 slots:
    1 byte   count for this slot (0..2)
    1 byte   reserved
    then 2 x { 3 bytes address, 1 byte size (0=byte,1=word), 2 bytes value }
"""
import re, glob, os, sys

SLOTS = ["Infinite Credits", "P1 Invincibility", "P2 Invincibility",
         "P1 Infinite Lives", "P2 Infinite Lives",
         "P1 Infinite Bombs", "P2 Infinite Bombs"]
MAXACT = 2
ACT = re.compile(r'<action(?:\s+condition="[^"]*")?\s*>'
                 r'maincpu\.([pr])([bw])@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)</action>')

def parse(path):
    t = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'<cheat desc="([^"]*)"\s*>(.*?)</cheat>', t, re.S):
        d, body = m.group(1).strip(), m.group(2)
        if d not in SLOTS or '<parameter' in body or d in out:
            continue
        acts = ACT.findall(body)[:MAXACT]
        if acts:
            out[d] = [(int(a, 16), 1 if sz == 'w' else 0, int(v, 16)) for _, sz, a, v in acts]
    return out

def table(found):
    rows = []
    for name in SLOTS:
        acts = found.get(name, [])
        rec = [len(acts), 0]
        for i in range(MAXACT):
            if i < len(acts):
                a, sz, v = acts[i]
                rec += [(a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF, sz, (v >> 8) & 0xFF, v & 0xFF]
            else:
                rec += [0, 0, 0, 0, 0, 0]
        rows.append(rec)
    return rows

def main():
    D = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/Downloads/cheat0279/cheat')
    root = os.path.dirname(os.path.abspath(__file__)) + '/..'
    added = skipped = 0
    for p in sorted(glob.glob(root + '/releases/*.mra') + glob.glob(root + '/releases/_alternatives/*/*.mra')):
        t = open(p, encoding='utf-8').read()
        if 'index="5"' in t:
            continue
        sn = re.search(r'<setname>([^<]+)', t).group(1).strip()
        src = f'{D}/{sn}.xml'
        if not os.path.exists(src):
            skipped += 1; continue
        found = parse(src)
        if not found:
            skipped += 1; continue
        rows = table(found)
        body = '\n'.join('        ' + ' '.join(f'{b:02X}' for b in r) for r in rows)
        names = ', '.join(n for n in SLOTS if n in found)
        blk = (f'\n  <!-- Cheats (Pugsy\'s MAME cheat database). Slots in fixed order:\n'
               f'       {", ".join(SLOTS)}.\n'
               f'       This set provides: {names}. See tools/gen_cheats_mra.py. -->\n'
               f'  <rom index="5" md5="none">\n    <part>\n{body}\n    </part>\n  </rom>\n')
        open(p, 'w', encoding='utf-8').write(t.replace('</misterromdescription>', blk + '</misterromdescription>'))
        added += 1
    print(f"added cheat tables to {added} .mra; {skipped} had no usable cheats")

if __name__ == '__main__':
    main()
