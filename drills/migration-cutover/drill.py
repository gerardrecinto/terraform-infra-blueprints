#!/usr/bin/env python3
"""On-premises to cloud migration drill, local only.

Seeds the legacy database, copies it to the new one and proves the copy with a row count and
a checksum, then shifts traffic from the legacy app to the new one in steps while sending a
request every 100 ms. Halfway the new app is stopped to stand in for a bad release, traffic
goes back to legacy, the new app returns, and the shift is run again to 100 percent.
Needs Docker and Python 3. Standard library only. About 60 seconds.
"""
import json
import subprocess
import sys
import threading
import time
import urllib.request

URL = "http://127.0.0.1:18090/"
HOLD = 4.0
log, stop_probe = [], threading.Event()


def sh(*cmd, inp=None, check=True):
    p = subprocess.run(cmd, input=inp, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{p.stderr}")
    return p.stdout.strip()


def psql(container, sql):
    return sh("docker", "exec", container, "psql", "-U", "postgres", "-d", "shop", "-At", "-c", sql)


def set_weights(legacy, cloud):
    for name, w in (("legacy", legacy), ("cloud", cloud)):
        sh("docker", "exec", "mig-proxy", "sh", "-c", f'echo "set server sites/{name} weight {w}" | nc 127.0.0.1 9999')


def probe():
    while not stop_probe.is_set():
        t = time.time()
        try:
            with urllib.request.urlopen(URL, timeout=1) as r:
                log.append((t, r.read().decode().strip(), True))
        except Exception:
            log.append((t, None, False))
        time.sleep(max(0, 0.1 - (time.time() - t)))


def window(start, end):
    rows = [r for r in log if start <= r[0] < end]
    return {"sent": len(rows), "failed": sum(1 for r in rows if not r[2]),
            "legacy": sum(1 for r in rows if r[1] == "legacy"), "cloud": sum(1 for r in rows if r[1] == "cloud")}


def main():
    sh("docker", "compose", "up", "-d")
    try:
        for _ in range(40):
            try:
                if urllib.request.urlopen(URL, timeout=1).read().decode().strip() == "legacy":
                    break
            except Exception:
                time.sleep(1)
        for c in ("mig-legacy-db", "mig-cloud-db"):
            for _ in range(40):
                if sh("docker", "exec", c, "pg_isready", "-U", "postgres", "-d", "shop", check=False).endswith("accepting connections"):
                    break
                time.sleep(1)

        print("1. seed the legacy database (50,000 orders)")
        psql("mig-legacy-db", "create table orders as select g as id, md5(g::text) as sku, (g % 97) * 1.5 as amount from generate_series(1,50000) g; alter table orders add primary key (id);")

        print("2. copy it to the cloud database and verify")
        dump = sh("docker", "exec", "mig-legacy-db", "pg_dump", "-U", "postgres", "shop")
        sh("docker", "exec", "-i", "mig-cloud-db", "psql", "-U", "postgres", "-d", "shop", inp=dump)
        q = "select count(*) || ' rows, checksum ' || md5(string_agg(id || sku || amount, ',' order by id)) from orders"
        a, b = psql("mig-legacy-db", q), psql("mig-cloud-db", q)
        print(f"   legacy: {a}\n   cloud:  {b}")
        if a != b:
            sys.exit("   copy does not match; stop here and do not shift traffic")

        threading.Thread(target=probe, daemon=True).start()
        time.sleep(1)
        results = []

        def step(label, legacy, cloud, action=None):
            set_weights(legacy, cloud)
            t0 = time.time()
            if action:
                action()
            time.sleep(HOLD)
            results.append((label, window(t0, time.time())))

        print("3. shift traffic in steps")
        step("cloud 10%", 90, 10)
        step("cloud 50%", 50, 50)
        step("bad release: cloud app stopped at 50%", 50, 50, lambda: sh("docker", "stop", "-t", "1", "mig-cloud-app"))
        step("rollback: cloud 0%", 100, 0)
        step("cloud app restored, still 0%", 100, 0, lambda: sh("docker", "start", "mig-cloud-app"))
        step("retry cloud 10%", 90, 10)
        step("retry cloud 50%", 50, 50)
        step("cutover: cloud 100%", 0, 100)
        stop_probe.set()
        time.sleep(0.3)

        print(f"\n{'step':42} {'sent':>5} {'failed':>7} {'legacy':>7} {'cloud':>6}")
        for label, w in results:
            print(f"{label:42} {w['sent']:>5} {w['failed']:>7} {w['legacy']:>7} {w['cloud']:>6}")
        ok = results[-1][1]["failed"] == 0 and results[-1][1]["legacy"] == 0
        print("\ncutover clean: all final-step requests served by cloud with no failures" if ok else "\ncutover NOT clean")
        return 0 if ok else 1
    finally:
        stop_probe.set()
        subprocess.run(["docker", "compose", "down", "-v"], capture_output=True)


if __name__ == "__main__":
    sys.exit(main())
