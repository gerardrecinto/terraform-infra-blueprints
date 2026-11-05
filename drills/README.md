# Drills

Three runnable drills that need only Docker, Python 3 and curl. Nothing leaves your machine and no cloud or vendor account is used.

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

## migration-cutover: move a service and its data in steps

```bash
cd drills/migration-cutover
python3 drill.py
```

A legacy stack and a "cloud" stack run side by side, each with its own Postgres. The drill seeds 50,000 orders in the legacy database, copies them with `pg_dump`, and compares a row count and a checksum before any traffic moves. Then it shifts traffic through a proxy in steps (10%, 50%), stops the new app at 50% to stand in for a bad release, rolls traffic back to 0%, restores the app and runs the shift again to 100%, sending a request every 100 ms and printing a table per step.

One laptop run: the copy matched (50,000 rows, same checksum), and the final step served 39 of 39 requests from the cloud side with no failures. No request failed at any step, because the proxy's health checks and retries hid the stopped app from the client. That tells you the rollback mechanism works, not that a real release would be this quiet.

Limits: the proxy weights stand in for weighted DNS or a global traffic manager, which add caching delay this drill does not have. The "data copy" is a one-time dump of a quiet database, not a live replication stream with writes in flight. It is a lab, not a record of a migration I led. The plan it follows is `docs/on-prem-to-cloud-migration-plan.md`.
