#!/bin/zsh
# Interleaved runs of every mode over one link; appends JSON lines to $OUT.
# usage: matrix.sh <host> <linklabel> <rounds> <seconds> <trace...>
# env: LOAD=1 runs a bulk TCP upload to the receiver alongside (a big file copy).
host=$1 link=$2 rounds=$3 secs=$4; shift 4
D=${0:A:h}/../../build/transport
OUT=${OUT:-$D/results.jsonl}
modes=(${=MODES:-tcp quic1 quicN udp udpnack qdgram qdgramnack})
for r in $(seq $rounds); do
  for t in "$@"; do
    for m in $modes; do
      extra=()
      [[ $m == *:* ]] && { extra=(${(s:,:)${m#*:}}); m=${m%%:*}; }
      variant=${(j:,:)extra}
      label="$link|${LOAD:+load|}${t:t:r}|$m${variant:+/${variant//=/-}}|r$r"   # no "=": nettest reads k=v as options
      line=$("$D/nettest" send $host $m "$D/$t" $secs "$label" $extra 2>&1 | grep '^{')
      echo "$line" >> $OUT
      [[ -n $line ]] && echo "$line" | python3 ${0:A:h}/fmt.py || echo "$label FAILED"
    done
  done
done
