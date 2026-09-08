#!/usr/bin/env python3
"""Build rom_fetch_bucket (or rom_fetch_fine) reference $readmemh tables
from a sim/rtl/tdragon2_hw/tb_tdragon2_hw.cpp run's own "BUCKET N XXXX T"
or "FINE N XXXX T" dump lines (see that file's own dbg_bucket_sel_i
loop). Neither output file is ROM-dump-derived (they're just this one
reference run's own live rotate-XOR accumulator state), so both are safe
to commit.

Usage:
    ./sim/rtl/tdragon2_hw/obj_dir/Vtdragon2_hw_top | tee run.log
    tools/mk_fetch_bucket_ref.py run.log \
        --state-out rtl/tdragon2/tdragon2_fetch_bucket_ref.hex \
        --touched-out rtl/tdragon2/tdragon2_fetch_bucket_touched.hex
    tools/mk_fetch_bucket_ref.py run.log --prefix FINE \
        --state-out rtl/tdragon2/tdragon2_fetch_fine_ref.hex \
        --touched-out rtl/tdragon2/tdragon2_fetch_fine_touched.hex
"""

import argparse
import re


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", help="tb_tdragon2_hw run log/output containing the dump lines")
    ap.add_argument("--prefix", default="BUCKET", choices=["BUCKET", "FINE", "WORD"], help="which dump section to parse (default: BUCKET)")
    ap.add_argument("--count", type=int, default=None, help="expected entry count (default: 128, or 16 for --prefix WORD)")
    ap.add_argument("--state-out", required=True)
    ap.add_argument("--touched-out", required=True)
    args = ap.parse_args()

    count = args.count if args.count is not None else (16 if args.prefix == "WORD" else 128)
    state = [None] * count
    touched = [None] * count
    pat = re.compile(rf"^{args.prefix}\s+(\d+)\s+([0-9A-Fa-f]{{4}})\s+([01])\s*$")
    with open(args.log) as f:
        for line in f:
            m = pat.match(line.strip())
            if not m:
                continue
            idx = int(m.group(1))
            state[idx] = m.group(2).lower()
            touched[idx] = m.group(3)

    missing = [i for i, v in enumerate(state) if v is None]
    if missing:
        raise SystemExit(f"error: missing BUCKET lines for indices {missing}")

    with open(args.state_out, "w") as f:
        f.write("\n".join(state) + "\n")
    with open(args.touched_out, "w") as f:
        f.write("\n".join(touched) + "\n")
    print(f"wrote {args.state_out} and {args.touched_out}, {sum(1 for t in touched if t == '1')} of {count} entries touched")


if __name__ == "__main__":
    main()
