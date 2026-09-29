#!/bin/zsh
# usage: capture.sh label  -> test page up, settle, fetch the receiver's decoded frame
source "$(dirname "$0")/env.sh"
D=$S/cap/$1; rm -rf $D; mkdir -p $D
$S/testpage $D > $D/page.log 2>&1 & P=$!
sleep 8; ssh $R 'rm -f /tmp/od-idle.png'; sleep 1
# nudge one frame so the probe dumps even if the stream already went idle
ssh $R 'touch /tmp/od-dump-request'; sleep 6
scp -q $R:/tmp/od-idle.png $D/recv.png; kill $P
grep "encoder ready" "$SENDER_LOG" | tail -1 > $D/encoder.txt
cat $D/page.log $D/encoder.txt
