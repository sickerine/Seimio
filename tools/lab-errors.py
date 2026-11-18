#!/usr/bin/env python3
"""The warnings and errors the app on the TV reported (LogTap.watch: a handler that threw, a binding that
read nothing) in the lab reports written in the last N seconds (default 600). Exits 1 if there are any.
usage: python3 -I tools/lab-errors.py [seconds]"""
import json, os, sys, time
reports = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".lab", "reports")
since, seen = time.time() - float(sys.argv[1] if len(sys.argv) > 1 else 600), []
for f in sorted(os.listdir(reports), key=lambda f: os.path.getmtime(os.path.join(reports, f))):
    path = os.path.join(reports, f)
    if "design" not in f or os.path.getmtime(path) < since: continue
    try: errors = json.load(open(path)).get("errors", [])
    except ValueError: continue
    for e in errors:
        if e not in seen: seen.append(e); print(e[:300])
print(f"{len(seen)} error(s)" if seen else "no errors reported")
sys.exit(1 if seen else 0)
