#!/usr/bin/env python3
"""Compare an RTL-simulation trace against a MAME oracle trace.

Both files use the same nmktrace v1 text format (see docs/sim-harness.md and
sim/oracle/trace.lua's header comment for the authoritative grammar):

    # nmktrace v1 game=<name> clock_hz=<int> cpu=<tag> space=<name> addr=<lo>-<hi> screen=<tag>
    B <cycle> <r|w> <addr_hex> <data_hex> <mask_hex>
    F <cycle> <frame_num> <crc32_hex>
    R <cycle> <reg_name> <value_hex>

The RTL side (a Verilator testbench, see sim/rtl/) is expected to emit the
identical grammar so this one tool serves both "does my DUT match the
oracle" and, just as usefully during bring-up, "does my own tracer's output
stay byte-for-byte reproducible run to run."

Comparison is a straight ordered walk of both event streams (arcade hardware
here is causally deterministic — same inputs, same cycle-accurate trace), with
an optional --cycle-tolerance for early bring-up before a DUT's timing is
proven cycle-exact against MAME's scheduler.
"""

import argparse
import sys
from dataclasses import dataclass


@dataclass
class Event:
    kind: str          # 'B', 'F', or 'R'
    cycle: int
    line_no: int
    fields: tuple


def parse_trace(path):
    """Yields Event objects in file order. Raises ValueError on malformed lines."""
    with open(path, "r") as f:
        for line_no, raw in enumerate(f, start=1):
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            kind = parts[0]
            if kind == "B":
                # B <cycle> <r|w> <addr_hex> <data_hex> <mask_hex>
                if len(parts) != 6:
                    raise ValueError(f"{path}:{line_no}: malformed B line: {line!r}")
                cycle = int(parts[1])
                fields = (parts[2], int(parts[3], 16), int(parts[4], 16), int(parts[5], 16))
                yield Event("B", cycle, line_no, fields)
            elif kind == "F":
                # F <cycle> <frame_num> <crc32_hex>
                if len(parts) != 4:
                    raise ValueError(f"{path}:{line_no}: malformed F line: {line!r}")
                cycle = int(parts[1])
                fields = (int(parts[2]), int(parts[3], 16))
                yield Event("F", cycle, line_no, fields)
            elif kind == "R":
                # R <cycle> <reg_name> <value_hex>
                if len(parts) != 4:
                    raise ValueError(f"{path}:{line_no}: malformed R line: {line!r}")
                cycle = int(parts[1])
                fields = (parts[2], int(parts[3], 16))
                yield Event("R", cycle, line_no, fields)
            else:
                raise ValueError(f"{path}:{line_no}: unknown event kind {kind!r}: {line!r}")


def fields_equal(a: Event, b: Event) -> bool:
    """Compare everything except cycle timestamp."""
    if a.kind != b.kind:
        return False
    if a.kind == "B":
        # compare op + addr + data; mask only if both sides recorded it
        if a.fields[:3] != b.fields[:3]:
            return False
        if len(a.fields) == 4 and len(b.fields) == 4 and a.fields[3] != b.fields[3]:
            return False
        return True
    # F and R: compare full field tuple exactly
    return a.fields == b.fields


def events_equal(a: Event, b: Event, cycle_tolerance: int) -> bool:
    if abs(a.cycle - b.cycle) > cycle_tolerance:
        return False
    return fields_equal(a, b)


def describe(ev: Event) -> str:
    if ev.kind == "B":
        op, addr, data = ev.fields[0], ev.fields[1], ev.fields[2]
        mask = f" mask={ev.fields[3]:x}" if len(ev.fields) == 4 else ""
        return f"cycle={ev.cycle} BUS {op} addr={addr:x} data={data:x}{mask}"
    if ev.kind == "F":
        frame, crc = ev.fields
        return f"cycle={ev.cycle} FRAME #{frame} crc32={crc:08x}"
    name, value = ev.fields
    return f"cycle={ev.cycle} REG {name}={value:x}"


def compare(oracle_path: str, candidate_path: str, cycle_tolerance: int, max_report: int) -> int:
    oracle_events = list(parse_trace(oracle_path))
    candidate_events = list(parse_trace(candidate_path))

    counts_o = {"B": 0, "F": 0, "R": 0}
    counts_c = {"B": 0, "F": 0, "R": 0}
    for e in oracle_events:
        counts_o[e.kind] += 1
    for e in candidate_events:
        counts_c[e.kind] += 1

    print(f"oracle:    {oracle_path}  ({len(oracle_events)} events: "
          f"B={counts_o['B']} F={counts_o['F']} R={counts_o['R']})")
    print(f"candidate: {candidate_path}  ({len(candidate_events)} events: "
          f"B={counts_c['B']} F={counts_c['F']} R={counts_c['R']})")

    mismatches = 0
    n = min(len(oracle_events), len(candidate_events))
    first_divergence_index = None
    for i in range(n):
        if not events_equal(oracle_events[i], candidate_events[i], cycle_tolerance):
            if first_divergence_index is None:
                first_divergence_index = i
            mismatches += 1
            if mismatches <= max_report:
                print(f"\nMISMATCH at event #{i}:")
                print(f"  oracle    ({oracle_path}:{oracle_events[i].line_no}): {describe(oracle_events[i])}")
                print(f"  candidate ({candidate_path}:{candidate_events[i].line_no}): {describe(candidate_events[i])}")

    if len(oracle_events) != len(candidate_events):
        print(f"\nLENGTH MISMATCH: oracle has {len(oracle_events)} events, "
              f"candidate has {len(candidate_events)} (compared first {n})")
        mismatches += abs(len(oracle_events) - len(candidate_events))

    # Diagnostic: if every event's non-cycle fields match but cycle_tolerance
    # was too tight to accept the timestamps, check for (and report) a
    # constant offset — a fixed startup/reset latency difference is a very
    # different, much less concerning finding than genuinely divergent
    # timing, and is worth calling out explicitly rather than just failing.
    if mismatches > 0 and cycle_tolerance == 0:
        deltas = set()
        all_fields_match = True
        for i in range(n):
            if not fields_equal(oracle_events[i], candidate_events[i]):
                all_fields_match = False
                break
            deltas.add(candidate_events[i].cycle - oracle_events[i].cycle)
        if all_fields_match and len(deltas) == 1:
            offset = deltas.pop()
            print(f"\nDIAGNOSTIC: all {n} events match exactly except for a "
                  f"CONSTANT {offset:+d}-cycle offset on every event (likely a fixed "
                  f"startup/reset latency difference, not a functional divergence) — "
                  f"re-run with --cycle-tolerance {abs(offset)} to confirm.")

    if mismatches == 0:
        print(f"\nMATCH: all {n} events identical (cycle_tolerance={cycle_tolerance})")
        return 0

    if first_divergence_index is not None:
        print(f"\nFAIL: {mismatches} mismatching/extra events "
              f"(first divergence at event #{first_divergence_index})")
    else:
        print(f"\nFAIL: all {n} compared events matched, but trace lengths differ "
              f"(one side has {mismatches} extra trailing events)")
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle", help="MAME oracle trace file (from sim/oracle/trace.lua)")
    ap.add_argument("candidate", help="RTL simulation trace file to check against the oracle")
    ap.add_argument("--cycle-tolerance", type=int, default=0,
                     help="allow this many cycles of timestamp skew per event before flagging a mismatch (default: 0, exact)")
    ap.add_argument("--max-report", type=int, default=20,
                     help="stop printing individual mismatches after this many (default: 20)")
    args = ap.parse_args()

    try:
        sys.exit(compare(args.oracle, args.candidate, args.cycle_tolerance, args.max_report))
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
