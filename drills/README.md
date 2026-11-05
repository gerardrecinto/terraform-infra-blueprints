# Drills

Two runnable drills that need only Docker, Python 3 and curl. Nothing leaves your machine and no cloud or vendor account is used.

## pull-the-plug: switch traffic between two sites

```bash
cd drills/pull-the-plug
./drill.sh
```

Starts two nginx "data centers" behind a health-checking HAProxy that stands in for a global traffic manager, sends a request every 100 ms, stops the primary, then restarts it. Prints how many requests failed and how long failover and failback took. HAProxy is a stand-in: the matching Akamai configuration is `Akamai/modules/gtm_failover` (validated and plan-tested, never applied). The runbook is `docs/pull-the-plug-runbook.md`.

One laptop run: 315 requests, 4 failed, failover 4.1 s (includes the time `docker stop` takes to stop nginx), failback 1.8 s. These numbers move between runs and say nothing about a real data center or an Akamai property.

## apache-upgrade: upgrade httpd behind a gate

```bash
cd drills/apache-upgrade
./upgrade.sh                                                   # 2.4.58 to the latest 2.4, passes
./upgrade.sh 2.4.58-alpine 2.4-alpine conf/httpd.bad.conf      # config that cannot load, gate refuses
```

Runs the config test on the new version, starts it beside the live one, checks that `/`, `/healthz` and a security header match, then cuts over. A config that does not load stops at step 2 and leaves the live server untouched. This is a real Apache 2.4.58 to 2.4.69 upgrade of a small config. It is not an AEM upgrade: the AEM Dispatcher is an Apache module, but no AEM instance runs here.
