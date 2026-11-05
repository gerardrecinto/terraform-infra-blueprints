# On-premises to cloud migration plan (design only)

Status: design. No migration was run from this plan. The pieces it uses that do exist in this repo: `AWS/modules/dr_failover` (weighted DNS with health checks), `Akamai/modules/gtm_failover` (global traffic switch), `drills/pull-the-plug` (a measured switch), `drills/migration-cutover` (a runnable rehearsal of the cutover steps below on one machine), `AWS/modules/eks` and `ansible/` (the target cluster and its upgrades).

## Waves

1. Inventory and dependencies. List every service, its data stores, the hostnames and ports it talks to, and its owner. Draw the call graph. Anything with an unknown owner or an undocumented dependency is not ready to move.
2. Pilot with one low-risk service. Pick a stateless service with an owner who will watch it. Goal: prove the pipeline, network path, secrets and monitoring, not move a lot.
3. Stateless services next, in order of fewest dependencies. Build once, deploy the same image to both sites.
4. Stateful services last. Replicate data first (read replica or change stream), verify row counts and checksums, then cut over.

## Cutover for each service

1. Run both sites. The cloud copy takes no traffic.
2. Shift traffic by weight: 1%, 10%, 50%, 100%, holding at each step long enough to see the error rate and p99 latency of both sites. Weighted DNS or a global traffic manager does this; keep the DNS TTL at 30 to 60 seconds so a step takes effect fast.
3. Roll back by setting the cloud weight to 0. Rollback must be tested before step 2 starts, not discovered during an incident.
4. Keep the on-premises copy running for a full business cycle after 100%, then decommission.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hidden dependency on an on-premises service or hardcoded IP | Inventory plus a connection log from the old host before cutover |
| Data drift between sites during dual run | Single writer, checksum comparison, cut writes over once |
| Latency to data left on premises | Move the service and its data together, or add a cache; measure before the 10% step |
| DNS caching holds clients on the old site | Low TTL set at least one old-TTL ahead of the first shift |
| Compliance or access rules differ in the cloud | Map controls first (`docs/compliance-controls-map.md`), review with security before the pilot |
| Cost surprise | Tag every resource from day one (`AWS/modules/cost_tagging`) and review spend weekly during dual run |

## What this is not

It is not a record of a migration I led. It is how I would run one, built from the pieces above.
