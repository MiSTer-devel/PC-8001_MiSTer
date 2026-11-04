#!/bin/sh
# Every core-vs-CSCP comparison (tools/cscp_cmp.sh); prints one line per frame, exits 1 if any differ.
cd "$(dirname "$0")/.."
T=tools/cscp_cmp.sh
rc=0
$T boot   300,600                                                        || rc=1
$T print  700    'print 1+1\n'                                           || rc=1
$T prog   1500   '10 for i=1 to 5\n20 print i,i*i\n30 next\nlist\nrun\n' || rc=1
$T w80    1300   'width 80,25\n{WAIT60}print "hello 80 columns"\nfiles\n' || rc=1
$T w8020  900    'width 80,20\n{WAIT60}print "eighty by twenty"\n'      || rc=1
$T w4025  1100   'width 40,25\n{WAIT60}print "forty by 25"\n'           || rc=1
$T color  1500   'console 0,25,0,1\n{WAIT60}color 2\nprint "red"\ncolor 4\nprint "green"\ncolor 7\n' || rc=1
$T pset   1400   'console 0,25,0,1\n{WAIT60}for i=0 to 79:pset(i,i/2),5:next\n' || rc=1
# 80 columns: BASIC scans the keys only every few frames while it echoes, so type slower (CSCP: ~14 frames a key)
$T chars  1700   'width 80,25\n{WAIT60}for i=32 to 255:print chr$(i);:next\n' -- --type-rate 6:6 || rc=1
$T sg40   1300   'for i=0 to 255:print chr$(i);:next\n'                  || rc=1
$T blink  2400,2412,2424,2436,2448,2460,2472,2484,2496 '10 cls:print "blink";\n20 poke &hf350,0:poke &hf351,2:poke &hf352,10:poke &hf353,0\n30 goto 20\nrun\n' || rc=1
Y=refs/software/archive_org/yearbased_pc8001_unpacked
TAPE="$Y/1983/PC-8001/River Patrol (1983)(Micom BASIC).t88" TEXT2='1500:list 100-300\n' $T tape_t88 2000 'cload"river"\n' || rc=1
TAPE="$Y/1982/PC-8001/Kumo Vader (1982)(Micom BASIC).cmt" TEXT2='1300:list 100-300\n' $T tape_cmt 1800 'cload"KUMO"\n' || rc=1
$T time   1800   'time$="12:34:56":for i=1 to 3000:next:print time$\n'   || rc=1
$T kbdus  700    'print "!#$%&()=-^@[];:,./<>?+*_"\n' -- --kbd-us        || rc=1
D="$Y/BASIC/PC-8001/N-BASIC System Disk PC-8034-2W.d88"
AT=1500 DISK="$D" DISK2="$Y/1979/PC-8001/Block Kuzushi (1979)(ASCII).d88" TEXT2='2000:mount 2:run"2:BLOCK"\n' \
	$T block2 6000,9000 '2\n' || rc=1
exit $rc
