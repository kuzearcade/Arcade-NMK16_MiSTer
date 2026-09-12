#!/bin/bash
# $1 = set; builds (if needed) and runs the reference sim, then compares with MAME snapshots.
g=$1; SP=/tmp/claude-1000/-home-vboxuser-Arcade-NMK16-MiSTer/850e2bac-564c-4ee2-a2ee-4a850336cbdf/scratchpad
make GAME=$g obj_dir_$g/Vgunnail_core > build_$g.log 2>&1 || { echo "$g BUILD FAIL"; grep -m8 "%Error" build_$g.log | cut -c1-200; exit 1; }
rm -f ${g}_frame_*.ppm
TB_DUMP_PPM=1 make GAME=$g CYCLES=320000000 run > run_$g.log 2>&1
grep "tb_gc:" run_$g.log | tail -3
a=$(python3 $SP/mg_cmp.py . $g $SP/mame_snaps/$g/$g 20 168 4 2>&1 | grep -c "diff      0 px"); b=$(python3 $SP/mg_cmp.py . $g $SP/mame_snaps/$g/$g 150 449 4 2>&1 | grep -c "diff      0 px")
echo "$g exact: $a/149 $b/300"
python3 $SP/mg_cmp.py . $g $SP/mame_snaps/$g/$g 150 449 4 2>&1 | grep -v "diff      0 px" | tail -5
