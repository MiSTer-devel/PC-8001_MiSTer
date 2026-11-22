#!/bin/sh
# setup.sh: copy tools/mister_pad.py to the MiSTer and start the pad (once per MiSTer boot)
cd "$(dirname "$0")"; M=${MISTER_SSH:-mister}
ssh $M 'mkdir -p /media/fat/Scripts' && scp -q ../mister_pad.py $M:/media/fat/Scripts/ &&
ssh $M 'pgrep -f "mister_pad.py serve" >/dev/null || (cd /tmp; nohup python3 /media/fat/Scripts/mister_pad.py serve > /tmp/pad.log 2>&1 &); sleep 2; cat /tmp/pad.log'
