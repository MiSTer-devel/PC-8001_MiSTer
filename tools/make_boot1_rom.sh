#!/bin/sh
# Make boot1.rom (the PC-8001mkII's ROMs, OSD Model = PC-8001mkII) from MAME's pc8001mk2 ROM files:
#   tools/make_boot1_rom.sh DIR [OUT]   DIR has n80_2.rom (N80-BASIC / N-BASIC, 32 KB) and kanji1.rom (128 KB)
# Layout (ioctl index 40h, kept in DDR3 by rtl/rom_store.sv): n80_2.rom at 0, kanji1.rom at 8000h.
# Same as: cat n80_2.rom kanji1.rom > boot1.rom. boot.rom is still needed (its font and disk.rom).
set -e
dir=${1:?usage: $0 DIR [OUT]}
out=${2:-boot1.rom}
check() {   # file sha1 size
	[ -f "$1" ] || { echo "missing $1" >&2; exit 1; }
	s=$(shasum "$1" | cut -d' ' -f1)
	[ "$s" = "$2" ] || echo "warning: $1 SHA1 $s, expected $2" >&2
	[ "$(wc -c < "$1" | tr -d ' ')" = "$3" ] || { echo "$1 is not $3 bytes" >&2; exit 1; }
}
check "$dir/n80_2.rom"  c12d34e42021110930fed45a8af98db52136f1fb 32768
check "$dir/kanji1.rom" 82e11a177af6a5091dd67f50a2f4bafda84d6556 131072
cat "$dir/n80_2.rom" "$dir/kanji1.rom" > "$out"
echo "$out: $(wc -c < "$out" | tr -d ' ') bytes, SHA1 $(shasum "$out" | cut -d' ' -f1)"
