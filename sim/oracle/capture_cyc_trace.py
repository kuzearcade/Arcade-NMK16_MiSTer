#!/usr/bin/env python3
"""Capture a cycle-timestamped MAME instruction trace via the debugger's
own `trace` command, for comparing per-instruction *cycle cost* (not just
PC sequence) against an RTL trace — see docs/tier2-system.md's
"Cycle-timestamped NMK004 trace tooling" for why this exists: every prior
Tier 2 CPU verification pass in this project (all eleven
docs/tier2-tlcs90.md verification results, and every oracle checkpoint
match in docs/tier2-system.md) checked instruction *sequence* only, via
plain PC-per-line traces (sim/oracle/trace.lua, sim/rtl/*/tb_*.cpp) that
carry no timing information at all. This tool closes that gap.

How it works: MAME's debugger exposes a read-only `totalcycles` symbol
per focused CPU device (cumulative cycle count since machine start — find
it and other per-device symbols via the debugger's own `symlist`
command). The `trace` command's own `action` parameter (a debugger
command run before each trace line is logged) lets us prepend it via
`tracelog`:

    focus <device>
    trace <out>,<device>,noloop,{tracelog "%d ",totalcycles}

`focus` matters — without it, `totalcycles` in the action resolves
against whatever CPU is currently visible/focused by default (usually
:maincpu), not the CPU actually being traced, silently producing a
constant or wrong prefix rather than an error. `noloop` matters too:
MAME's default loop-collapse behavior inserts human-readable
"(LOOPS FOR N INSTRUCTIONS)" summary lines that break any trace parser
expecting one instruction per line.

Output format: "<cycles> <PC>\\n" per instruction — the exact same
two-column format sim/rtl/mustang/tb_mustang.cpp's own `nmk004_cyc.trace`
uses (there: "<clk_sys_ticks/4> <PC>\\n", since NMK004's own real clock
is clk_sys/4 — see that module's own comment), so the two are directly,
line-for-line comparable via sim/compare/cyc_diff.py.

Caveats (real, found during development, not hypothetical):
  - The two traces' own *absolute* cycle values are NOT expected to
    align (each side's cycle-0 reference is its own simulation/machine
    start, not a shared wall-clock) — compare cycle *deltas* between
    matched PC checkpoints, never absolute values. sim/compare/cyc_diff.py
    already does this.
  - `noloop` traces are large (a tight polling loop that would collapse
    to one summary line under default settings instead logs every single
    iteration) — budget `--seconds-to-run` accordingly; a few real
    seconds already produces hundreds of thousands of instructions for
    an 8MHz CPU.

Usage:
    sim/oracle/capture_cyc_trace.py --game mustang --rompath mame_roms \\
        --device :nmk004:mcu --out sim/oracle/traces/mustang_nmk004_cyc.trace \\
        --seconds-to-run 2
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# MAME trace lines look like "  1234: ld d,$00" (no cycle prefix) or, with
# our tracelog action prepended, "56 001234: ld d,$00". The address field
# width varies by CPU (68000 uses 6 hex digits, TLCS-90 uses 5), so match
# generically on hex digits rather than a fixed width.
TRACE_RE = re.compile(r"^(\d+) ([0-9A-Fa-f]+):")


def build_debugscript(device: str, trace_out: Path, script_path: Path) -> None:
    script_path.write_text(
        f"focus {device}\n"
        f'trace {trace_out},{device},noloop,{{tracelog "%d ",totalcycles}}\n'
        f"go\n"
        f"exit\n"
    )


def run_mame(game: str, rompath: str, script_path: Path, work_dir: Path, seconds_to_run: int) -> None:
    cmd = [
        "mame", game,
        "-rompath", rompath,
        "-video", "none", "-sound", "none", "-nothrottle",
        "-debug", "-debugscript", str(script_path),
        "-seconds_to_run", str(seconds_to_run),
    ]
    env = dict(os.environ)
    env["DISPLAY"] = ""
    result = subprocess.run(cmd, cwd=work_dir, env=env, capture_output=True, text=True,
                             timeout=seconds_to_run * 30 + 60)
    if result.returncode != 0:
        print(f"warning: mame exited with code {result.returncode}", file=sys.stderr)
        print(result.stdout[-2000:], file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)


def reformat(raw_path: Path, out_path: Path) -> int:
    count = 0
    with open(raw_path) as f_in, open(out_path, "w") as f_out:
        for line in f_in:
            m = TRACE_RE.match(line)
            if not m:
                continue  # a stray loop-summary or malformed line — skip, don't fail the whole capture
            cycles, pc = m.group(1), m.group(2).upper()
            f_out.write(f"{cycles} {pc}\n")
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", required=True)
    ap.add_argument("--rompath", required=True)
    ap.add_argument("--device", required=True, help="MAME device tag to trace, e.g. :nmk004:mcu or :maincpu")
    ap.add_argument("--out", required=True, help="output path, two-column '<cycles> <PC>' format")
    ap.add_argument("--seconds-to-run", type=int, default=2, help="emulated seconds budget (default 2)")
    ap.add_argument("--work-dir", default=".", help="directory to run mame in; default cwd")
    args = ap.parse_args()

    work_dir = Path(args.work_dir).resolve()
    out_path = Path(args.out).resolve()
    script_path = work_dir / f".capture_cyc_{args.game}.debugscript"
    raw_path = work_dir / f".capture_cyc_{args.game}.raw.tr"
    raw_path.unlink(missing_ok=True)

    build_debugscript(args.device, raw_path, script_path)
    print(f"[capture_cyc_trace] tracing {args.device} in {args.game}, {args.seconds_to_run}s budget", file=sys.stderr)
    run_mame(args.game, args.rompath, script_path, work_dir, args.seconds_to_run)

    if not raw_path.exists():
        raise SystemExit(f"error: {raw_path} was not created — mame/debugger may have failed to start")
    count = reformat(raw_path, out_path)
    script_path.unlink(missing_ok=True)
    raw_path.unlink(missing_ok=True)
    print(f"[capture_cyc_trace] wrote {count} instructions to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
