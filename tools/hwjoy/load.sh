#!/bin/sh
# load.sh NAME [SECONDS]: load PC8001_NAME.mgl, type MON / L, wait SECONDS (default 60), screenshot NAME_title.png
cd "$(dirname "$0")"; n=$1; w=${2:-60}
ssh ${MISTER_SSH:-mister} "echo 'load_core /media/fat/_Development/PC8001_$n.mgl' > /dev/MiSTer_cmd"; sleep 14
./k type --hold 50 'MON\n' >/dev/null 2>&1; sleep 1; ./k type --hold 50 'L\n' >/dev/null 2>&1
sleep $w; ./k screenshot ${OUT:-.}/${n}_title.png >/dev/null 2>&1
