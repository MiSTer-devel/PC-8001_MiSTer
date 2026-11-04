#!/bin/sh
# Regression tests: run the headless sim and compare frame hashes with tests/expected/*.hash.
#   ./run_tests.sh            check
#   ./run_tests.sh --update   write the current hashes as the expected ones
# ROMs from ../refs/emulators/mame_roms/pc8001 (MAME names; see ../README.md).
cd "$(dirname "$0")"
VTOP=./obj_dir_headless/Vtop
[ -x $VTOP ] || { echo "build first: make" >&2; exit 2; }
mkdir -p tests/expected out/tests
update=0; [ "$1" = "--update" ] && update=1
fail=0
# name | frame | sim options
run() {
	name=$1; frame=$2; shift 2
	rm -rf out/tests/$name
	$VTOP --quiet --stop-at-frame $frame --screenshot $frame --out out/tests/$name \
		--frame-log out/tests/$name/frames.csv "$@" || { echo "FAIL $name (exit $?)"; fail=1; return; }
	got=$(awk -F, -v f=$frame '$1==f{print $2}' out/tests/$name/frames.csv)
	if [ $update = 1 ]; then echo $got > tests/expected/$name.hash; echo "set  $name $got"; return; fi
	want=$(cat tests/expected/$name.hash 2>/dev/null)
	if [ "$got" = "$want" ]; then echo "ok   $name $got"; else echo "FAIL $name got $got want $want (out/tests/$name)"; fail=1; fi
}
run boot     250
run boot16k  250 --ram16k
run print    500 --type "300:print 1+1\\n"
run w80      700 --type "300:width 80,25\\n{WAIT60}print \"80 columns\"\\n"
Y=../refs/software/archive_org/yearbased_pc8001_unpacked
run tape_t88 1400 --tape-turbo --tape "$Y/1983/PC-8001/River Patrol (1983)(Micom BASIC).t88" --type '300:cload"river"\n' --type '1200:list 100-300\n'
run tape_mon 1300 --tape-turbo --tape "$Y/1982/PC-8001/Kumo Vader (1982)(Micom BASIC).cmt" --type '300:cload"KUMO"\n' --type '800:mon\n{WAIT30}l\n'
run disk_boot 900 --disk "$Y/BASIC/PC-8001/N-BASIC System Disk PC-8034-2W.d88"
python3 -I tests/make_ext_rom.py out/tests/ext.rom
run ext_rom  400 --ext-rom out/tests/ext.rom
# printer: the bytes LPRINT and LLIST send
run printer  800 --printer out/tests/printer.txt --type "300:lprint 123\\n10 rem printer\\nllist\\n"
if [ $update = 0 ]; then
	want=$(printf ' 123 \r\n10 REM printer\r\n')
	[ "$(cat out/tests/printer.txt)" = "$want" ] && echo "ok   printer output" || { echo "FAIL printer output: $(od -c out/tests/printer.txt | head -3)"; fail=1; }
fi
exit $fail
