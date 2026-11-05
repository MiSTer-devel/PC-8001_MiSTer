#!/bin/sh
# Compare the core (Verilator sim) with CSCP (the reference emulator) after typing the same text.
#   tools/cscp_cmp.sh NAME FRAMES [TEXT] [-- sim options]
#   tools/cscp_cmp.sh print 700 'print 1+1\n'
#   tools/cscp_cmp.sh blink 900,904,908,912 '...'
# Both boot without a disk unit; TEXT is typed from frame $AT (300; sim: PS/2 keys, --type; CSCP: its auto key,
# --paste-text, with {WAITn} removed since the paste waits for BASIC), then each of FRAMES (comma separated) is
# compared (sim 640x200 lines doubled vs CSCP 640x400). SHIFT=N compares sim frame F+N with CSCP frame F.
# TEXT2="FRAME:TEXT" types a second text at FRAME in both (e.g. after a tape load).
# DISK=FILE mounts a .d88 in drive 1 of both, with the PC-80S31 unit (CSCP: DISK.ROM in its ROM dir).
# DISK2=FILE mounts a .d88 in drive 2 of both.
# SWAP=FRAME:FILE puts FILE in drive 1 before FRAME (CSCP --swap-disk); SWAP2 the same for drive 2.
# TAPE=FILE mounts a .cmt/.t88 in both (the sim at 5x turbo; CSCP feeds its 8251 FIFO at 5 ms a byte).
# MODEL=mk2 runs the PC-8001mkII (CSCP's pc8001mk2 build; sim --mk2); NMODE=1 its N-BASIC mode.
# Output: runs/cmp/NAME/{sim,cscp}/frame_NNNNNN.png. Exit 0 when every frame is identical.
cd "$(dirname "$0")/.."
B=/Users/alans/dev2/common_source_code/build
m=""; smodel=""; cmodel=""
if [ "$MODEL" = mk2 ]; then
	m=mk2; smodel="--mk2"
	[ -n "$NMODE" ] && { smodel="$smodel --n-mode"; cmodel="--boot-mode 2"; }
fi
CSCP=${CSCP:-$B/pc8001$m.app/Contents/MacOS/pc8001$m}
AT=${AT:-300}
VTOP=${VTOP:-verilator/obj_dir_headless/Vtop}
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
romdir=refs/emulators/cscp_roms/pc8001${m}_nodisk; cdisk=""; sdisk=""
if [ -n "$DISK" ]; then
	d="$out/disk.d88"; cp "$DISK" "$d"
	romdir=refs/emulators/cscp_roms/pc8001$m; cdisk="--disk-a $d"; sdisk="--disk $d"
fi
if [ -n "$DISK2" ]; then
	d="$out/disk2.d88"; cp "$DISK2" "$d"
	romdir=refs/emulators/cscp_roms/pc8001$m; cdisk="$cdisk --disk-b $d"; sdisk="$sdisk --disk2 $d"
fi
# SWAP=FRAME:FILE: insert FILE in drive 1 before FRAME (both)
cswap=""; sswap=""
if [ -n "$SWAP" ]; then
	sf=${SWAP%%:*}; w="$out/swap.d88"; cp "${SWAP#*:}" "$w"
	cswap="--swap-disk $sf:a:$w"; sswap="--swap-disk $sf:$w"
fi
if [ -n "$SWAP2" ]; then
	sf=${SWAP2%%:*}; w="$out/swap2.d88"; cp "${SWAP2#*:}" "$w"
	cswap="$cswap --swap-disk $sf:b:$w"; sswap="$sswap --swap-disk2 $sf:$w"
fi
c2=""; s2=""
if [ -n "$TEXT2" ]; then c2="--paste-text"; s2="--type"; fi
ctext=$(printf '%s' "$text" | sed -E 's/\{WAIT[0-9]+\}//g')
if [ -n "$text" ]; then
	"$CSCP" --headless --rom-dir $romdir --out "$out/cscp" --stop-at-frame "$last" $cmodel \
		--paste-text "$AT:$ctext" $cs $ctape $cdisk $cswap $c2 ${TEXT2:+"$TEXT2"} >/dev/null 2>&1
	"$VTOP" --quiet --rom-dir refs/emulators/mame_roms/pc8001 \
		--stop-at-frame $((last + SHIFT)) $smodel $ss --out "$out/sim" --type "$AT:$text" $stape $sdisk $sswap $s2 ${TEXT2:+"$TEXT2"} "$@"
else
	"$CSCP" --headless --rom-dir $romdir --out "$out/cscp" --stop-at-frame "$last" $cmodel \
		$cs $ctape $cdisk $cswap >/dev/null 2>&1
	"$VTOP" --quiet --rom-dir refs/emulators/mame_roms/pc8001 \
		--stop-at-frame $((last + SHIFT)) $smodel $ss --out "$out/sim" $stape $sdisk $sswap "$@"
fi
rc=0
for f in $(echo "$frames" | tr ',' ' '); do
	a=$(printf '%06d' $((f + SHIFT))); b=$(printf '%06d' "$f")
	printf '%-12s %6s ' "$name" "$f"
	python3 -I verilator/pngdiff.py --double-a "$out/sim/frame_$a.png" "$out/cscp/frame_$b.png" || rc=1
done
exit $rc
