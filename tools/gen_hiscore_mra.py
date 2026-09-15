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

def records(lines):
    recs=[]; total=0
    for ln in lines:
        f=ln.split(':',1)[1].split(',')
        if len(f)<6: continue
        addr=int(f[2],16); length=int(f[3],16)
        start=int(f[4],16); end=int(f[5],16)
        recs.append([(addr>>24)&0xFF,(addr>>16)&0xFF,(addr>>8)&0xFF,addr&0xFF,
                     (length>>8)&0xFF,length&0xFF,start,end])
        total+=length
    return recs,total

def fmt(rows):
    out=[]
    for r in rows: out.append('        '+' '.join(f'{b:02X}' for b in r))
    return '\n'.join(out)

def main():
    dat=load_dat(sys.argv[1] if len(sys.argv)>1 else 'mame/plugins/hiscore/hiscore.dat')
    root=os.path.dirname(os.path.abspath(__file__))+'/..'
    n=skip=0
    for p in sorted(glob.glob(root+'/releases/*.mra')+glob.glob(root+'/releases/_alternatives/*/*.mra')):
        t=open(p,encoding='utf-8').read()
        if 'index="3"' in t: continue
        sn=re.search(r'<setname>([^<]+)',t).group(1).strip()
        if sn not in dat: skip+=1; continue
        recs,total=records(dat[sn])
        if not recs: skip+=1; continue
        blk=('\n  <!-- High scores: MAME hiscore.dat entries for %s, and the\n'
             '       saved dump. See tools/gen_hiscore_mra.py. -->\n'
             '  <rom index="3" md5="none">\n    <part>\n%s\n%s\n    </part>\n  </rom>\n'
             '  <nvram index="4" size="%d"/>\n' % (sn, fmt([HDR]), fmt(recs), total))
        t=t.replace('</misterromdescription>', blk+'</misterromdescription>')
        open(p,'w',encoding='utf-8').write(t); n+=1
    print(f"added hiscore sections to {n} .mra; {skip} have no hiscore.dat entry")

if __name__=='__main__': main()
