#!/bin/sh
# d3011df sweep: for each .mra -> load, settle, shot A (attract), coin x2 + start,
# shot B (+12 s, game start), shot C (+22 s, gameplay). One log line per game.
MAN=/media/fat/sweep97_manifest.txt
LOG=/media/fat/sweep97_log.txt
: > $LOG
while IFS="	" read -r SET RBF MRA; do
  [ -z "$SET" ] && continue
  rm -rf "/media/fat/screenshots/$SET"
  echo "load_core $MRA" > /dev/MiSTer_cmd
  sleep 45
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 4
  python3 /media/fat/mister_keys.py 5 5 1 >/dev/null 2>&1
  sleep 12
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 10
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 4
  N=$(ls "/media/fat/screenshots/$SET" 2>/dev/null | wc -l)
  RUN=$(ps aux | grep -c "[M]iSTer /media")
  echo "$SET	$RBF	shots=$N	mister=$RUN	$(date +%H:%M:%S)" >> $LOG
done < $MAN
echo "SWEEP COMPLETE" >> $LOG
