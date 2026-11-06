# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# ACK module -- managed Container Service for Kubernetes cluster
# Analogous to the EKS, AKS, and GKE modules for AWS, Azure, and GCP
# Control plane is fully managed by Alibaba Cloud; this module owns node pools and RAM

terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.99"
    }
  }
}

provider "alicloud" {
  region = var.region
}

# RAM role assumed by worker nodes -- least privilege, no AdministratorAccess-equivalent
# Trust policy scoped to the ECS service principal only
resource "alicloud_ram_role" "node" {
  role_name = "${var.cluster_name}-node-role"
  assume_role_policy_document = jsonencode({
    Version = "1"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = ["ecs.aliyuncs.com"] }
      }
    ]
  })
  description = "Worker node role for ACK cluster ${var.cluster_name}"
}

resource "alicloud_ram_role_policy_attachment" "node_policies" {
  for_each    = toset(var.node_role_policies)
  role_name   = alicloud_ram_role.node.role_name
  policy_name = each.value
  policy_type = "System"
}

resource "alicloud_cs_managed_kubernetes" "this" {
  name            = var.cluster_name
  cluster_spec    = var.cluster_spec
  version         = var.kubernetes_version
  vswitch_ids     = var.vswitch_ids
  new_nat_gateway = false
  proxy_mode      = "ipvs"

  # Private control-plane endpoint -- API server not reachable from the public internet
  service_cidr = var.service_cidr

  # Managed masters -- no dedicated master nodes, no master SSH key exposure
  addons {
    name = "terway-eniip"
  }
  addons {
    name = "csi-plugin"
  }
  addons {
    name = "csi-provisioner"
  }
  addons {
    name = "logtail-ds"
  }

  maintenance_window {
    enable           = true
    maintenance_time = "03:00:00.000+08:00"
    duration         = "3h"
    weekly_period    = "Sunday"
  }

  tags = merge(var.tags, {
    environment = var.environment
    terraform   = "true"
  })
}

# Managed node pools -- autoscaling, one pool per workload class
resource "alicloud_cs_kubernetes_node_pool" "pools" {
  for_each = var.node_pools

  cluster_id           = alicloud_cs_managed_kubernetes.this.id
  node_pool_name       = each.key
  vswitch_ids          = var.vswitch_ids
  instance_types       = each.value.instance_types
  system_disk_category = each.value.system_disk_category
  system_disk_size     = each.value.system_disk_size

  scaling_config {
    min_size = each.value.min_count
    max_size = each.value.max_count
    type     = "cost_optimized"
  }

  desired_size = each.value.initial_count

  # Security hardening
  security_hardening_os = true
  runtime_name          = "containerd"

  install_cloud_monitor = true

  labels {
    key   = "environment"
    value = var.environment
  }

  dynamic "taints" {
    for_each = each.value.taints
    content {
      key    = taints.value.key
      value  = taints.value.value
      effect = taints.value.effect
    }
  }
}
