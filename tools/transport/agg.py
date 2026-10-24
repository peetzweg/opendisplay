#!/usr/bin/env python3
"""Aggregate results.jsonl: per link+trace+mode, mean of typical and worst-case numbers across rounds."""
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
g = collections.OrderedDict()
for d in rows:
    parts = d['label'].split('|')
    if len(parts) < 3:            # labels from an older runner lost the variant
        continue
    key = '|'.join(p for p in parts if not p.startswith('r'))
    g.setdefault(key, []).append(d)
print(f"{'link|trace|mode':40s} n  lat50  p95   p99   worst(each run)       >100ms  lost  srcdrop")
for k, v in g.items():
    m = lambda f: sum(x[f] for x in v) / len(v)
    print(f"{k:40s} {len(v)}  {m('lat50'):5.1f} {m('ser95'):5.1f} {m('ser99'):5.1f}  {','.join(str(round(x['latMax'])) for x in v):20s} {sum(x['over100ms'] for x in v):5d} {sum(x['lost'] for x in v):5d} {sum(x['srcDrops'] for x in v):5d}")
