# Threat model: web service on EKS behind a WAF

**TL;DR: A STRIDE walk-through for the reference stack in this repository (CDN or load balancer, WAF, EKS workload, managed data store). It lists each threat, the control in this repo that addresses it, and the gap you still own.**

Scope: the `AWS/modules/waf_ddos` web ACL, an ALB, a workload deployed with `helm/charts/web-service` on EKS, IRSA for AWS access, and a managed data store. This is a template for a first assessment, not an audit result.

## Data flow

```text
client -> (CDN) -> WAF -> ALB -> ingress -> pod (web-service) -> data store / AWS APIs (via IRSA)
                      logs -> CloudWatch (redacted)        metrics -> Prometheus -> alerts
trust boundaries: internet | edge (WAF/ALB) | cluster network | data tier | AWS control plane
```

## STRIDE

| Threat | Example | Control in this repo | Gap you still own |
|---|---|---|---|
| Spoofing | Stolen session or forged token | Short-lived IRSA credentials instead of static keys; authorization headers redacted in WAF logs | Application authentication and session design, MFA |
| Tampering | SQL injection, request manipulation | WAF managed rules (common exploits, SQLi, known bad inputs); read-only root filesystem and no privilege escalation in the chart | Input validation in the application; signed images and admission checks |
| Repudiation | "I never made that change" | Terraform plan and apply through pull requests; WAF full logs retained for `log_retention_days` | Immutable central audit logging and retention policy |
| Information disclosure | Credentials in logs, over-broad IAM | `redacted_headers`; no secrets in values (the chart references Secrets by name); per-service IAM role through IRSA | Secret rotation, encryption at rest, data classification |
| Denial of service | Request flood, credential stuffing | Per-IP rate rule; optional Shield Advanced protection; HPA, zone spread and PodDisruptionBudget in the chart | Capacity planning, CDN absorption, application-layer rate limits |
| Elevation of privilege | Container breakout, lateral movement | Non-root, all capabilities dropped, seccomp RuntimeDefault, NetworkPolicy default allow-list | Node hardening, pod security admission, cluster RBAC review |

## Top risks and next steps

1. **Rate rule tuned wrongly.** Start in `rate_limit_action = "count"`, study sampled requests, then block.
2. **Managed rules block legitimate traffic.** Roll new groups out with `count_only = true` first.
3. **Egress is open on 443.** Tighten `networkPolicy.egressExtra` and use a proxy or VPC endpoints for known destinations.
4. **No admission control in this repo.** Add a policy engine or admission webhook that verifies image signatures and the pod security settings.
