# Terraform

![Terraform Platform IaC logo](docs/assets/logo.svg)

Infrastructure-as-code across on-premises, AWS, Azure, GCP, AliCloud, and OpenStack. Reusable modules and environment-specific workflows covering EKS, AKS, GKE, ACK, Magnum, Apigee, PrivateLink, S3/OSS/Swift tiering, observability, and logging pipelines, with a Terragrunt layer for running the same workflow across multiple environments without copy-pasting it.

![Terraform](https://img.shields.io/badge/Terraform-1.7%2B-7B42BC?logo=terraform&logoColor=white)
![Terragrunt](https://img.shields.io/badge/Terragrunt-multi--env-4A4A4A?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EKS%20%7C%20S3%20%7C%20OpenSearch-FF9900?logo=amazon-aws&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-AKS%20%7C%20ACR-0089D6?logo=microsoft-azure&logoColor=white)
![GCP](https://img.shields.io/badge/GCP-GKE%20%7C%20Apigee%20X-4285F4?logo=google-cloud&logoColor=white)
![AliCloud](https://img.shields.io/badge/AliCloud-ACK%20%7C%20OSS-FF6A00?logo=alibabacloud&logoColor=white)
![OpenStack](https://img.shields.io/badge/OpenStack-Magnum%20%7C%20Octavia-ED1944?logo=openstack&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

<img src="docs/assets/demo.gif" alt="Real terminal recording: terraform fmt -check across every module in this repo, then a trivy IaC security scan (config from trivy.yaml) that actually catches misconfigurations in secure-connectivity" width="820" />

Commercial angle and consulting hooks: [docs/go-to-market.md](docs/go-to-market.md).

> **Note:** This is a personal portfolio repository. Module design and provisioning patterns are original implementations inspired by common enterprise infrastructure problems. All company names, internal system names, account IDs, hostnames, ARNs, VPC CIDRs, and business metrics have been removed or replaced with generic placeholders — none of the figures or names in this repository refer to a real employer, deployment, or production outcome.

---

## Design principles

**Separation of concerns at every layer.** Helm release versions, replica counts, and chart config live in Terraform, not ad-hoc `helm upgrade` commands. ConfigMaps that drive runtime behavior are Terraform resources with full audit trail and PR-based change control.

**Ephemeral state handled at the IaC layer.** Pod IPs are transient. Rather than fighting this, modules use `data "kubernetes_pod_v1"` to query live cluster state and converge AWS resources (NLB target groups) to match. Every `terraform apply` is a reconciliation loop.

**Least-privilege exposure by design.** PrivateLink keeps cross-account traffic off the public internet. Separate NLB target groups per gateway type enforce protocol-level isolation. `target_type = ip` bypasses NodePort NAT and preserves source IP end-to-end.

**Everything version-controlled, nothing click-ops.** IAM roles, Cognito federation, Grafana alert rules, ACR cleanup tasks: all Terraform resources. If it can't be reviewed in a PR and rolled back with a revert, it doesn't exist in production.

**Bad input fails at plan time, not three resources deep in a provider error.** Every one of the 510 input variables across every module and workflow in this repo has a `description`, and the ones with a real constraint (environments, CIDR blocks, retention windows, percentage thresholds, SQS/Log Analytics service limits) have a `validation` block enforcing it. `terraform plan` should tell you `environment must be one of: dev, staging, prod`, not fail an hour later on a resource that silently accepted garbage.

---

## Structure

```
AWS/
├── modules/
│   ├── eks/               multi-account EKS: OIDC, CNI custom networking, Linux/Windows node groups
│   ├── privatelink/       cross-account endpoint service + consumer (SSH/ADB, MSK, internal APIs)
│   ├── s3_lifecycle/      Standard → IA → Glacier Deep Archive, KMS enforcement
│   ├── grafana_alerting/  Grafana rules for ALBs (5XX, P99), MSK, SQS, PrivateLink
│   ├── nginx_ingress/     NGINX on NLB, TCP ConfigMap, dynamic pod IP NLB target registration
│   ├── sqs_sns/           SQS + SNS with DLQ, FIFO, cross-service subscriptions
│   └── opensearch/        OpenSearch with Cognito/SAML SSO + Azure AD OIDC
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

live/
├── root.hcl                                shared locals: cloud/environment derived from the folder path
├── alicloud/{dev,prod}/ack/                dev + prod units for AliCloud/workflows/deploy_ack
├── openstack/{dev,prod}/magnum_k8s/        dev + prod units for OpenStack/workflows/deploy_magnum_k8s
├── gcp/{dev,prod}/apigee_proxies/          dev + prod units for GCP/workflows/deploy_apigee_proxies
├── aws/{dev,prod}/blue_green_eks/          dev + prod units for AWS/workflows/blue_green_eks
├── aws/{dev,prod}/opensearch_migration/    dev + prod units for AWS/workflows/opensearch_migration
└── azure/{dev,prod}/aks_logging/           dev + prod units for Azure/workflows/deploy_aks_logging
```

---

## AWS Modules

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
  replication_regions        = ["ap-south-1", "eu-central-1"]
}
```

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

---

## Azure

### `modules/aks`

AKS with Azure AD RBAC, workload identity (OIDC issuer), ACR pull role, Container Insights, auto-scaling node pools.

### `workflows/deploy_aks_logging`

Example telemetry logging stack:

| Component | Role |
|---|---|
| FluentBit DaemonSet | Tails all pod logs → Event Hubs (Kafka protocol) |
| Azure Event Hubs | Kafka-compatible message bus |
| Logstash | Parses, enriches, indexes to OpenSearch |
| OpenSearch (on AKS) | Log storage and full-text search |
| Grafana | Dashboards, internal LoadBalancer |

---

## GCP

### `modules/apigee`

Apigee X setup with org/env/instance provisioning. Proxy bundles are rendered from templates via `archive_file`. Each bundle includes JS-ValidateToken (Bearer token introspection), JS-PathRouter (dynamic `target.url`), and SpikeArrest (600 req/min) — a pattern for consolidating many single-purpose API proxies into fewer parameterized ones, reducing duplicated auth and routing logic across an org.

### `modules/gke`

Private, VPC-native GKE with Workload Identity, Binary Authorization, Shielded Nodes, and REGULAR release channel auto-upgrades.

### `workflows/deploy_apigee_proxies`

Three example proxies showing the path-routing and token-auth pattern:

| Proxy | Base Path | Routes |
|---|---|---|
| device-api | `/device-api/v2` | `/devices`, `/ssh`, `/workspaces`, `/builds` |
| package-api | `/package-api/v2` | `/packages`, `/download`, `/catalog`, `/releases` |
| inference-api | `/inference-api/v2` | `/models`, `/inference`, `/benchmarks`, `/compile`, `/profile` |

---

## AliCloud

### `modules/ack`

Managed Container Service for Kubernetes: least-privilege worker RAM role, autoscaling node pools split by workload class (general vs. taint-isolated batch), security-hardened OS images, and a weekly maintenance window instead of ad-hoc master upgrades.

### `modules/oss_lifecycle`

Standard to IA to Archive to Cold Archive tiering, KMS or AES256 encryption, versioning, public access block, and access logging, the OSS equivalent of the AWS `s3_lifecycle` and GCP `gcs_lifecycle` modules.

### `modules/api_gateway`

API group and throttled routes fronting backend services, consolidating per-service auth and rate limiting behind one app credential instead of duplicating it downstream.

### `workflows/deploy_ack`

Composes all three: an ACK cluster with a general pool and a tainted batch pool, an OSS bucket for cluster logs on a short retention schedule, and an internal API Gateway route fronting the cluster's status endpoint.

---

## OpenStack

### `modules/magnum_k8s`

Managed Kubernetes on private OpenStack clouds via Magnum: a cluster template pinning image, flavors, and Calico networking, then a cluster resource built from it so a fleet-wide upgrade is one template change instead of N cluster edits.

### `modules/swift_lifecycle`

Swift has no native storage-class tiering like the hyperscalers, so retention here is enforced through per-object expiry headers set by callers, plus a dedicated versions container so overwritten objects survive until they expire rather than disappearing immediately.

### `modules/octavia_ingress`

Standalone Octavia load balancer with an HTTPS listener, a round-robin backend pool, active health checks, and member registration driven by a map of backend addresses, the OpenStack equivalent of the AWS `nginx_ingress` module.

### `workflows/deploy_magnum_k8s`

Composes all three: a Magnum cluster sized by environment (3 masters in prod, 1 elsewhere), a Swift container for backups, and an Octavia load balancer fronting the cluster's ingress nodes.

---

## Terragrunt

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

---

## secure-connectivity/

A separate, self-contained portfolio: five pieces of AWS connectivity
infrastructure (public NGINX service, private SSM-only compute access, an
optional hardened access gateway, and two environment-orchestration
capstones that compose the modules together). Built to demonstrate
public-vs-private trust boundaries, identity-aware administrative access,
and module composition specifically -- see
[secure-connectivity/PROGRESS.md](secure-connectivity/PROGRESS.md) for build
status and [secure-connectivity/docs/interview-guide.md](secure-connectivity/docs/interview-guide.md)
(once written) for the design-decision writeups.

---

## License

MIT
