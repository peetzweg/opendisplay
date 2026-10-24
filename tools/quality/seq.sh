#!/bin/zsh
# usage: seq.sh label change|scroll N  -> saves up to N consecutive decoded frames
source "$(dirname "$0")/env.sh"
D=$S/cap/$1; rm -rf $D; mkdir -p $D; ssh $R 'rm -f /tmp/od-seq-*.png'
before=$(ssh $R "grep -c 'frame sequence dumped' $RECEIVER_LOG")
OD_RECEIVER_HOST=$R $S/testpage $D $2 $3 > $D/page.log 2>&1 & P=$!
[[ $2 == scroll ]] && { sleep 3; ssh $R "echo $3 > /tmp/od-dump-request"; }
for i in {1..60}; do sleep 2; [[ $(ssh $R "grep -c 'frame sequence dumped' $RECEIVER_LOG") -gt $before ]] && break; done
sleep 1; kill $P; scp -q "$R:/tmp/od-seq-*.png" $D/
grep "encoder ready" "$SENDER_LOG" | tail -1 > $D/encoder.txt
cat $D/encoder.txt; ls $D | grep -c od-seq
