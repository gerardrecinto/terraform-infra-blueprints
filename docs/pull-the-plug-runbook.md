# Runbook: "Pull the Plug" traffic switch between sites

**TL;DR: Drain one site by setting its weight to 0 in `AWS/modules/dr_failover`, apply, and confirm traffic and errors on the surviving site before touching the drained one. Rehearse it on a schedule, because an untested failover is a guess.**

This is a reference runbook for the weighted-DNS pattern in `AWS/modules/dr_failover`. Adapt names, thresholds and approvers to your environment. The same steps apply when a global load balancer (for example Akamai GTM) fronts the sites; only the place where weights are set changes.

## Terms

- **Site:** a data center or cloud region that can serve the whole service on its own.
- **Drain:** send a site no new traffic while existing requests finish.
- **Pull the plug:** a planned, controlled test or maintenance event that turns a site off to prove the other site carries the load.

## Before you start (go / no-go)

| Check | Pass condition |
|---|---|
| Capacity | The surviving site runs at no more than 60% of its capacity at today's peak, so it can absorb 100% of traffic |
| Data | Replication lag is below the agreed recovery point; no failed or paused replication |
| Health | Both sites are healthy in Route 53 and in your own dashboards |
| Dependencies | Databases, queues, caches, auth and third parties used by the service are reachable from the surviving site |
| Change control | Change ticket approved, comms sent, on-call and incident commander named, rollback owner named |
| Timing | Outside peak traffic and release freezes; DNS TTL is 60 seconds or lower and has been for at least one old-TTL period |

If any check fails, stop and fix it first.

## Steps

1. **Baseline.** Record current error rate, p99 latency, request rate per site and replication lag.
2. **Shift in stages.** Change weights, plan and apply (for example 50/50 to 80/20, then 100/0). Watch each stage for at least 2 TTLs.
   ```hcl
   endpoints = {
     dc-east  = { target = "east.example.internal", weight = 0 }    # site being drained
     aws-west = { target = "west.example.internal", weight = 100 }
   }
   ```
3. **Verify the drain.** `dig +short app.example.com` from several networks returns only the surviving site; request rate on the drained site falls to near zero; errors and p99 on the surviving site stay inside the objective.
4. **Do the work or hold the test.** Maintenance, or the failure exercise, on the drained site.
5. **Restore in stages.** Reverse the weights in the same steps, watching error rate and replication catch-up.
6. **Close out.** Record timings, surprises and follow-ups; update the capacity and runbook numbers.

## Abort and rollback

Abort and restore the previous weights if the surviving site's error rate, p99 latency or saturation exceeds the stop condition (agree it beforehand, for example error rate above 1% for 5 minutes, or p99 above 2x baseline). Revert is the same change in reverse and takes effect within about one TTL.

## Unplanned failure

The health checks in the module remove a site that fails `failure_threshold` checks in a row (about `failure_threshold * request_interval` seconds, plus one TTL for caches). The same capacity and data checks apply; the difference is that nobody chose the moment. That is why the planned rehearsal matters.

## Rehearsal schedule

- Every quarter for a tier-1 service; after any architecture change; and after any change to capacity.
- Record the measured time to drain, time to recover and customer impact, and compare with the target.
