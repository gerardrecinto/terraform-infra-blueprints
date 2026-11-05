#!/usr/bin/env python3
"""Turn the probe log into failover and failback numbers."""
import json, sys

log, stop, start = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = [json.loads(l) for l in open(log)]

def first(site, after):
    for r in rows:
        if r["t"] >= after and r["ok"] and r["site"] == site:
            return r["t"]
    return None

failed = [r for r in rows if not r["ok"]]
west = first("dc-west", stop)
back = first("dc-east", start)
print(f"requests sent:            {len(rows)}")
print(f"requests that failed:     {len(failed)}")
print(f"served by dc-east:        {sum(1 for r in rows if r['site'] == 'dc-east')}")
print(f"served by dc-west:        {sum(1 for r in rows if r['site'] == 'dc-west')}")
print(f"failover (plug to dc-west answering): {west - stop:.1f}s" if west else "failover: dc-west never answered")
print(f"failback (restart to dc-east answering): {back - start:.1f}s" if back else "failback: dc-east never answered again")
if failed:
    span = failed[-1]["t"] - failed[0]["t"]
    print(f"failed requests spanned:  {span:.1f}s ({failed[0].get('err')})")
ok = west is not None and back is not None
sys.exit(0 if ok else 1)
