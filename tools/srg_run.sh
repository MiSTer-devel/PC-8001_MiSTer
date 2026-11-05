#!/bin/sh
# One SR N80SR-mode graphics test (tools/srg_asm.py): tools/srg_run.sh NAME P31 P33 P53 [rev]
cd "$(dirname "$0")/.."
n=$1; shift
H=$(python3 tools/srg_asm.py "$@")
MODEL=sr V2=1 tools/cscp_cmp.sh "$n" 6000 "10 a\$=\"$H\"\n20 for i=0 to len(a\$)/2-1:poke &hc000+i,val(\"&h\"+mid\$(a\$,i*2+1,2)):next\n30 def usr=&hc000:a=usr(0)\nrun\n" -- --type-rate 6:6
