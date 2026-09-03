#!/usr/bin/env bash
# Regenerates rtl/third_party_gen/t80/T80s.v — a synthesizable Verilog
# translation of the real, vendored T80 VHDL core (rtl/third_party/t80/,
# bootstrap-fetched per deps.lock) — via GHDL + the ghdl-yosys-plugin.
#
# Why this exists: Verilator has no VHDL support at all, so the vendored
# T80 core (pure VHDL, used unmodified for the real Quartus/hardware build)
# can't be used directly in this project's Verilator-based sim harness.
# This script produces a Verilog netlist with equivalent logic, generated
# once and committed (see docs/t80-vhdl-toolchain.md), for simulation only.
#
# Prerequisites (NOT installed by tools/bootstrap.sh — this is a one-time,
# heavyweight dev-toolchain setup, not a per-build dependency):
#   - GHDL built from source with --enable-libghdl --enable-synth
#     (Ubuntu's packaged ghdl lacks --enable-synth; see docs/t80-vhdl-toolchain.md)
#   - ghdl-yosys-plugin built against that GHDL (ghdl.so)
#   - yosys (apt's yosys package is fine)
#
# Usage:
#   GHDL_BIN=/path/to/ghdl GHDL_YOSYS_PLUGIN=/path/to/ghdl.so tools/gen_t80_verilog.sh
#
# Only needs to be re-run if deps.lock's t80 pin changes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T80_SRC="$ROOT/rtl/third_party/t80"
GEN_DIR="$ROOT/rtl/third_party_gen/t80"
PATCH="$GEN_DIR/ghdl-compat.patch"

GHDL_BIN="${GHDL_BIN:-ghdl}"
GHDL_YOSYS_PLUGIN="${GHDL_YOSYS_PLUGIN:-}"

if [ -z "$GHDL_YOSYS_PLUGIN" ]; then
	echo "error: set GHDL_YOSYS_PLUGIN=/path/to/ghdl.so (built per docs/t80-vhdl-toolchain.md)" >&2
	exit 1
fi
if [ ! -d "$T80_SRC" ]; then
	echo "error: $T80_SRC not found — run tools/bootstrap.sh first" >&2
	exit 1
fi

GHDL_LIB_DIR="$("$GHDL_BIN" --libghdl-library-path | xargs dirname)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$T80_SRC"/T80_Pack.vhd "$T80_SRC"/T80.vhd "$T80_SRC"/T80_ALU.vhd \
   "$T80_SRC"/T80_MCode.vhd "$T80_SRC"/T80_Reg.vhd "$T80_SRC"/T80s.vhd "$WORK/"

echo "[gen_t80] applying $PATCH" >&2
patch -p1 -d "$WORK" < "$PATCH"

echo "[gen_t80] synthesizing via GHDL + yosys" >&2
LD_LIBRARY_PATH="$GHDL_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
yosys -m "$GHDL_YOSYS_PLUGIN" -p "
	ghdl --std=93 -fsynopsys -fexplicit --latches \
		$WORK/T80_Pack.vhd $WORK/T80.vhd $WORK/T80_ALU.vhd \
		$WORK/T80_MCode.vhd $WORK/T80_Reg.vhd $WORK/T80s.vhd -e t80s;
	synth;
	write_verilog $WORK/T80s.v
"

mkdir -p "$GEN_DIR"
cp "$WORK/T80s.v" "$GEN_DIR/T80s.v"
echo "[gen_t80] wrote $GEN_DIR/T80s.v" >&2
