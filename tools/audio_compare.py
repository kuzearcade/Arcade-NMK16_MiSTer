#!/usr/bin/env python3
"""Compare a core's audio dump with MAME's -wavwrite output.

    tools/audio_compare.py <mame.wav> <core.raw|core.wav> [--offset-search S]

The core file is raw signed 16-bit mono at 48 kHz (TB_DUMP_AUDIO from
the sim testbenches, or arecord output converted to mono) or a .wav.
Both are cut to the common length, the best time alignment is found by
cross-correlating band energies (within +-S seconds, default 1.0), and
per-band energy correlation plus an overall similarity score are printed
— the same spectral-envelope comparison used for the tdragon2/macross2
sound bring-up (docs/hw-bringup.md).
"""
import sys, wave, struct
import numpy as np

def load(path):
    if path.endswith(".wav"):
        with wave.open(path, "rb") as w:
            n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
            data = np.frombuffer(w.readframes(n), dtype=np.int16).reshape(-1, ch).astype(np.float64)
            return data.mean(axis=1), sr
    data = np.fromfile(path, dtype=np.int16).astype(np.float64)
    return data, 48000

def bands(x, sr, frame=0.05, nb=24):
    hop = int(sr * frame)
    nfr = len(x) // hop
    spec = np.zeros((nfr, nb))
    edges = np.geomspace(60, sr / 2 - 1, nb + 1)
    freqs = np.fft.rfftfreq(hop, 1 / sr)
    for i in range(nfr):
        seg = x[i * hop:(i + 1) * hop] * np.hanning(hop)
        p = np.abs(np.fft.rfft(seg)) ** 2
        for b in range(nb):
            m = (freqs >= edges[b]) & (freqs < edges[b + 1])
            spec[i, b] = np.log10(p[m].sum() + 1e3)
    return spec, hop

def main():
    a, sra = load(sys.argv[1]); b, srb = load(sys.argv[2])
    search = 1.0
    if "--offset-search" in sys.argv: search = float(sys.argv[sys.argv.index("--offset-search") + 1])
    assert sra == srb, (sra, srb)
    sr = sra
    sa, hop = bands(a, sr); sb, _ = bands(b, sr)
    ea = sa.sum(axis=1) - np.median(sa.sum(axis=1)); eb = sb.sum(axis=1) - np.median(sb.sum(axis=1))
    maxlag = int(search * sr / hop)
    best, bestlag = -1e9, 0
    for lag in range(-maxlag, maxlag + 1):
        if lag >= 0: x, y = ea[lag:], eb[:len(ea) - lag]
        else:        x, y = ea[:lag], eb[-lag:]
        n = min(len(x), len(y))
        if n < 20: continue
        c = np.dot(x[:n], y[:n]) / (np.linalg.norm(x[:n]) * np.linalg.norm(y[:n]) + 1e-9)
        if c > best: best, bestlag = c, lag
    if bestlag >= 0: A, B = sa[bestlag:], sb
    else:            A, B = sa, sb[-bestlag:]
    n = min(len(A), len(B)); A, B = A[:n], B[:n]
    print(f"aligned: core lags MAME by {bestlag * hop / sr:+.3f} s, {n * hop / sr:.1f} s compared, envelope corr {best:.3f}")
    corr = [np.corrcoef(A[:, k], B[:, k])[0, 1] for k in range(A.shape[1])]
    diff = (A - B).mean(axis=0) * 10  # dB
    print("band  corr   level(MAME-core dB)")
    edges = np.geomspace(60, sr / 2 - 1, A.shape[1] + 1)
    for k in range(A.shape[1]):
        print(f"{edges[k]:6.0f}-{edges[k+1]:5.0f}Hz  {corr[k]:+.2f}  {diff[k]:+6.1f}")
    print(f"mean band corr {np.nanmean(corr):.3f}, mean level diff {diff.mean():+.1f} dB")
    ra = 20 * np.log10(np.sqrt((a ** 2).mean()) + 1); rb = 20 * np.log10(np.sqrt((b ** 2).mean()) + 1)
    print(f"RMS: MAME {ra:.1f} dBFS-ish, core {rb:.1f}")

if __name__ == "__main__":
    main()
