#!/bin/sh
# Compare the core (Verilator sim) with CSCP (the reference emulator) after typing the same text.
#   tools/cscp_cmp.sh NAME FRAMES [TEXT] [-- sim options]
#   tools/cscp_cmp.sh print 700 'print 1+1\n'
#   tools/cscp_cmp.sh blink 900,904,908,912 '...'
# Both boot without a disk unit; TEXT is typed from frame $AT (300; sim: PS/2 keys, --type; CSCP: its auto key,
# --paste-text, with {WAITn} removed since the paste waits for BASIC), then each of FRAMES (comma separated) is
# compared (sim 640x200 lines doubled vs CSCP 640x400). SHIFT=N compares sim frame F+N with CSCP frame F.
# TEXT2="FRAME:TEXT" types a second text at FRAME in both (e.g. after a tape load).
# TAPE=FILE mounts a .cmt/.t88 in both (the sim at 5x turbo; CSCP feeds its 8251 FIFO at 5 ms a byte).
# Output: runs/cmp/NAME/{sim,cscp}/frame_NNNNNN.png. Exit 0 when every frame is identical.
cd "$(dirname "$0")/.."
CSCP=${CSCP:-/Users/alans/dev2/common_source_code/build/pc8001.app/Contents/MacOS/pc8001}
AT=${AT:-300}
SHIFT=${SHIFT:-0}
name=${1:?name}; frames=${2:?frames}; text=${3:-}; shift 2; [ $# -gt 0 ] && shift
[ "$1" = "--" ] && shift
out=runs/cmp/$name
rm -rf "$out"; mkdir -p "$out"
last=0; cs=""; ss=""
for f in $(echo "$frames" | tr ',' ' '); do
	[ "$f" -gt "$last" ] && last=$f
	cs="$cs --screenshot $f"; ss="$ss --screenshot $((f + SHIFT))"
done
ctape=""; stape=""
if [ -n "$TAPE" ]; then
	t="$out/tape.${TAPE##*.}"; cp "$TAPE" "$t"   # a path without spaces for the unquoted options
	ctape="--tape $t"; stape="--tape $t --tape-turbo"
fi
c2=""; s2=""
if [ -n "$TEXT2" ]; then c2="--paste-text"; s2="--type"; fi
ctext=$(printf '%s' "$text" | sed -E 's/\{WAIT[0-9]+\}//g')
if [ -n "$text" ]; then
	"$CSCP" --headless --rom-dir refs/emulators/cscp_roms/pc8001_nodisk --out "$out/cscp" --stop-at-frame "$last" \
		--paste-text "$AT:$ctext" $cs $ctape $c2 ${TEXT2:+"$TEXT2"} >/dev/null 2>&1
	verilator/obj_dir_headless/Vtop --quiet --rom-dir refs/emulators/mame_roms/pc8001 \
		--stop-at-frame $((last + SHIFT)) $ss --out "$out/sim" --type "$AT:$text" $stape $s2 ${TEXT2:+"$TEXT2"} "$@"
else
	"$CSCP" --headless --rom-dir refs/emulators/cscp_roms/pc8001_nodisk --out "$out/cscp" --stop-at-frame "$last" \
		$cs >/dev/null 2>&1
	verilator/obj_dir_headless/Vtop --quiet --rom-dir refs/emulators/mame_roms/pc8001 \
		--stop-at-frame $((last + SHIFT)) $ss --out "$out/sim" "$@"
fi
rc=0
for f in $(echo "$frames" | tr ',' ' '); do
	a=$(printf '%06d' $((f + SHIFT))); b=$(printf '%06d' "$f")
	printf '%-12s %6s ' "$name" "$f"
	python3 -I verilator/pngdiff.py --double-a "$out/sim/frame_$a.png" "$out/cscp/frame_$b.png" || rc=1
done
exit $rc
