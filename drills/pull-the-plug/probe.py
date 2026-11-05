#!/usr/bin/env python3
"""Send one request every 100 ms and record who answered. Standard library only."""
import json, sys, time, urllib.request

url, seconds, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
end = time.time() + seconds
with open(out, "w") as f:
    while time.time() < end:
        t = time.time()
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                rec = {"t": t, "site": r.read().decode().strip(), "ok": r.status == 200}
        except Exception as e:
            rec = {"t": t, "site": None, "ok": False, "err": type(e).__name__}
        f.write(json.dumps(rec) + "\n")
        f.flush()
        time.sleep(max(0, 0.1 - (time.time() - t)))
