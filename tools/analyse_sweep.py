# Off-board analysis of the sweep screenshots.
#   shot A = ~26 s after load (attract), shot B = ~14 s after coin+start
# Pass = both shots exist, A is non-blank and varied, and B differs from A
# (the game responded to input). Anything else is reported, not glossed.
import sys, os, glob
from PIL import Image
import numpy as np
root=sys.argv[1]; manifest=sys.argv[2]
rows=[l.rstrip("\n").split("\t") for l in open(manifest) if l.strip()]
print(f"{'set':13} {'rbf':15} {'PROM':4} {'shots':5} {'lit%':>6} {'colors':>6} {'A→B diff%':>9}  verdict")
bad=[]
for sn,rbf,prom,_ in rows:
    d=os.path.join(root,sn)
    shots=sorted(glob.glob(d+"/*.png"))
    if len(shots)<2:
        print(f"{sn:13} {rbf:15} {prom:4} {len(shots):5} {'-':>6} {'-':>6} {'-':>9}  *** MISSING SHOTS ***")
        bad.append((sn,"missing shots")); continue
    A=np.array(Image.open(shots[0]).convert('RGB'))
    B=np.array(Image.open(shots[-1]).convert('RGB'))
    lit=float((A.sum(2)>0).mean()*100)
    cols=len(np.unique(A.reshape(-1,3),axis=0))
    diff=float(np.any(A!=B,axis=2).mean()*100) if A.shape==B.shape else 100.0
    v=[]
    if lit<1.0: v.append("BLANK")
    if cols<8: v.append("FLAT")
    if diff<0.5: v.append("NO-INPUT-RESPONSE")
    verdict="ok" if not v else "*** "+" ".join(v)+" ***"
    if v: bad.append((sn,",".join(v)))
    print(f"{sn:13} {rbf:15} {prom:4} {len(shots):5} {lit:6.1f} {cols:6d} {diff:9.1f}  {verdict}")
print(f"\n{len(rows)-len(bad)}/{len(rows)} passed the smoke test")
if bad:
    print("needing a look:")
    for s,w in bad: print(f"   {s:14} {w}")
