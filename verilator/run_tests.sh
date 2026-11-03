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
exit $fail
