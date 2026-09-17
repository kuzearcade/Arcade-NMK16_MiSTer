#!/bin/sh
# Second pass for sets whose +22 s frame was still an intro / character
# select: load, settle, coin x2 + start, then button 1 (lctrl) a few times to
# skip intros and confirm selects, shot D at ~+45 s, shot E at ~+65 s.
# Manifest: SET <tab> RBF <tab> MRA (same layout as the main sweep).
MAN=/media/fat/pass2_manifest.txt
LOG=/media/fat/pass2_log.txt
: > $LOG
while IFS="	" read -r SET RBF MRA; do
  [ -z "$SET" ] && continue
  rm -rf "/media/fat/screenshots/$SET"
  echo "load_core $MRA" > /dev/MiSTer_cmd
  sleep 45
  python3 /media/fat/mister_keys.py 5 5 1 >/dev/null 2>&1
  sleep 6
  python3 /media/fat/mister_keys.py lctrl >/dev/null 2>&1
  sleep 8
  python3 /media/fat/mister_keys.py lctrl >/dev/null 2>&1
  sleep 8
  python3 /media/fat/mister_keys.py lctrl >/dev/null 2>&1
  sleep 20
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 20
  timeout 8 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 4
  N=$(ls "/media/fat/screenshots/$SET" 2>/dev/null | wc -l)
  echo "$SET	$RBF	shots=$N	$(date +%H:%M:%S)" >> $LOG
done < $MAN
echo "PASS2 COMPLETE" >> $LOG
