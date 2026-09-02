#!/usr/bin/env python3
"""Compare per-instruction *cycle cost* between an RTL cycle-timestamped
trace and a MAME oracle one — a different question from
sim/compare/oracle_diff.py's own PC-sequence matching (which this project
has used for every Tier 2 CPU verification pass to date, and which is
completely blind to whether each instruction takes the *right number of
clock cycles*). See docs/tier2-system.md's "Cycle-timestamped NMK004
trace tooling" for why this exists.

Both input files are two-column text, one instruction per line:

    <cycles> <PC_hex>

`<cycles>` is a cumulative count since each side's own trace start — the
two sides' cycle-0 references are NOT expected to align (RTL simulation
start vs MAME machine start are unrelated moments), so this tool only
ever compares cycle *deltas* between consecutive matched checkpoints
(i.e. "how many cycles did this one instruction cost"), never absolute
values.

Matching is the same ordered-subsequence walk sim/compare's own PC-only
diff already uses (tolerates the oracle skipping instructions the
candidate trace also executes, e.g. from collapsed loops or a shorter
oracle capture window) — see that tool's own module for the rationale
if replicating it elsewhere.

Usage:
    sim/compare/cyc_diff.py oracle.trace candidate.trace [--max-report N]
"""

import argparse
import sys


def parse(path):
    """Yields (cycles, pc_int) tuples in file order. PC is parsed as hex so
    differing field widths across sources (e.g. MAME's disassembler pads
    TLCS-90 addresses to 5 hex digits, this project's own RTL traces use
    4) never cause a spurious PC mismatch."""
    with open(path) as f:
        for line_no, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise ValueError(f"{path}:{line_no}: expected '<cycles> <PC>', got {line!r}")
            yield int(parts[0]), int(parts[1], 16)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle", help="MAME oracle cycle-trace (sim/oracle/capture_cyc_trace.py)")
    ap.add_argument("candidate", help="RTL cycle-trace (e.g. sim/rtl/mustang/nmk004_cyc.trace)")
    ap.add_argument("--max-report", type=int, default=20, help="max per-instruction mismatches to print (default 20)")
    ap.add_argument("--tolerance", type=int, default=0,
                     help="allowed cycle-delta difference before counting as a mismatch (default 0 = exact)")
    args = ap.parse_args()

    oracle = list(parse(args.oracle))
    candidate = list(parse(args.candidate))

    if len(oracle) < 2 or len(candidate) < 2:
        raise SystemExit("error: need at least 2 instructions on each side to compute deltas")

    # Ordered-subsequence match on PC alone first, to find corresponding
    # candidate indices for each oracle checkpoint.
    j = 0
    matched = []  # list of (oracle_idx, candidate_idx)
    for i, (_, pc) in enumerate(oracle):
        found = False
        while j < len(candidate):
            if candidate[j][1] == pc:
                found = True
                break
            j += 1
        if not found:
            print(f"PC match stopped at oracle checkpoint {i+1} (PC={pc:04X}), not found in remaining candidate trace")
            break
        matched.append((i, j))
        j += 1

    print(f"matched {len(matched)} of {len(oracle)} oracle checkpoints on PC sequence "
          f"as a subsequence of {len(candidate)} candidate trace lines")

    if len(matched) < 2:
        raise SystemExit("error: fewer than 2 PC-matched checkpoints — can't compute any cycle deltas")

    # Now walk consecutive MATCHED pairs and compare cycle deltas.
    mismatches = 0
    reported = 0
    total_oracle_delta = 0
    total_candidate_delta = 0
    first_mismatch_at = None
    for k in range(1, len(matched)):
        oi_prev, ci_prev = matched[k - 1]
        oi, ci = matched[k]
        oracle_delta = oracle[oi][0] - oracle[oi_prev][0]
        candidate_delta = candidate[ci][0] - candidate[ci_prev][0]
        total_oracle_delta += oracle_delta
        total_candidate_delta += candidate_delta
        diff = candidate_delta - oracle_delta
        if abs(diff) > args.tolerance:
            mismatches += 1
            if first_mismatch_at is None:
                first_mismatch_at = k
            if reported < args.max_report:
                print(f"  checkpoint {k}: PC {oracle[oi_prev][1]:04X}->{oracle[oi][1]:04X}: "
                      f"oracle={oracle_delta} candidate={candidate_delta} (diff={diff:+d})")
                reported += 1

    n = len(matched) - 1
    print(f"\n{mismatches}/{n} instruction cycle-costs differ (tolerance={args.tolerance})")
    if first_mismatch_at is not None:
        print(f"first mismatch at matched checkpoint {first_mismatch_at}")
    print(f"total cycles over matched span: oracle={total_oracle_delta} candidate={total_candidate_delta} "
          f"(candidate/oracle ratio={total_candidate_delta / total_oracle_delta:.3f})" if total_oracle_delta else "")


if __name__ == "__main__":
    main()
