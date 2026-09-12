#!/bin/bash
# rebuild + run the Family E sets, N at a time
cd "$(dirname "$0")"
sets="$1"; par=${2:-3}
for g in $sets; do
  ( make GAME=$g obj_dir_$g/Vgunnail_core > build_$g.log 2>&1 || { echo "$g BUILD FAIL"; exit 1; }
    ./run_afega_one.sh $g > fame_$g.txt 2>&1; echo "$g done: $(grep exact fame_$g.txt)" ) &
  while [ $(jobs -r | wc -l) -ge $par ]; do sleep 5; done
done
wait
