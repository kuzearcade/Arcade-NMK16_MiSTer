#!/usr/bin/env python3
"""Add the hiscore <rom index="3"> config and <nvram index="4"> to each .mra
that has a MAME hiscore.dat entry.

The index-3 payload is the 16-byte header the MiSTer hiscore.v expects,
followed by one record per hiscore.dat line. We build records in the
CFG_LENGTHWIDTH=2 form the cores are parameterised for:

    4 bytes  address (big-endian, the raw 68000 address from hiscore.dat)
    2 bytes  length
    1 byte   start-value check
    1 byte   end-value check

hiscore.dat shares one entry block across CONSECUTIVE label lines, e.g.
    gunnail:
    gunnailb:
    @:maincpu,program,...
so labels accumulate until the first @ line.
"""
import re, sys, glob, os

# START_WAIT is 0x0C000000 cycles (~5 s at 40 MHz clk_sys), not the ~65k the
# upstream doc's example uses. These boards run a destructive work-RAM test at
# boot; with a short wait the module's start/end byte checks pass on a transient
# test pattern, it writes the saved scores into RAM mid-test, and the game halts
# with "WORK RAM CHECK ERROR" (seen on tdragon2, address 1F743B). Waiting until
# the test is finished is the fix, and it lives in data rather than RTL.
HDR = [0x0C,0x00,0x00,0x00,  # START_WAIT
       0x00,0xFF,            # CHECK_WAIT
       0x00,0x02,            # CHECK_HOLD
       0x00,0x02,            # WRITE_HOLD
       0x00,0x01,            # WRITE_REPEATCOUNT
       0x00,0xFF,            # WRITE_REPEATWAIT
       0x02,                 # ACCESS_PAUSEPAD
       0x00]                 # CHANGEMASK bytes

def load_dat(path):
    out={}; pending=[]; cur=[]
    for ln in open(path,encoding='utf-8',errors='replace'):
        s=ln.strip()
        if not s or s.startswith(';'): continue
        if s.startswith('@'):
            if pending: cur=pending; pending=[]
            for c in cur: out.setdefault(c,[]).append(s)
        elif s.endswith(':'):
            if cur: cur=[]
            pending += [x.strip() for x in s[:-1].split(',') if x.strip()]
    return out

# NMK-24 sweep, 2026-09-16 (post-fix build 20260917): macross2k FROZE on load
# with a dump present while its siblings macross2/macross2g were fine. Its
# hiscore.dat block is identical to theirs except the final record's check
# bytes at 1fd600 -- they use 01,63 and macross2k uses 00,73. With 00,73 the
# module's check never passes, so it retries forever and hammers the CPU with
# pause bursts (the endless CHECK_WAIT loop described in gunnail_core.sv).
#
# Measured on hardware, hiscore ON, dump present, 45s + coin/start:
#   00,73 (dat as written) -> both screenshots byte-identical (FROZEN), twice
#   record dropped          -> game runs
#   01,63 (parent's bytes)  -> game runs
#   hiscore OFF             -> game runs
# So macross2k is given its parent's check bytes.
#
# NOT VERIFIED either way, for macross2k OR for the already-shipping macross2:
# whether that final region's scores actually restore. The saved dumps hold
# 00/54 at that record's first/last byte, which matches neither dat value, so
# the check may simply never pass on either set. That would be benign (no
# restore of that one region) rather than the hang, but it is unconfirmed.
HS_CHECK_OVERRIDE = {
    # setname: {record address: (start, end)}
    'macross2k': {0x1fd600: (0x01, 0x63)},
}

def records(lines,setname=None):
    recs=[]; total=0
    for ln in lines:
        f=ln.split(':',1)[1].split(',')
        if len(f)<6: continue
        addr=int(f[2],16); length=int(f[3],16)
        start=int(f[4],16); end=int(f[5],16)
        ov=HS_CHECK_OVERRIDE.get(setname,{}).get(addr)
        if ov: start,end=ov
        recs.append([(addr>>24)&0xFF,(addr>>16)&0xFF,(addr>>8)&0xFF,addr&0xFF,
                     (length>>8)&0xFF,length&0xFF,start,end])
        total+=length
    return recs,total

def fmt(rows):
    out=[]
    for r in rows: out.append('        '+' '.join(f'{b:02X}' for b in r))
    return '\n'.join(out)

# NMK-24: sets that lock up once a saved dump exists, so they must NOT get a
# <rom index="3"> region. hiscore.v takes the game-RAM port for the whole of
# its compare loop (NMK16_Gunnail.sv holds hs_access high across the pause),
# and on these games that is enough to wedge the running game -- reproduced in
# sim/rtl/gunnail_hs as the 68000 collapsing into a 4-PC loop. Determined by
# measurement, not by reasoning about which boards have a protection MCU: the
# MCU-less hachamfp fails too. See docs/known-issues.md. Remove entries here
# once the arbitration rework lands and the set has been retested on hardware.
HS_EXCLUDE = {
    # EMPTY as of the NMK-24 root-cause fix (pause broke fx68k's enPhi1/enPhi2
    # alternation; see docs/known-issues.md). Every entry that used to live here
    # was measured on bitstreams built BEFORE that fix, so the list carried no
    # information about the fixed cores. Re-populate ONLY from a fresh hardware
    # sweep on post-fix bitstreams, and say which build measured it.
}

def main():
    dat=load_dat(sys.argv[1] if len(sys.argv)>1 else 'mame/plugins/hiscore/hiscore.dat')
    root=os.path.dirname(os.path.abspath(__file__))+'/..'
    n=skip=excl=0
    for p in sorted(glob.glob(root+'/releases/*.mra')+glob.glob(root+'/releases/_alternatives/*/*.mra')):
        t=open(p,encoding='utf-8').read()
        if 'index="3"' in t: continue
        sn=re.search(r'<setname>([^<]+)',t).group(1).strip()
        if sn in HS_EXCLUDE: excl+=1; continue
        if sn not in dat: skip+=1; continue
        recs,total=records(dat[sn],sn)
        if not recs: skip+=1; continue
        blk=('\n  <!-- High scores: MAME hiscore.dat entries for %s, and the\n'
             '       saved dump. See tools/gen_hiscore_mra.py. -->\n'
             '  <rom index="3" md5="none">\n    <part>\n%s\n%s\n    </part>\n  </rom>\n'
             '  <nvram index="4" size="%d"/>\n' % (sn, fmt([HDR]), fmt(recs), total))
        t=t.replace('</misterromdescription>', blk+'</misterromdescription>')
        open(p,'w',encoding='utf-8').write(t); n+=1
    print(f"added hiscore sections to {n} .mra; {skip} have no hiscore.dat entry; "
          f"{excl} skipped as NMK-24 exclusions")

if __name__=='__main__': main()
