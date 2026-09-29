#!/bin/zsh
# usage: capture.sh label -> page up, settle, fetch receiver's decoded frame
S=/private/tmp/claude-501/-Users-mnml-git-opensidecar/606d6027-f0b4-41ae-babb-660433ec8b35/scratchpad
D=$S/cap/$1; mkdir -p $D
$S/testpage $D > $D/page.log 2>&1 & P=$!
sleep 8; ssh imac 'rm -f /tmp/od-idle.png'; sleep 1
# nudge one frame so the dumper runs even if the stream already went idle
ssh imac 'touch /tmp/od-dump-request'; sleep 6
scp -q imac:/tmp/od-idle.png $D/recv.png; kill $P
grep "encoder ready" "$HOME/Library/Logs/OpenDisplay Dev/opendisplay.log" | tail -1 > $D/encoder.txt
cat $D/page.log $D/encoder.txt; sips -g pixelWidth -g pixelHeight $D/recv.png | tail -2
