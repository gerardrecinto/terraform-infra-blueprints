# Compliance controls map (SOC 2, PCI DSS, SOX)

**TL;DR: This maps controls that the modules, chart and runbooks in this repository help to implement to the control areas auditors ask about. It supports evidence gathering. It is not a compliance claim: no audit has been performed against this repository, and each organization must confirm scope and evidence with its auditors.**

| Control area | What auditors look for | What this repository provides | Evidence to collect |
|---|---|---|---|
| **SOC 2 CC6.1 / CC6.3** Logical access, least privilege | Narrow, reviewed permissions; no shared static credentials | IRSA role per workload in the chart; no secrets in values; `serviceAccount.automountServiceAccountToken: false` by default | IAM role policies, access reviews |
| **SOC 2 CC6.6** Boundary protection | Controls at the network edge | WAF web ACL (`waf_ddos`) with managed rules, per-IP rate limit and block lists; chart NetworkPolicy | Web ACL configuration, rule metrics |
| **SOC 2 CC7.2** Monitoring and detection | Logged events, alerts on anomalies | WAF full logging with redaction; chart ServiceMonitor; Prometheus metric name for the rate rule | Log retention settings, alert rules, on-call records |
| **SOC 2 CC7.4 / A1.2** Incident response and recovery | Tested procedures | `pull-the-plug-runbook.md`; `dr_failover` health checks | Rehearsal records with timings |
| **SOC 2 CC8.1** Change management | Reviewed, tested, approved changes | Terraform changes by pull request, CI format and validate checks, `helm lint` and chart tests, Ansible lint | PR history, CI runs, approvals |
| **PCI DSS 1.x** Network security controls | Restrict traffic to and from the cardholder data environment | NetworkPolicy allow-lists, WAF in front of the web tier | Network diagrams, rule sets |
| **PCI DSS 6.4** Protect public-facing web applications | WAF or equivalent, ongoing vulnerability handling | `waf_ddos` module; container scanning in CI (Trivy) | WAF logs, scan reports |
| **PCI DSS 10.x** Log and monitor access | Logs retained and protected | WAF log group with retention, optional KMS key, header redaction | Retention configuration, access policy on logs |
| **SOX ITGC** Change management and segregation of duties | Changes traceable to an approved request; developers cannot push straight to production | Infrastructure as code with PR review; `plan` output kept as the change record | Branch protection settings, approvals, apply logs |

## Limits

- Controls here cover infrastructure patterns only; application, people and process controls are separate.
- Cardholder data scope, key management, vendor management, penetration testing and formal evidence collection are outside this repository.
- Treat "supports" as "helps produce evidence for". Your auditor decides whether a control is met.
