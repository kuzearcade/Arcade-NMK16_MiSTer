#!/bin/bash
# Build every game's reference sim, then run them in parallel with PPM dumps.
cd "$(dirname "$0")"
GAMES="${GAMES:-macross mustang bioship vandyke acrobatm strahl tdragon hachamf tdragon1 hachamfb bjtwin bjtwinp sabotenb nouryoku cactus nouryokup tharrier vandykeb}"
CYCLES="${CYCLES:-120000000}"
for g in $GAMES; do
  make GAME=$g obj_dir_$g/Vgunnail_core > build_$g.log 2>&1 || { echo "BUILD FAILED $g"; grep -m3 "%Error" build_$g.log; }
done
for g in $GAMES; do
  sel=$(grep "^SEL_$g " Makefile | awk '{print $3}')
  ( TB_DUMP_PPM=1 TB_GAME_SEL=$sel TB_PREFIX=$g timeout 3600 ./obj_dir_$g/Vgunnail_core $CYCLES > run_$g.log 2>&1; echo "$g done $?" ) &
done
wait
echo ALL DONE
