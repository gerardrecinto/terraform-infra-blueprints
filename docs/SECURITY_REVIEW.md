# Infrastructure security review

This is configuration review and mocked-provider testing. No cloud deployment, penetration test, or production security certification is claimed.

## Controls checked in pull requests

The standalone AKS module now uses a private API endpoint without a public FQDN, managed Microsoft Entra RBAC, and no local administrator credentials. Existing callers must run Terraform and Kubernetes clients from a network that reaches the private endpoint and configure the appropriate private DNS. There is no public wildcard fallback.

The enterprise AKS workflow explicitly enables Entra RBAC and Calico policy enforcement. It uses Azure CNI Overlay, so node pools use the node subnet plus `pod_cidr`, rather than simultaneously specifying an Azure CNI pod subnet. The old `aks_pods_subnet_name` input is retained but ignored. Callers must now supply `azure_ad_tenant_id`; group role assignments remain their responsibility. A policy engine does not itself install application-specific deny policies.

The migration snapshot bucket uses a dedicated rotating customer-managed KMS key and grants the snapshot role decryption/data-key access. Existing source uploaders need a reviewed IAM policy for that key. This workflow does not configure on-prem upload credentials. The public ALB drops malformed headers, while its explicitly documented HTTP-only demonstration mode remains a separate risk below.

CI validates the changed configurations, runs mocked AKS/snapshot/ALB security tests, and blocks HIGH/CRITICAL Trivy findings in the two corrected AKS configurations. Mocked provider operations do not call Azure or AWS. Cluster versions still need to be selected against the region's supported versions; schema validation cannot establish regional availability.

Sources: [AKS network policies](https://learn.microsoft.com/en-us/azure/aks/use-network-policies), [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/concepts-network-azure-cni-overlay), [AWS KMS with S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html).

## Findings still open in the repository-wide scan

The October 29 review with Trivy 0.74.0 found eleven HIGH/CRITICAL results before this change. Five are addressed here: unrestricted standalone AKS API exposure, missing explicit enterprise RBAC, missing enterprise network policy, missing snapshot customer-managed encryption, and missing ALB malformed-header dropping. Six remain:

| Finding and location | Review and next action |
|---|---|
| AWS-0104, `AWS/modules/opensearch/main.tf` | All-protocol internet egress is broader than necessary. Identify actual domain egress requirements and test explicit destinations before tightening. This is not accepted as harmless or suppressed. |
| AWS-0104, `AWS/modules/privatelink/main.tf` | Interface endpoint security-group egress is broad. Review and test the consumer/service direction and remove unnecessary outbound permissions. No suppression added. |
| AWS-0104, `secure-connectivity/modules/access-gateway/main.tf` | Gateway outbound access is restricted to TCP 443 but any IPv4 destination for SSM and package repositories. This is a documented tradeoff, not identity-aware destination restriction. Prefer reviewed VPC endpoints and endpoint security groups where feasible. No suppression added. |
| AWS-0164, `secure-connectivity/modules/network/main.tf` | The public-subnet example autoassigns public addresses. Private compute uses separate private subnets. Callers must decide whether automatic public addressing is necessary. No suppression added. |
| AWS-0053, `secure-connectivity/modules/nginx-public-service/main.tf` | This module intentionally creates an internet-facing ALB for a public web service. Its public purpose does not establish authorization, application security or DDoS readiness. No suppression added. |
| AWS-0054, `secure-connectivity/modules/nginx-public-service/main.tf` | Without a certificate the example serves plaintext HTTP. The README warns it is demonstration-only; a production caller must provide a certificate. Making TLS mandatory is separate compatibility work. No suppression added. |

The repository-wide scan still reports these findings. Its existing SARIF upload is not a blocking security gate. A global `exit-code: 1` would currently make unrelated PRs red, so this change does not pretend that all findings are resolved. The new narrow AKS gate fails on HIGH/CRITICAL results rather than hiding them. No existing ignores were broadened and no new ignores were added.
