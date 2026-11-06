# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders. This is an original portfolio
# implementation demonstrating the ACK + OSS + API Gateway composition pattern generically.

terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.99"
    }
  }

  backend "oss" {
    bucket = "example-terraform-state"
    prefix = "ack"
    region = "cn-hangzhou"
  }
}

provider "alicloud" {
  region = var.region
}

module "ack" {
  source = "../../modules/ack"

  region       = var.region
  cluster_name = "platform-${var.environment}"
  environment  = var.environment
  vswitch_ids  = var.vswitch_ids

  node_pools = {
    # general -- default pool for stateless services
    general = {
      instance_types       = ["ecs.g7.xlarge"]
      system_disk_category = "cloud_essd"
      system_disk_size     = 100
      min_count            = 2
      max_count            = 8
      initial_count        = 2
      taints               = []
    }
    # batch -- spot-friendly pool for retryable batch and CI workloads, tainted so
    # nothing lands there by accident
    batch = {
      instance_types       = ["ecs.g7.2xlarge"]
      system_disk_category = "cloud_essd"
      system_disk_size     = 200
      min_count            = 0
      max_count            = 6
      initial_count        = 0
      taints = [
        {
          key    = "workload-class"
          value  = "batch"
          effect = "NoSchedule"
        }
      ]
    }
  }
}

module "log_bucket" {
  source = "../../modules/oss_lifecycle"

  bucket_name       = "platform-${var.environment}-logs"
  environment       = var.environment
  object_prefix     = "cluster-logs/"
  enable_versioning = false

  # Logs are cheap to regenerate, not worth long archive retention
  transition_to_ia_days           = 14
  transition_to_archive_days      = 45
  transition_to_cold_archive_days = 90
  expiration_days                 = 180
}

module "internal_api" {
  source = "../../modules/api_gateway"

  group_name  = "platform-internal"
  environment = var.environment

  apis = {
    # cluster-status -- read-only health/status endpoint fronting the ACK cluster's
    # internal status service, rate-limited so dashboards can't accidentally hammer it
    cluster-status = {
      description     = "Read-only cluster and node pool status"
      request_path    = "/status/*"
      backend_address = "http://cluster-status-svc.platform.svc.cluster.local"
      backend_path    = "/api/status/*"
    }
  }
}
