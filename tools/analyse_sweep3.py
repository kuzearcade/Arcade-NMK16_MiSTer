# Off-board analysis of a three-shot hardware sweep (tools/mister_sweep3 layout):
#   shot A = ~45 s after load (attract), coin x2 + start,
#   shot B = +12 s (game start), shot C = +22 s (gameplay).
# Pass = three shots exist, A is non-blank and varied, B differs from A (the
# game responded to coin+start) and B or C differs from the attract frame by a
# margin that a fade or a cursor blink cannot produce. B->C is reported so a
# reviewer can see whether the game is animating in play; it is NOT a pass
# criterion, because several stage intros hold a static frame for >10 s.
# Anything short of that is reported by name, never glossed.
import sys, os, glob, shutil
from PIL import Image
import numpy as np

root, manifest = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else None
rows = [l.rstrip("\n").split("\t") for l in open(manifest) if l.strip()]

def load(p):
    return np.array(Image.open(p).convert('RGB'))

def diff(a, b):
    return float(np.any(a != b, axis=2).mean() * 100) if a.shape == b.shape else 100.0

print(f"{'set':13} {'rbf':15} {'shots':5} {'A lit%':>6} {'A cols':>6} {'A→B%':>6} {'A→C%':>6} {'B→C%':>6}  verdict")
bad = []
for sn, rbf, _ in rows:
    d = os.path.join(root, sn)
    shots = sorted(glob.glob(d + "/*.png"))
    if out and shots:
        os.makedirs(os.path.join(out, sn), exist_ok=True)
        for tag, p in zip("ABC", shots):
            shutil.copy2(p, os.path.join(out, sn, f"{sn}_{tag}_{os.path.basename(p)}"))
    if len(shots) < 3:
        print(f"{sn:13} {rbf:15} {len(shots):5} {'-':>6} {'-':>6} {'-':>6} {'-':>6} {'-':>6}  *** MISSING SHOTS ({len(shots)}/3) ***")
        bad.append((sn, f"missing shots {len(shots)}/3")); continue
    A, B, C = (load(p) for p in shots[:3])
    lit = float((A.sum(2) > 0).mean() * 100)
    cols = len(np.unique(A.reshape(-1, 3), axis=0))
    ab, ac, bc = diff(A, B), diff(A, C), diff(B, C)
    v = []
    if lit < 1.0: v.append("BLANK-ATTRACT")
    if cols < 8: v.append("FLAT-ATTRACT")
    if ab < 0.5 and ac < 0.5: v.append("NO-INPUT-RESPONSE")
    elif max(ab, ac) < 5.0: v.append("WEAK-RESPONSE")
    verdict = "ok" if not v else "*** " + " ".join(v) + " ***"
    if v: bad.append((sn, ",".join(v)))
    print(f"{sn:13} {rbf:15} {len(shots):5} {lit:6.1f} {cols:6d} {ab:6.1f} {ac:6.1f} {bc:6.1f}  {verdict}")
print(f"\n{len(rows) - len(bad)}/{len(rows)} passed (loaded, attract drawn, responded to coin+start)")
if bad:
    print("needing a look:")
    for s, w in bad: print(f"   {s:14} {w}")
