#!/bin/zsh
# usage: seq.sh label change|scroll N  -> saves up to N consecutive decoded frames
S=/private/tmp/claude-501/-Users-mnml-git-opensidecar/606d6027-f0b4-41ae-babb-660433ec8b35/scratchpad
RL='"$HOME/Library/Logs/OpenDisplay Receiver Dev/opendisplay.log"'
D=$S/cap/$1; rm -rf $D; mkdir -p $D; ssh imac 'rm -f /tmp/od-seq-*.png'
before=$(ssh imac "grep -c 'frame sequence dumped' $RL")
$S/testpage $D $2 $3 > $D/page.log 2>&1 & P=$!
[[ $2 == scroll ]] && { sleep 3; ssh imac "echo $3 > /tmp/od-dump-request"; }
for i in {1..60}; do sleep 2; [[ $(ssh imac "grep -c 'frame sequence dumped' $RL") -gt $before ]] && break; done
sleep 1; kill $P; scp -q 'imac:/tmp/od-seq-*.png' $D/
grep "encoder ready" "$HOME/Library/Logs/OpenDisplay Dev/opendisplay.log" | tail -1 > $D/encoder.txt
cat $D/encoder.txt; ls $D | grep -c od-seq
