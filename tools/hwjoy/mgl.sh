#!/bin/sh
# mgl.sh TAPE NAME: copy TAPE to games/PC8001/joytest/NAME.EXT and write _Development/PC8001_NAME.mgl
M=${MISTER_SSH:-mister}; ext=${1##*.}; n=$2; t=$(mktemp -d)
printf '<mistergamedescription>\n<rbf>_Development/PC8001</rbf>\n<file delay="2" type="f" index="1" path="../../games/PC8001/joytest/%s.%s"/>\n</mistergamedescription>\n' $n $ext > $t/PC8001_$n.mgl
ssh $M 'mkdir -p /media/fat/games/PC8001/joytest' && scp -q "$1" $M:/media/fat/games/PC8001/joytest/$n.$ext && scp -q $t/PC8001_$n.mgl $M:/media/fat/_Development/
rm -rf $t
