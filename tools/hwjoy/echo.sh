#!/bin/sh
# echo.sh NAME: load PC8001_NAME.mgl; at the BASIC prompt press every pad input between Q markers (Auto map:
# right left up down = 6 4 8 2; A, C, then up+right = 9 with diagonals, else 8 6; B (Return by default) last).
# Screenshot NAME_echo.png
cd "$(dirname "$0")"
ssh ${MISTER_SSH:-mister} "echo 'load_core /media/fat/_Development/PC8001_$1.mgl' > /dev/MiSTer_cmd"; sleep 14
./k type --hold 50 'Q' >/dev/null 2>&1
./pad press right press left press up press down press a press c down up press right up right up up wait 300 press b
./k type --hold 50 'Q' >/dev/null 2>&1
sleep 5; ./k screenshot ${OUT:-.}/$1_echo.png >/dev/null 2>&1
