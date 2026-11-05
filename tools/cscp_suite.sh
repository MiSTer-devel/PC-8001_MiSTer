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
# PC-8001mkII
MODEL=mk2 $T mk2boot  300,600                                            || rc=1
MODEL=mk2 NMODE=1 $T mk2n 300,600                                        || rc=1
MODEL=mk2 $T mk2print 900  'print 1+1\nfiles\n'                           || rc=1
# graphics: machine code (DI) fills GVRAM with its address's low byte, sets 31h and spins: 09h 640 attribute,
# 1Dh 320x200 4 colours + blue, 4Dh mono on red, 29h attribute on blue
for v in 09 1d 4d 29; do
	MODEL=mk2 $T mk2g$v 4400 "10 for i=0 to 23:read a:poke &hc000+i,a:next\n20 data &hf3,&hd3,&h5c,&h21,0,&h80,1,&h80,&h3e,&h75,&h23,&h0b,&h78,&hb1,&h20,&hf9,&hd3,&h5f,&h3e,&h$v,&hd3,&h31,&h18,&hfe\n30 def usr=&hc000:a=usr(0)\nrun\n" -- --type-rate 6:6 || rc=1
done
# interrupts and kanji: tools/mk2int_asm.py counts timer and VRTC interrupts over 60 frames; then kanji ROM reads
MODEL=mk2 $T mk2int 7600 "10 a\$=\"F33EC1ED47ED5E2140C02204C1214AC02202C12100002200C22202C2CD33C03E03D3E4D3E6FB063CCD33C010FBF3AFD3E6FBC9DB40E62020FADB40E62028FAC9E52A00C2232200C21808E52A02C2232202C2F53E03D3E4F1E1FBED4D\"\n20 for i=0 to len(a\$)/2-1:poke &hc000+i,val(\"&h\"+mid\$(a\$,i*2+1,2)):next\n30 def usr=&hc000:x=usr(0):out &he8,4:out &he9,9:print peek(&hc200)+256*peek(&hc201);peek(&hc202)+256*peek(&hc203);inp(&he8);inp(&he9);:out &he8,&h21:out &he9,&h43:print inp(&he8);inp(&he9)\nrun\n" -- --type-rate 6:6 || rc=1
# PC-8001mkIISR: N80 (mkII-compatible), N and N80SR modes
MODEL=sr $T srboot 300,600                                                || rc=1
MODEL=sr NMODE=1 $T srn 300,600                                           || rc=1
MODEL=sr V2=1 $T srv2 300,600                                             || rc=1
# N80SR graphics (tools/srg_asm.py: three planes filled, 31h/33h/53h set, [reversed palette]): 640 and 320 colour,
# 320 page 1 / plane mask, 640 and 320 attribute, PR2 (graphics over text), graphics off
while read n a b c r; do tools/srg_run.sh $n $a $b $c $r || rc=1; done <<EOT
srg_c640 18 80 00 rev
srg_c320 1C 80 00
srg_c320p 1C 84 00
srg_c320h 1C 84 04
srg_a640 28 80 00
srg_a320 4C 80 00 rev
srg_a320m 0C 80 14
srg_pr2 18 88 00
srg_off 18 80 02
EOT
# ALU (34h/35h; tools/sralu_asm.py): set/invert/clear, copy, R->B, B->R and the colour compare
MODEL=sr V2=1 $T sralu 12000 "$(python3 tools/sralu_asm.py | python3 tools/ml_text.py)" -- --type-rate 6:6 || rc=1
# YM2203 (tools/sropn_asm.py): timer A interrupts on level 4 over 60 frames, status, SSG register readback
MODEL=sr V2=1 $T sropn 9000 "$(python3 tools/sropn_asm.py | python3 tools/ml_text.py | sed 's/a=usr(0)/a=usr(0):print peek(\&hc200)+256*peek(\&hc201);peek(\&hc202);peek(\&hc203)/')" -- --type-rate 6:6 || rc=1
exit $rc
