# terraform-infra-blueprints

**New here?** A library of ready-made building blocks for setting up cloud servers, storage and networks, written as code so a team can review and reuse them.

It is for platform and DevOps engineers who want reviewed Terraform modules to read, validate and adapt on AWS, Azure, GCP, AliCloud, OpenStack and on-prem. Browse the catalog: https://gerardrecinto.github.io/terraform-infra-blueprints/

## Validate one module

```bash
git clone https://github.com/gerardrecinto/terraform-infra-blueprints.git
cd terraform-infra-blueprints/AWS/modules/s3_lifecycle
terraform init -backend=false
terraform validate
```

This needs git and Terraform 1.7 or later. It uses no cloud credentials and creates nothing. The first `init` downloads the AWS provider and can take a few minutes. CI runs this module validation and the credential-free mocked plan tests below on Terraform 1.9.8.

## What it does and does not do

Does:
- Gives you modules and workflows for Kubernetes, storage tiering, private connectivity and observability, with every input described and many checked at plan time.
- Checks itself in CI: formatting, `terraform validate`, a Trivy misconfiguration scan, Terragrunt validation, Helm lint and render tests, and ansible-lint.

Does not:
- Prove any module works in a real account. Nothing here has been applied as part of this repo, and no production result is claimed.
- Replace your own review. Treat everything as a reviewed starting point.

<details>
<summary><b>Design principles</b></summary>

**Separation of concerns at every layer.** Helm release versions, replica counts, and chart config live in Terraform, not ad-hoc `helm upgrade` commands. ConfigMaps that drive runtime behavior are Terraform resources with full audit trail and PR-based change control.

**Ephemeral state handled at the IaC layer.** Pod IPs are transient. Rather than fighting this, modules use `data "kubernetes_pod_v1"` to query live cluster state and converge AWS resources (NLB target groups) to match. Every `terraform apply` is a reconciliation loop.

**Least-privilege exposure by design.** PrivateLink keeps cross-account traffic off the public internet. Separate NLB target groups per gateway type enforce protocol-level isolation. `target_type = ip` bypasses NodePort NAT and preserves source IP end-to-end.

**Everything version-controlled, nothing click-ops.** IAM roles, Cognito federation, Grafana alert rules, ACR cleanup tasks: all Terraform resources. If it can't be reviewed in a PR and rolled back with a revert, it doesn't exist in production.

**Bad input fails at plan time, not three resources deep in a provider error.** Every input variable across the modules and workflows in this repo has a `description`, and the ones with a real constraint (environments, CIDR blocks, retention windows, percentage thresholds, SQS/Log Analytics service limits) have a `validation` block enforcing it. `terraform plan` should tell you `environment must be one of: dev, staging, prod`, not fail an hour later on a resource that silently accepted garbage.

</details>

<details>
<summary><b>Structure</b></summary>

```
AWS/
├── modules/
│   ├── eks/               multi-account EKS: OIDC, CNI custom networking, Linux/Windows node groups
│   ├── privatelink/       cross-account endpoint service + consumer (SSH/ADB, MSK, internal APIs)
│   ├── s3_lifecycle/      Standard → IA → Glacier Deep Archive, KMS enforcement
│   ├── grafana_alerting/  Grafana rules for ALBs (5XX, P99), MSK, SQS, PrivateLink
│   ├── nginx_ingress/     NGINX on NLB, TCP ConfigMap, dynamic pod IP NLB target registration
│   ├── sqs_sns/           SQS + SNS with DLQ, FIFO, cross-service subscriptions
│   ├── opensearch/        OpenSearch with Cognito/SAML SSO + Azure AD OIDC
│   ├── waf_ddos/          WAFv2 web ACL: IP block lists, per-IP rate limit, managed rules, redacted logs, optional Shield Advanced
│   └── dr_failover/       Route 53 weighted records with health checks for draining and switching traffic between sites
└── workflows/
    ├── deploy_eks/        EKS cluster provisioning (EKS Auto Mode, Helm/K8s providers)
    ├── blue_green_eks/    zero-downtime EB → EKS via ALB weighted target groups
    └── opensearch_migration/ on-prem ES → AWS OpenSearch with Cognito + Azure AD SSO

Azure/
├── modules/
│   ├── aks/               Azure AD RBAC, workload identity, ACR integration, Container Insights
│   └── acr/               geo-replication, weekly untagged image cleanup Task
└── workflows/
    └── deploy_aks_logging/ FluentBit → Event Hubs → Logstash → OpenSearch → Grafana

GCP/
├── modules/
│   ├── apigee/            Apigee X org + env + instance; JS token auth; path routing; SpikeArrest
│   ├── gke/               private cluster: Workload Identity, Binary Authorization, Shielded Nodes
│   └── gcs_lifecycle/     Standard → Nearline → Coldline → Archive with CMEK
└── workflows/
    └── deploy_apigee_proxies/ three example API proxies with token auth + path routing

AliCloud/
├── modules/
│   ├── ack/               managed CS Kubernetes: RAM node role, tainted batch pool, auto-upgrade window
│   ├── oss_lifecycle/     Standard → IA → Archive → Cold Archive, KMS, versioning, public access block
│   └── api_gateway/       throttled API group + app credential fronting backend services
└── workflows/
    └── deploy_ack/        ACK cluster + log bucket + internal status API, composed together

OpenStack/
├── modules/
│   ├── magnum_k8s/        Magnum-managed Kubernetes: cluster template + cluster, Calico networking
│   ├── swift_lifecycle/   per-object expiry retention + dedicated versions container
│   └── octavia_ingress/   HTTPS listener, round-robin pool, active health checks, member registration
└── workflows/
    └── deploy_magnum_k8s/ Magnum cluster + Swift backups + Octavia ingress, composed together

helm/
└── charts/web-service/    production-oriented Helm chart for EKS: rolling updates, probes, HPA, PDB, zone spread, NetworkPolicy, IRSA

ansible/
└── playbooks/k8s-rolling-node-upgrade.yml   cordon, drain, upgrade, verify and uncordon kubeadm workers one at a time

live/
├── root.hcl                                shared locals: cloud/environment derived from the folder path
├── alicloud/{dev,prod}/ack/                dev + prod units for AliCloud/workflows/deploy_ack
├── openstack/{dev,prod}/magnum_k8s/        dev + prod units for OpenStack/workflows/deploy_magnum_k8s
├── gcp/{dev,prod}/apigee_proxies/          dev + prod units for GCP/workflows/deploy_apigee_proxies
├── aws/{dev,prod}/blue_green_eks/          dev + prod units for AWS/workflows/blue_green_eks
├── aws/{dev,prod}/opensearch_migration/    dev + prod units for AWS/workflows/opensearch_migration
└── azure/{dev,prod}/aks_logging/           dev + prod units for Azure/workflows/deploy_aks_logging
```

</details>

<details>
<summary><b>AWS Modules</b></summary>

### `modules/s3_lifecycle`

Tiered log storage: Standard → Standard-IA → Glacier Deep Archive, with KMS enforcement and optional cross-region replication. This models a common cost-optimization pattern for large, append-only log buckets where recent data needs fast access and older data can move to cold storage.

```hcl
module "log_archive" {
  source = "./AWS/modules/s3_lifecycle"

  bucket_name                = "app-logs-prod"
  environment                = "prod"
  log_prefix                 = "logs/"
  transition_to_glacier_days = 90
  kms_key_arn                = var.kms_key_arn
  enforce_encryption_policy  = true
  replication_regions        = [] # destinations and KMS replication require separate setup
}
```

The lifecycle day counts are object ages, not time spent in the previous tier. Standard-IA starts at day 30 or later. Deep Archive starts at least 30 days after Standard-IA, and expiration is either disabled (`0`) or later than the archive transition. These constraints fail during planning. Early deletion can still incur minimum storage charges. See the [AWS lifecycle constraints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html).

Run the plan regression tests without AWS credentials or resources (Terraform 1.7 or later):

```bash
terraform -chdir=AWS/modules/s3_lifecycle init -backend=false
terraform -chdir=AWS/modules/s3_lifecycle test
```

Replication destinations are not created by this module. Read the [replication prerequisites and current limits](AWS/modules/s3_lifecycle/README.md) before enabling it.

Same module, same behavior, ported to Pulumi (TypeScript): [`Pulumi/aws-s3-lifecycle`](Pulumi/aws-s3-lifecycle/). Written for a direct side-by-side comparison of the two IaC models on one real module rather than a comparison writeup with no code behind it.

### `modules/eks`

Multi-account EKS with VPC CNI custom networking, OIDC federation, mixed Linux/Windows node groups:

```hcl
module "eks" {
  source = "./AWS/modules/eks"

  cluster_name    = "platform-prod"
  cluster_version = "1.31"
  environment     = "prod"
  vpc_id          = "vpc-0abc123"
  subnet_ids      = ["subnet-aaa", "subnet-bbb"]

  cni_custom_networking_enabled = true
  eni_config_subnets = {
    "us-west-2a" = "subnet-100a"
    "us-west-2b" = "subnet-100b"
  }

  linux_node_groups = {
    general = {
      instance_types = ["m6i.xlarge"]
      min_size       = 2
      max_size       = 10
      desired_size   = 3
      capacity_type  = "ON_DEMAND"
    }
  }
}
```

### `modules/nginx_ingress`

NGINX on NLB for an SSH/ADB-style device gateway plus a general streaming target. The hard problem is ephemeral pod IPs: NLB `target_type = ip` registers pod IPs directly (preserves source IP for SSH auth), but pod IPs change on every rollout. The module uses `data "kubernetes_pod_v1"` + `for_each` so every `terraform apply` re-syncs NLB targets to actual pod state.

```
Traffic path:
  Consumer VPC
    └─ VPC Endpoint (PrivateLink)
         └─ NLB (internal)
              ├─ Target Group: ssh_adb (port 22, target_type=ip)
              │    └─ pod IPs registered dynamically via for_each
              └─ Target Group: streaming (port 443, target_type=ip)
                   └─ source IP sticky → NGINX TCP stream → pod
```

### `modules/grafana_alerting`

Terraform-managed Grafana alert rules for ALBs, MSK, and SQS, parameterized by ARN suffixes and thresholds so the same module can be reused across environments:

```hcl
module "grafana_alerts" {
  source = "./AWS/modules/grafana_alerting"

  environment        = "prod"
  alb_arn_suffixes   = [module.alb_app_a.arn_suffix, module.alb_app_b.arn_suffix]
  alb_5xx_threshold  = 10
  alb_latency_p99_ms = 2000
  msk_cluster_name   = "events-prod"
  sqs_queue_names    = ["event-queue-prod", "release-queue-prod"]
  slack_webhook_url  = var.slack_webhook
}
```

### `modules/waf_ddos`

WAFv2 web ACL for a public web tier: explicit IPv4 and IPv6 block lists, a per-IP rate rule (block or count), AWS managed rule groups (common exploits, known bad inputs, SQL injection, IP reputation), full logging to CloudWatch with credential headers redacted, and optional Shield Advanced protections. New limits can be rolled out in `count` mode first.

```hcl
module "waf" {
  source = "./AWS/modules/waf_ddos"

  name                    = "storefront"
  environment             = "prod"
  associate_resource_arns = [aws_lb.public.arn]
  rate_limit_per_5min     = 2000
  rate_limit_action       = "count" # observe first, then switch to "block"
  blocked_ipv4_cidrs      = ["203.0.113.0/24"]
}
```

Reference implementation: it carries no production metrics, and every limit should be tuned against real traffic. Threat model: [docs/threat-model-web-service.md](docs/threat-model-web-service.md).

### `modules/dr_failover`

Weighted Route 53 records with a health check per site. Normal traffic follows the weights; a planned drain sets a site's weight to 0; a failing site is removed automatically by its health check. Validation rejects a single-site setup and an all-zero weight set (which Route 53 treats as equal weights).

```hcl
module "traffic" {
  source = "./AWS/modules/dr_failover"

  zone_id     = var.zone_id
  record_name = "app.example.com"
  ttl         = 30

  endpoints = {
    dc-east  = { target = "east.example.internal", weight = 0 }   # drained
    aws-west = { target = "west.example.internal", weight = 100 }
  }
}
```

Procedure and abort criteria: [docs/pull-the-plug-runbook.md](docs/pull-the-plug-runbook.md).

</details>

<details>
<summary><b>Azure</b></summary>

### `modules/aks`

AKS with a private control-plane endpoint, Microsoft Entra RBAC, local administrator credentials disabled, workload identity (OIDC issuer), ACR pull role, Container Insights and auto-scaling node pools. Clients need private network and DNS access. The enterprise workflow requires an Entra tenant ID and uses Calico with Azure CNI Overlay. See the [security review and remaining findings](docs/SECURITY_REVIEW.md).

### `workflows/deploy_aks_logging`

Example telemetry logging stack:

| Component | Role |
|---|---|
| FluentBit DaemonSet | Tails all pod logs → Event Hubs (Kafka protocol) |
| Azure Event Hubs | Kafka-compatible message bus |
| Logstash | Parses, enriches, indexes to OpenSearch |
| OpenSearch (on AKS) | Log storage and full-text search |
| Grafana | Dashboards, internal LoadBalancer |

</details>

<details>
<summary><b>GCP</b></summary>

### `modules/apigee`

Apigee X setup with org/env/instance provisioning. Proxy bundles are rendered from templates via `archive_file`. Each bundle includes JS-ValidateToken (Bearer token introspection), JS-PathRouter (dynamic `target.url`), and SpikeArrest (600 req/min). This is a pattern for consolidating many single-purpose API proxies into fewer parameterized ones, reducing duplicated auth and routing logic across an org.

### `modules/gke`

Private, VPC-native GKE with Workload Identity, Binary Authorization, Shielded Nodes, and REGULAR release channel auto-upgrades.

### `workflows/deploy_apigee_proxies`

Three example proxies showing the path-routing and token-auth pattern:

| Proxy | Base Path | Routes |
|---|---|---|
| device-api | `/device-api/v2` | `/devices`, `/ssh`, `/workspaces`, `/builds` |
| package-api | `/package-api/v2` | `/packages`, `/download`, `/catalog`, `/releases` |
| inference-api | `/inference-api/v2` | `/models`, `/inference`, `/benchmarks`, `/compile`, `/profile` |

</details>

<details>
<summary><b>AliCloud</b></summary>

### `modules/ack`

Managed Container Service for Kubernetes: least-privilege worker RAM role, autoscaling node pools split by workload class (general vs. taint-isolated batch), security-hardened OS images, and a weekly maintenance window instead of ad-hoc master upgrades.

### `modules/oss_lifecycle`

Standard to IA to Archive to Cold Archive tiering, KMS or AES256 encryption, versioning, public access block, and access logging, the OSS equivalent of the AWS `s3_lifecycle` and GCP `gcs_lifecycle` modules.

### `modules/api_gateway`

API group and throttled routes fronting backend services, consolidating per-service auth and rate limiting behind one app credential instead of duplicating it downstream.

### `workflows/deploy_ack`

Composes all three: an ACK cluster with a general pool and a tainted batch pool, an OSS bucket for cluster logs on a short retention schedule, and an internal API Gateway route fronting the cluster's status endpoint.

</details>

<details>
<summary><b>OpenStack</b></summary>

### `modules/magnum_k8s`

Managed Kubernetes on private OpenStack clouds via Magnum: a cluster template pinning image, flavors, and Calico networking, then a cluster resource built from it so a fleet-wide upgrade is one template change instead of N cluster edits.

### `modules/swift_lifecycle`

Swift has no native storage-class tiering like the hyperscalers, so retention here is enforced through per-object expiry headers set by callers, plus a dedicated versions container so overwritten objects survive until they expire rather than disappearing immediately.

### `modules/octavia_ingress`

Standalone Octavia load balancer with an HTTPS listener, a round-robin backend pool, active health checks, and member registration driven by a map of backend addresses, the OpenStack equivalent of the AWS `nginx_ingress` module.

### `workflows/deploy_magnum_k8s`

Composes all three: a Magnum cluster sized by environment (3 masters in prod, 1 elsewhere), a Swift container for backups, and an Octavia load balancer fronting the cluster's ingress nodes.

</details>

<details>
<summary><b>Terragrunt</b></summary>

The `workflows/` directories above are plain Terraform root modules: each one is runnable on its own with its own `terraform init`. `live/` is a thin Terragrunt layer on top of six of them, for the actual reason teams reach for Terragrunt: running the same workflow for more than one environment without copy-pasting the whole module tree per environment.

```
live/
├── root.hcl                                shared locals: derives cloud/environment from the folder path
├── alicloud/{dev,prod}/ack/                both point at AliCloud/workflows/deploy_ack
├── openstack/{dev,prod}/magnum_k8s/        both point at OpenStack/workflows/deploy_magnum_k8s
├── gcp/{dev,prod}/apigee_proxies/          both point at GCP/workflows/deploy_apigee_proxies
├── aws/{dev,prod}/blue_green_eks/          both point at AWS/workflows/blue_green_eks
├── aws/{dev,prod}/opensearch_migration/    both point at AWS/workflows/opensearch_migration
└── azure/{dev,prod}/aks_logging/           both point at Azure/workflows/deploy_aks_logging
```

Each leaf `terragrunt.hcl` is a handful of lines: an `include` of `root.hcl`, a `terraform.source` pointing at the workflow, and an `inputs` block with that environment's values (smaller node counts and single-AZ networking in dev, multi-AZ and real capacity in prod). `root.hcl` derives `environment` from the directory path itself (`path_relative_to_include()`), so it is never typed twice: get it from the folder you're standing in, not a variable a future edit can forget to change.

Two things worth knowing if you try this yourself:
- `source` uses Terragrunt's `parent//subdir` syntax (`AliCloud//workflows/deploy_ack`, not `AliCloud/workflows/deploy_ack`). These workflows call sibling modules via `../../modules/x`; without the `//`, Terragrunt copies only the workflow directory into its run cache and that relative path breaks. This is a common gotcha with any local-module Terragrunt setup, not specific to this repo.
- Each `include` block sets `expose = true`. Without it, a child unit cannot read `include.root.locals.environment` at all, since Terragrunt does not merge an included config's `locals` into the child's scope unless it is explicitly exposed.

Every leaf here was run through `terragrunt run -- init -backend=false` and `terragrunt run -- validate` for real, plus `terragrunt hcl format --check` and `terragrunt hcl validate` across the whole `live/` tree, the same verification discipline as every other module in this repo.

</details>

<details>
<summary><b>secure-connectivity/</b></summary>

Four AWS connectivity modules: a public NGINX service, private SSM-only
compute access, an optional hardened access gateway, and a shared network
module. They show public-vs-private trust boundaries, identity-aware
administrative access and module composition. The two environment
capstones and the interview guide that the build plan mentions are not in
the repo yet; see [secure-connectivity/PROGRESS.md](secure-connectivity/PROGRESS.md)
for build status.

</details>

<details>
<summary><b>Helm chart</b></summary>

[`helm/charts/web-service`](helm/charts/web-service/) deploys a stateless HTTP service on Kubernetes and EKS with the settings that usually get missed: `maxUnavailable: 0` rolling updates with `progressDeadlineSeconds`, startup, liveness and readiness probes, graceful shutdown with a `preStop` sleep, an HPA with a slow scale-down, a PodDisruptionBudget, zone and node spread, a default-deny style NetworkPolicy, a restricted pod security context, IRSA through `serviceAccount.roleArn`, image pinning by digest, and a values schema. 18 pytest checks render the chart and assert these properties (`python -m pytest helm/tests`).

```bash
helm upgrade --install web helm/charts/web-service -n web --create-namespace \
  --set image.repository=ghcr.io/example/web --set image.digest=sha256:<digest> \
  --set serviceAccount.roleArn=arn:aws:iam::<account>:role/web
```

</details>

<details>
<summary><b>Ansible</b></summary>

[`ansible/playbooks/k8s-rolling-node-upgrade.yml`](ansible/) upgrades kubeadm workers one at a time with a health gate between nodes and leaves a failed node cordoned. Checked with `ansible-lint` (production profile) in CI; not run against a real cluster from this repository.

</details>

<details>
<summary><b>Compliance and operations notes</b></summary>

- [docs/compliance-controls-map.md](docs/compliance-controls-map.md): where SOC 2, PCI DSS and SOX control areas line up with these modules (supports evidence gathering; not a compliance claim).
- [docs/threat-model-web-service.md](docs/threat-model-web-service.md): STRIDE walk-through for the reference stack.
- [docs/pull-the-plug-runbook.md](docs/pull-the-plug-runbook.md): planned site drain and rehearsal.

</details>

<details>
<summary><b>Demo recording and notes</b></summary>

<img src="docs/assets/demo.gif" alt="Real terminal recording: terraform fmt -check across every module in this repo, then a trivy IaC security scan (config from trivy.yaml) that actually catches misconfigurations in secure-connectivity" width="820" />

> **Note:** This is a personal portfolio repository. Module design and provisioning patterns are original implementations inspired by common enterprise infrastructure problems. All company names, internal system names, account IDs, hostnames, ARNs, VPC CIDRs, and business metrics have been removed or replaced with generic placeholders. None of the figures or names in this repository refer to a real employer, deployment, or production outcome.

Commercial angle and consulting hooks: [docs/go-to-market.md](docs/go-to-market.md).

</details>

## License

MIT

Optional paid help: [scoped reviews and setup](SUPPORT.md).
