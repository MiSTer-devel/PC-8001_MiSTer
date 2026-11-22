#!/bin/sh
# rec.sh NAME SECONDS PAD-COMMAND...: record frames while the pad does the command; NAME.png = 8 of them
cd "$(dirname "$0")"; n=$1; s=$2; shift 2; o=${OUT:-.}
rm -rf $o/fr_$n; ./k frames --full ${s}s $o/fr_$n >/dev/null 2>&1 &
sleep 0.8; ./pad "$@"; wait
ls $o/fr_$n/*.png > $o/l_$n.txt 2>/dev/null; c=$(wc -l < $o/l_$n.txt); step=$(( (c + 7) / 8 )); [ $step -lt 1 ] && step=1
awk -v s=$step 's==1 || NR%s==1' $o/l_$n.txt | head -8 | sed "s|^|file '|;s|$|'|" > $o/c_$n.txt
ffmpeg -loglevel error -y -f concat -safe 0 -i $o/c_$n.txt -vf "scale=480:-2,tile=4x2" -frames:v 1 $o/$n.png
echo "$n: $c frames"
