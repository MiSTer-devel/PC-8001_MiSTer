#!/bin/sh
cd "$1" && exec /Users/alans/dev2/common_source_code/build/pc8001mk2.app/Contents/MacOS/pc8001mk2 --headless --rom-dir /Users/alans/dev2/PC-8001_MiSTer/refs/emulators/cscp_roms/pc8001mk2_nodisk --boot-mode 0 --out o --stop-at-frame 250000 --script script.txt > run.json 2>run.err
