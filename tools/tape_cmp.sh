#!/bin/sh
# Load a tape in both the core (sim) and CSCP, start it, and compare: tools/tape_cmp.sh NAME FILE.cmt|.t88
# BASIC tapes (.cmt starting D3h, or a .t88): cload, then run. Machine code (.cmt starting 3Ah): mon, L, then
# G to the first block's load address (most games start there). The start is typed once both have loaded
# (CSCP feeds 5 ms a byte: frames ~ size x 0.31, plus margin); frames compared: 300 and 1200 after it.
# Extra frames: FRAMES="a,b" (relative to the start). Output and exit code as tools/cscp_cmp.sh.
cd "$(dirname "$0")/.."
n=${1:?usage: $0 NAME FILE}; f=${2:?usage: $0 NAME FILE}
size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f")
start=$((300 + size * 31 / 100 + 400))
rel=${FRAMES:-300,1200}
frames=$(echo "$rel" | tr ',' '\n' | while read r; do echo $((start + r)); done | paste -sd, -)
case "$f" in
*.t88|*.T88) kind=basic ;;
*) [ "$(xxd -p -l 1 "$f")" = 3a ] && kind=mc || kind=basic ;;
esac
if [ $kind = basic ]; then
	TAPE="$f" TEXT2="$start:run\n" tools/cscp_cmp.sh "$n" "$frames" 'cload\n'
else
	a=$(xxd -p -s 1 -l 2 "$f" | tr a-f A-F)
	TAPE="$f" TEXT2="$start:G$a\n" tools/cscp_cmp.sh "$n" "$frames" 'mon\n{WAIT30}L\n'
fi
