#!/bin/sh
# Make boot.rom for the PC8001 core from MAME's pc8001 ROM files (or the same files under other names):
#   tools/make_boot_rom.sh DIR [OUT]   DIR has n80v110.rom (N-BASIC 1.1, 24 KB), font.rom (2 KB) and, for the
#                                      PC-80S31 disk unit, disk.rom (2 KB)
# Layout (ioctl index 0): N-BASIC at 0000h, font at 6000h, disk.rom at 6800h.
# Same as: cat n80v110.rom font.rom disk.rom > boot.rom (leave disk.rom out for a machine with no disk unit)
set -e
dir=${1:?usage: $0 DIR [OUT]}
out=${2:-boot.rom}
check() {   # file sha1 size
	[ -f "$1" ] || { echo "missing $1" >&2; exit 1; }
	s=$(shasum "$1" | cut -d' ' -f1)
	[ "$s" = "$2" ] || echo "warning: $1 SHA1 $s, expected $2" >&2
	[ "$(wc -c < "$1" | tr -d ' ')" = "$3" ] || { echo "$1 is not $3 bytes" >&2; exit 1; }
}
check "$dir/n80v110.rom" 4603cdb7a3833e7feb257b29d8052c872369e713 24576
check "$dir/font.rom"    84b90f69671d4b72e8f219e1fe7cd667e976cf7f 2048
if [ -f "$dir/disk.rom" ]; then
	check "$dir/disk.rom" bb7103a0818850a039c67ff666a31ce49a8d516f 2048
	cat "$dir/n80v110.rom" "$dir/font.rom" "$dir/disk.rom" > "$out"
else
	cat "$dir/n80v110.rom" "$dir/font.rom" > "$out"
fi
echo "$out: $(wc -c < "$out" | tr -d ' ') bytes, SHA1 $(shasum "$out" | cut -d' ' -f1)"
