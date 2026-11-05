#!/bin/sh
# Make boot2.rom (the PC-8001mkIISR's ROMs, OSD Model = PC-8001mkIISR) from MAME's pc8001mk2sr ROM files:
#   tools/make_boot2_rom.sh DIR [OUT]   DIR has n80_2sr.rom (N80-BASIC 1.2 / N-BASIC 1.6, 32 KB), n80_3.rom
#                                       (N80SR-BASIC, 40 KB), font80sr.rom (4 KB) and kanji1.rom (128 KB)
# (CSCP's names: N80_2.ROM of its SR set, N80_3.ROM, 80SRCG.ROM, KANJI1.ROM.)
# Layout (ioctl index 80h, kept in DDR3 by rtl/rom_store.sv): n80_2sr.rom at 0, n80_3.rom at 8000h,
# font80sr.rom at 12000h, FFh to 20000h, kanji1.rom at 20000h (256 KB). boot.rom is still needed (disk.rom).
set -e
dir=${1:?usage: $0 DIR [OUT]}
out=${2:-boot2.rom}
check() {   # file sha1 size
	[ -f "$1" ] || { echo "missing $1" >&2; exit 1; }
	s=$(shasum "$1" | cut -d' ' -f1)
	[ "$s" = "$2" ] || echo "warning: $1 SHA1 $s, expected $2" >&2
	[ "$(wc -c < "$1" | tr -d ' ')" = "$3" ] || { echo "$1 is not $3 bytes" >&2; exit 1; }
}
check "$dir/n80_2sr.rom"  e8db5dc5eae11da14e48656d324874e59f2e3844 32768
check "$dir/n80_3.rom"    9bfa5009d703cd31caa734d932d2a847d74cbfa6 40960
check "$dir/font80sr.rom" 565dc8e5e46b1633cb434d12b4d8b3a662546b33 4096
check "$dir/kanji1.rom"   82e11a177af6a5091dd67f50a2f4bafda84d6556 131072
{
	cat "$dir/n80_2sr.rom" "$dir/n80_3.rom" "$dir/font80sr.rom"
	# FFh from 13000h to 20000h (53248 bytes)
	head -c 53248 /dev/zero | LC_ALL=C tr '\0' '\377'
	cat "$dir/kanji1.rom"
} > "$out"
echo "$out: $(wc -c < "$out" | tr -d ' ') bytes, SHA1 $(shasum "$out" | cut -d' ' -f1)"
