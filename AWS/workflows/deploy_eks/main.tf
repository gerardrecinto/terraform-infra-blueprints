# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs
# Configure the AWS Provider
provider "aws" {
  region = local.aws_region
}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster_id.cluster_endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster_id.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    command     = "aws"
  }
}

# https://registry.terraform.io/providers/hashicorp/helm/latest/docs
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster_id.cluster_endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster_id.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
      command     = "aws"
    }
  }
}

locals {
  env             = "Production"
  cluster_name    = "gerardrecinto"
  aws_region      = "us-west-1"
  cluster_version = "1.31"
  vpc_id          = "vpc-0d3c6a6e25ee6ac7f"
  subnet_ids      = ["subnet-051442fadafbafc1c", "subnet-0773c376214a9a2e8"]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  # Optional
  cluster_endpoint_public_access = true

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  vpc_id     = local.vpc_id
  subnet_ids = local.subnet_ids

  tags = {
    Environment = local.env
    Terraform   = "true"
  }
}