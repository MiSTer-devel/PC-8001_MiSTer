#!/bin/sh
# MAME reference frames (MAME 0.283):
#   tools/mame_ref.sh MACHINE OUTDIR FRAMES [AT:TEXT ...] [-- extra mame options]
#   tools/mame_ref.sh pc8001 runs/mame/boot 300
#   tools/mame_ref.sh pc8001 runs/mame/width40 400,600 '300:WIDTH 40\n'
# MACHINE: pc8001, pc8001mk2, pc8001mk2sr. FRAMES: comma-separated snapshot frames (MAME counts from 1).
# MAME_SWAP=FRAME:FILE swaps the disk in drive 1 at FRAME (-flop1 FILE mounts the first, after --).
# Snapshots land in OUTDIR/MACHINE/NNNN.png. ROMs from refs/emulators/mame_roms.
set -e
cd "$(dirname "$0")/.."
MAME=${MAME:-/Users/alans/Downloads/mame0283-arm64/mame}
m=${1:?machine}; out=${2:?outdir}; frames=${3:?frames}; shift 3
i=0
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
	i=$((i+1)); export MAME_AT_$i="${1%%:*}" MAME_TEXT_$i="${1#*:}"; shift
done
[ "$1" = "--" ] && shift
mkdir -p "$out"
SNAPF=$frames "$MAME" "$m" -rompath refs/emulators/mame_roms -skip_gameinfo -nothrottle -video none -sound none \
	-snapshot_directory "$out" -cfg_directory "$out/cfg" -nvram_directory "$out/nvram" \
	-autoboot_script tools/mame_type.lua "$@" >/dev/null
ls "$out/$m"
