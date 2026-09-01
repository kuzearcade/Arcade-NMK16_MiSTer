#!/usr/bin/env python3
"""Capture a MAME oracle write-trace via the debugger's watchpoint
mechanism instead of the Lua bus-tap (sim/oracle/trace.lua) — use this
whenever the Lua tap is suspected of missing events, since it has a
confirmed, reproducible blind spot over at least part of MAME's
plain-.ram()-declared mainram region (see docs/tier1-bjtwin.md's
"Sprite rendering verification" section for the full story: the Lua tap
showed zero writes to a region MAME's own debugger then proved, with a
watchpoint hit, was genuinely written).

How it works: generates a MAME .debugscript that sets a write watchpoint
over the requested address range with an action that logs
"W <addr>=<data>" and auto-continues (`printf "W %04X=%04X\n",wpaddr,wpdata ; g`),
runs MAME with -debug -debuglog (which writes the debugger console,
including our printf output, to debug.log in the working directory),
then parses that log into the same nmktrace v1 'B' line grammar
sim/oracle/trace.lua and sim/compare/{oracle_diff,state_diff}.py use —
so the output of this tool is a drop-in alternative oracle source for
those comparison tools.

Caveats (real, not hypothetical — hit both during development):
  - Timestamps are a synthetic incrementing counter, NOT a real cycle
    count (MAME's watchpoint-hit context does not expose one to printf
    the way frame/register snapshots do). Fine for sim/compare/state_diff.py
    (which only replays events in order, ignoring the cycle field) but
    NOT valid input to sim/compare/oracle_diff.py's cycle-tolerance
    matching against an RTL trace's real cycle timestamps.
  - Every captured event is logged as a full 16-bit word write
    (mask=ffff) — wpaddr/wpdata don't expose the actual UDS/LDS byte
    lanes, only that the watchpoint's width (as given to `wpset`) was
    hit. Every write observed in this driver so far has been
    word-granularity, but a region with real byte-writes would be
    mis-captured as word-writes by this tool. Not yet needed for
    anything captured with it; flag if that changes.
  - A watchpoint over a *written-to* address that MAME's own memory
    system re-checks on every subsequent access to that address (e.g. a
    read-modify-write, or code that re-reads a location right after
    writing it) can generate more log lines than expected; this tool
    only ever emits 'B ... w ...' lines (never 'r'), so reads don't
    pollute the output, but don't assume line count == write count from
    debug.log alone if you're eyeballing it — always go through this
    parser.

Usage:
    sim/oracle/debug_capture.py --game cactus --rompath mame_roms \
        --addr-lo 0xf8000 --addr-hi 0xf8fff --stop-pc 0xaa66 \
        --out sim/oracle/traces/cactus_spriteram_debug.trace
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

WATCH_RE = re.compile(r"^W ([0-9A-Fa-f]+)=([0-9A-Fa-f]+)$")


def build_debugscript(addr_lo: int, addr_hi: int, stop_pc: int, script_path: Path) -> None:
    length = addr_hi - addr_lo + 1
    script_path.write_text(
        f"wpset 0x{addr_lo:x},0x{length:x},w,1,{{printf \"W %04X=%04X\\n\",wpaddr,wpdata ; g}}\n"
        f"bp 0x{stop_pc:x}\n"
        f"go\n"
        f"exit\n"
    )


def run_mame(game: str, rompath: str, script_path: Path, work_dir: Path, seconds_to_run: int) -> Path:
    debug_log = work_dir / "debug.log"
    debug_log.unlink(missing_ok=True)
    cmd = [
        "mame", game,
        "-rompath", rompath,
        "-video", "none", "-sound", "none", "-nothrottle",
        "-debug", "-debuglog",
        "-debugscript", str(script_path),
        "-seconds_to_run", str(seconds_to_run),
    ]
    env = dict(os.environ)
    env["DISPLAY"] = ""
    result = subprocess.run(cmd, cwd=work_dir, env=env, capture_output=True, text=True, timeout=seconds_to_run * 20 + 30)
    if result.returncode != 0:
        print(f"warning: mame exited with code {result.returncode}", file=sys.stderr)
        print(result.stdout[-2000:], file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)
    if not debug_log.exists():
        raise SystemExit(f"error: {debug_log} was not created — mame/debugger may have failed to start")
    return debug_log


def parse_and_write(debug_log: Path, out_path: Path, game: str) -> int:
    count = 0
    with open(debug_log) as f_in, open(out_path, "w") as f_out:
        f_out.write(f"# nmktrace v1 game={game} clock_hz=0 cpu=:maincpu space=program addr=debugger-watchpoint screen=- "
                     f"(cycle field is a synthetic event counter, NOT a real cycle count — see sim/oracle/debug_capture.py)\n")
        for line in f_in:
            m = WATCH_RE.match(line.strip())
            if not m:
                continue
            addr = int(m.group(1), 16)
            data = int(m.group(2), 16)
            f_out.write(f"B {count} w {addr:x} {data:x} ffff\n")
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", required=True)
    ap.add_argument("--rompath", required=True)
    ap.add_argument("--addr-lo", required=True, type=lambda s: int(s, 0))
    ap.add_argument("--addr-hi", required=True, type=lambda s: int(s, 0))
    ap.add_argument("--stop-pc", required=True, type=lambda s: int(s, 0),
                     help="breakpoint address known to be reached after the region of interest, so the capture has a definite end")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds-to-run", type=int, default=5, help="emulated seconds budget (default 5)")
    ap.add_argument("--work-dir", default=".", help="directory to run mame in (debug.log lands here); default cwd")
    args = ap.parse_args()

    work_dir = Path(args.work_dir).resolve()
    script_path = work_dir / f".debug_capture_{args.game}.debugscript"
    build_debugscript(args.addr_lo, args.addr_hi, args.stop_pc, script_path)

    print(f"[debug_capture] range 0x{args.addr_lo:x}-0x{args.addr_hi:x}, stop at PC=0x{args.stop_pc:x}", file=sys.stderr)
    debug_log = run_mame(args.game, args.rompath, script_path, work_dir, args.seconds_to_run)
    count = parse_and_write(debug_log, Path(args.out), args.game)
    script_path.unlink(missing_ok=True)
    print(f"[debug_capture] wrote {count} write events to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
