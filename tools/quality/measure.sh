#!/bin/zsh
# usage: measure.sh label  -> 35 s of motion, summary of the last 5 stats windows
# Needs exactly one OpenDisplay virtual screen (disconnect other receivers).
source "$(dirname "$0")/env.sh"
L=$SENDER_LOG
swift "$ROOT/tools/quality/motion.swift" >/dev/null 2>&1 & P=$!
sleep 36; kill $P
grep PHONE-STATS "$L" | tail -n 5 | python3 -c '
import sys,json,re,statistics as st
rows=[]
for l in sys.stdin:
    j=json.loads(l.split("PHONE-STATS ",1)[1].split(" | ")[0]); e=re.search(r"enc↓=(\d+) net↓=(\d+)",l)
    rows.append((j["fps"],j["enc50"],j["stalls"],j["e2e50"],j["e2e95"],int(e[1]),int(e[2]),j.get("capFps")))
k=["fps","enc50","stalls","e2e50","e2e95","encDrop","netDrop","capFps"]
print(sys.argv[1], " ".join(f"{n}={st.mean(r[i] for r in rows):.0f}" for i,n in enumerate(k)))' "$1"
