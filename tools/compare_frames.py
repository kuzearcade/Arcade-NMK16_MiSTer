#!/usr/bin/env python3
"""Match hardware-sim frame dumps against reference-sim frame dumps.
For every STEP-th hardware frame, find the reference frame (within a
+-WINDOW search around the same index) with the fewest differing pixels
and print the lag and the pixel count. A run of "0 px" lines at a constant
lag means the two sims render identically, just offset in time.
Usage: compare_frames.py <hw_glob> <ref_glob> [STEP=10] [WINDOW=40]"""
import sys, glob, re, numpy as np

def load(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6'
        w, h = map(int, f.readline().split())
        f.readline()
        return np.frombuffer(f.read(), np.uint8).reshape(h, w, 3)

def index(pattern):
    d = {}
    for p in glob.glob(pattern):
        m = re.search(r'(\d+)\.ppm$', p)
        if m:
            d[int(m.group(1))] = p
    return d

hw, ref = index(sys.argv[1]), index(sys.argv[2])
step = int(sys.argv[3]) if len(sys.argv) > 3 else 10
win = int(sys.argv[4]) if len(sys.argv) > 4 else 40
cache = {}
def R(i):
    if i not in cache:
        cache[i] = load(ref[i])
    return cache[i]
exact = 0
total = 0
for n in sorted(hw):
    if n % step:
        continue
    a = load(hw[n])
    best = None
    for i in range(max(0, n - win), n + win + 1):
        if i in ref:
            b = R(i)
            if b.shape != a.shape:
                continue
            d = int((a != b).any(axis=2).sum())
            if best is None or d < best[0]:
                best = (d, i)
    if best is None:
        continue
    total += 1
    exact += best[0] == 0
    print("hw %4d -> ref %4d (lag %+3d) %6d px" % (n, best[1], best[1] - n, best[0]))
print("exact matches: %d of %d" % (exact, total))
