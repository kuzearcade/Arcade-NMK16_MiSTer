#!/usr/bin/env python3
"""Capture a register-state-timestamped MAME instruction trace — a
superset of sim/oracle/capture_cyc_trace.py's "<cycles> <PC>" format,
adding the CPU's own A/F/BC/DE/HL/IX/IY/SP at every instruction boundary,
for hunting a *state* divergence (not just an instruction-sequence or
per-instruction-cycle-cost one) against an RTL trace — see
docs/hw-bringup.md's GunNail sequencer-divergence investigation: PC
sequence and per-instruction cycle cost were both directly verified
clean there, leaving register/RAM state as the only remaining candidate
for where a divergence enters.

Same mechanism as capture_cyc_trace.py (MAME debugger `trace` command,
`noloop`, an `action` that prepends fields via `tracelog`), just with a
longer action string reading the focused device's own named debugger
state symbols (added via state_add() in the device's own device_start()
— find a device's own symbol names via `symlist` after `focus <device>`
if porting this to a different CPU).

**A real gotcha found getting this working**: `tlcs90_device::device_start()`
registers the accumulator as `state_add(T90_A, "~A", ...)` — a
TILDE-PREFIXED name — and does NOT register a standalone flags ("F")
state at all, only the combined 16-bit `"AF"`. The debugger's plain
*expression evaluator* (which `tracelog`'s own arguments are, unlike the
register-window display these state names are more commonly seen in)
has no way to reference a tilde-prefixed symbol — `~a` parses as
"bitwise NOT of the expression `a`", not "the state named ~A" — and a
bare `a`/`f` (no tilde) silently resolves to *something* (not an error,
not the accumulator either) that happened to evaluate to a constant
0x0A/0x0F for an entire 16-second, 10M-instruction capture, which is
what made this look at first like a genuine, glaring MAME-vs-RTL
register divergence rather than a symbol-name bug in the capture
script. Confirmed by checking how many *distinct* values each field
took across a real capture: `hl`/`bc`/`af` (correct symbol names, all
registered without a tilde) show hundreds to thousands of distinct
values as expected; a bare `a`/`f` showed exactly one, for the entire
run. Fix: capture the combined 16-bit `af` (a real, working symbol) and
split it into A (high byte) / F (low byte) in `reformat()` below, never
ask the debugger for `a`/`f`/`~a` directly.

Output format: "<cycles> <PC> A=<a> F=<f> BC=<bc> DE=<de> HL=<hl>
IX=<ix> IY=<iy> SP=<sp>\\n" — deliberately matching the field names and
hex widths sim/rtl/gunnail/tb_gunnail.cpp's own TB_NMK004_REGS output
uses, so the two are directly line-diffable without reformatting. Note
the raw MAME line itself puts the register fields BEFORE the PC (the
`tracelog` action's own output prepends the normal "<PC>: <disasm>"
trace line, it doesn't insert into it) — this script's `reformat()`
re-orders them to PC-first on the way out.

Usage:
    sim/oracle/capture_reg_trace.py --game gunnail --rompath mame_roms \\
        --device :nmk004:mcu --out sim/oracle/traces/gunnail_nmk004_regs.trace \\
        --seconds-to-run 16
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# tracelog's own action output comes BEFORE the normal trace line, so the
# real "<PC>: <disasm>" pair is the LAST hex field, not the first —
# raw line shape: "<cyc> <af> <bc> <de> <hl> <ix> <iy> <sp> <pc>: <disasm>"
# (af is 16-bit here — see the module docstring for why a/f aren't used
# directly — split into A/F in reformat()).
TRACE_RE = re.compile(
    r"^(\d+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+) "
    r"([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+):"
)


def build_debugscript(device: str, trace_out: Path, script_path: Path) -> None:
    action = (
        '{tracelog "%d %04X %04X %04X %04X %04X %04X %04X ",'
        "totalcycles,af,bc,de,hl,ix,iy,sp}"
    )
    script_path.write_text(
        f"focus {device}\n"
        f"trace {trace_out},{device},noloop,{action}\n"
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
                continue  # a stray loop-summary or malformed line
            cyc, af, bc, de, hl, ix, iy, sp, pc = m.groups()
            af_val = int(af, 16)
            a, f = (af_val >> 8) & 0xFF, af_val & 0xFF
            f_out.write(
                f"{cyc} {pc.upper()} A={a:02X} F={f:02X} BC={bc.upper()} "
                f"DE={de.upper()} HL={hl.upper()} IX={ix.upper()} IY={iy.upper()} SP={sp.upper()}\n"
            )
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", required=True)
    ap.add_argument("--rompath", required=True)
    ap.add_argument("--device", required=True, help="MAME device tag to trace, e.g. :nmk004:mcu")
    ap.add_argument("--out", required=True, help="output path")
    ap.add_argument("--seconds-to-run", type=int, default=2, help="emulated seconds budget (default 2)")
    ap.add_argument("--work-dir", default=".", help="directory to run mame in; default cwd")
    args = ap.parse_args()

    work_dir = Path(args.work_dir).resolve()
    out_path = Path(args.out).resolve()
    script_path = work_dir / f".capture_reg_{args.game}.debugscript"
    raw_path = work_dir / f".capture_reg_{args.game}.raw.tr"
    raw_path.unlink(missing_ok=True)

    build_debugscript(args.device, raw_path, script_path)
    print(f"[capture_reg_trace] tracing {args.device} in {args.game}, {args.seconds_to_run}s budget", file=sys.stderr)
    run_mame(args.game, args.rompath, script_path, work_dir, args.seconds_to_run)

    if not raw_path.exists():
        raise SystemExit(f"error: {raw_path} was not created — mame/debugger may have failed to start")
    count = reformat(raw_path, out_path)
    script_path.unlink(missing_ok=True)
    raw_path.unlink(missing_ok=True)
    print(f"[capture_reg_trace] wrote {count} instructions to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
