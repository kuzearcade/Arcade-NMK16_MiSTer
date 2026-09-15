#!/bin/sh
# Per-game smoke test, run on the MiSTer. For each .mra:
#   load -> settle -> shot A -> coin+start -> settle -> shot B
# Screenshots land in /media/fat/screenshots/<setname>/ and are analysed off-board.
# One line per game to /media/fat/sweep_log.txt so a dropped ssh cannot lose the run.
MAN=/media/fat/sweep_manifest.txt
LOG=/media/fat/sweep_log.txt
: > $LOG
while IFS="	" read -r SET RBF PROM MRA; do
  [ -z "$SET" ] && continue
  rm -rf "/media/fat/screenshots/$SET"
  echo "load_core $MRA" > /dev/MiSTer_cmd
  sleep 45
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 4
  # coin x2 then start, on the keyboard MAME defaults this core uses
  python3 /media/fat/mister_keys.py 5 5 1 >/dev/null 2>&1
  sleep 10
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 4
  N=$(ls "/media/fat/screenshots/$SET" 2>/dev/null | wc -l)
  RUN=$(ps aux | grep -c "[M]iSTer /media")
  echo "$SET	$RBF	$PROM	shots=$N	mister=$RUN" >> $LOG
  echo "done $SET shots=$N"
done < $MAN
echo "SWEEP COMPLETE"
