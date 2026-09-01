#!/usr/bin/env python3
"""Compare final memory state reconstructed from two nmktrace bus-write
traces, instead of comparing rendered frame pixels — sidesteps the video
render FSM's phase-alignment gap (see docs/tier1-bjtwin.md "Known
architecture gap") by checking the CPU-bus-driven RAM regions (palette,
tilemap VRAM) directly, which don't depend on real-time raster sync at
all: replaying every 'B ... w ...' event in order for a given address
range gives the exact final word value at each address, independent of
timing.

Not valid for device-internal state that never crosses the CPU bus (e.g.
sprite_dma()'s buffer copy in nmk16_v.cpp, which is a raw C++ memory
copy — see docs/tier1-bjtwin.md's note on this) — only use for regions
the CPU itself writes.

Usage:
    sim/compare/state_diff.py oracle.trace candidate.trace \
        --addr-lo 0x88000 --addr-hi 0x887ff
"""

import argparse
import sys


def replay(path, addr_lo, addr_hi):
    """Returns {word_addr: last_written_value} for writes in [addr_lo, addr_hi]."""
    state = {}
    write_count = 0
    with open(path) as f:
        for line in f:
            if not line.startswith("B "):
                continue
            parts = line.split()
            if len(parts) < 6:
                continue  # truncated line (e.g. a trace cut off mid-write by a timeout)
            op, addr_s, data_s, mask_s = parts[2], parts[3], parts[4], parts[5]
            if op != "w":
                continue
            addr = int(addr_s, 16)
            if not (addr_lo <= addr <= addr_hi):
                continue
            data = int(data_s, 16)
            mask = int(mask_s, 16)
            write_count += 1
            prev = state.get(addr, 0)
            # apply only the masked bytes, like real hardware byte enables
            new = (prev & ~mask) | (data & mask)
            state[addr] = new & 0xFFFF
    return state, write_count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle")
    ap.add_argument("candidate")
    ap.add_argument("--addr-lo", required=True, type=lambda s: int(s, 0))
    ap.add_argument("--addr-hi", required=True, type=lambda s: int(s, 0))
    ap.add_argument("--max-report", type=int, default=20)
    args = ap.parse_args()

    oracle_state, oracle_writes = replay(args.oracle, args.addr_lo, args.addr_hi)
    cand_state, cand_writes = replay(args.candidate, args.addr_lo, args.addr_hi)

    print(f"oracle:    {args.oracle}  ({oracle_writes} writes, {len(oracle_state)} unique addresses)")
    print(f"candidate: {args.candidate}  ({cand_writes} writes, {len(cand_state)} unique addresses)")

    all_addrs = sorted(set(oracle_state) | set(cand_state))
    mismatches = 0
    for addr in all_addrs:
        ov = oracle_state.get(addr)
        cv = cand_state.get(addr)
        if ov != cv:
            mismatches += 1
            if mismatches <= args.max_report:
                ov_s = "MISSING" if ov is None else f"{ov:04x}"
                cv_s = "MISSING" if cv is None else f"{cv:04x}"
                print(f"  MISMATCH addr={addr:06x}: oracle={ov_s} candidate={cv_s}")

    if mismatches == 0:
        print(f"\nMATCH: all {len(all_addrs)} addresses identical final state")
        sys.exit(0)
    else:
        print(f"\nFAIL: {mismatches}/{len(all_addrs)} addresses differ")
        sys.exit(1)


if __name__ == "__main__":
    main()
