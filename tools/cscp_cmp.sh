#!/bin/sh
# Compare the core (Verilator sim) with CSCP (the reference emulator) after typing the same text.
#   tools/cscp_cmp.sh NAME FRAME [TEXT] [-- sim options]
#   tools/cscp_cmp.sh print 700 'print 1+1\n'
# Both boot without a disk unit; TEXT is typed from frame 300 (sim: PS/2 keys, --type; CSCP: its auto key,
# --paste-text), then frame FRAME of each is compared (sim 640x200 lines doubled vs CSCP 640x400).
# Output: runs/cmp/NAME/{sim,cscp}/frame_NNNNNN.png. Exit 0 when identical.
set -e
cd "$(dirname "$0")/.."
CSCP=${CSCP:-/Users/alans/dev2/common_source_code/build/pc8001.app/Contents/MacOS/pc8001}
AT=${AT:-300}
name=${1:?name}; frame=${2:?frame}; text=${3:-}; shift 2; [ $# -gt 0 ] && shift
[ "$1" = "--" ] && shift
out=runs/cmp/$name
rm -rf "$out"; mkdir -p "$out"
f=$(printf '%06d' "$frame")
if [ -n "$text" ]; then
	"$CSCP" --headless --rom-dir refs/emulators/cscp_roms/pc8001_nodisk --out "$out/cscp" --stop-at-frame "$frame" \
		--paste-text "$AT:$(printf "%s" "$text" | sed -E "s/\{WAIT[0-9]+\}//g")" --screenshot "$frame" >/dev/null 2>&1
	verilator/obj_dir_headless/Vtop --quiet --rom-dir refs/emulators/mame_roms/pc8001 --stop-at-frame "$frame" --screenshot "$frame" --out "$out/sim" \
		--type "$AT:$text" "$@"
else
	"$CSCP" --headless --rom-dir refs/emulators/cscp_roms/pc8001_nodisk --out "$out/cscp" --stop-at-frame "$frame" \
		--screenshot "$frame" >/dev/null 2>&1
	verilator/obj_dir_headless/Vtop --quiet --rom-dir refs/emulators/mame_roms/pc8001 --stop-at-frame "$frame" --screenshot "$frame" --out "$out/sim" "$@"
fi
printf '%-12s ' "$name"
python3 -I verilator/pngdiff.py --double-a "$out/sim/frame_$f.png" "$out/cscp/frame_$f.png"
