#!/usr/bin/env python3
"""One summary line per JSON result (stdin or files)."""
import json, sys, fileinput
for line in fileinput.input():
    line = line.strip()
    if not line.startswith('{'):
        continue
    d = json.loads(line)
    print(f"{d['label']:46s} got {d['got']:5d} lost {d['lost']:3d} drop {d['srcDrops']:3d} "
          f"lat50 {d['lat50']:6.1f} ser95 {d['ser95']:6.1f} ser99 {d['ser99']:6.1f} max {d['latMax']:6.1f} "
          f">50ms {d['over50ms']:3d} >100 {d['over100ms']:3d} hitch {d['hitches']:3d} nack {d['nacks']:4d}")
