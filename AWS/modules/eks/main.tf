# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# EKS module -- multi-account, mixed Linux/Windows node groups
# Supports VPC CNI custom networking (100-series subnets) and OIDC IDP federation

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = false # internal only; front with PrivateLink or VPN

  enable_cluster_creator_admin_permissions = true

  # OIDC provider for IRSA (pod-level IAM) and external IDP federation
  enable_irsa = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      # Enable custom networking so pods use 100-series subnets, not primary node subnet
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = tostring(var.cni_custom_networking_enabled)
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # Linux node groups
  eks_managed_node_groups = merge(
    { for name, cfg in var.linux_node_groups : name => {
      ami_type       = "AL2_x86_64"
      instance_types = cfg.instance_types
      capacity_type  = cfg.capacity_type
      min_size       = cfg.min_size
      max_size       = cfg.max_size
      desired_size   = cfg.desired_size
      labels         = cfg.labels
      taints         = cfg.taints
      tags           = var.tags
    } },
    { for name, cfg in var.windows_node_groups : "win-${name}" => {
      ami_type       = "WINDOWS_CORE_2022_x86_64"
      instance_types = cfg.instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = cfg.min_size
      max_size       = cfg.max_size
      desired_size   = cfg.desired_size
      # Windows nodes need specific labels for scheduling
      labels = {
        "kubernetes.io/os"                 = "windows"
        "node.kubernetes.io/windows-build" = "10.0.20348"
      }
      taints = [{
        key    = "os"
        value  = "windows"
        effect = "NO_SCHEDULE"
      }]
      tags = var.tags
    } }
  )

  tags = merge(var.tags, {
    Environment = var.environment
    Terraform   = "true"
  })
}

# ENIConfig resources for each AZ -- required for VPC CNI custom networking
resource "kubernetes_manifest" "eni_config" {
  for_each = var.cni_custom_networking_enabled ? var.eni_config_subnets : {}

  manifest = {
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = each.key # AZ name, matched by ENI_CONFIG_LABEL_DEF label
    }
    spec = {
      subnet         = each.value
      securityGroups = [module.eks.node_security_group_id]
    }
  }

  depends_on = [module.eks]
}

# EBS CSI driver IAM role
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# OIDC IDP federation -- allows external identity provider (Azure AD, Okta) to auth to the cluster
resource "aws_iam_openid_connect_provider" "external_idp" {
  count = var.oidc_issuer_url != "" ? 1 : 0

  url             = var.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.idp[0].certificates[0].sha1_fingerprint]
}

data "tls_certificate" "idp" {
  count = var.oidc_issuer_url != "" ? 1 : 0
  url   = var.oidc_issuer_url
}
