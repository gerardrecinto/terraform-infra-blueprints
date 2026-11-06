# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# GKE module -- private, VPC-native cluster with Workload Identity
# Analogous to the EKS and AKS modules for AWS and Azure
# Used as the compute layer backing Apigee and internal GCP services

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Service account for GKE nodes -- least privilege, no default editor role
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE Node SA for ${var.cluster_name}"
}

resource "google_project_iam_member" "node_sa_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region

  # Remove default node pool immediately -- we manage pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.kubernetes_version == "latest" ? null : var.kubernetes_version

  network    = var.network
  subnetwork = var.subnetwork

  # VPC-native (alias IPs) -- required for PrivateCluster and Workload Identity
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = var.private_cluster
    enable_private_endpoint = false # keep master endpoint accessible from authorized networks
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # Workload Identity -- pods assume GCP service accounts via K8s SA annotation
  workload_identity_config {
    workload_pool = var.workload_identity_enabled ? "${var.project_id}.svc.id.goog" : null
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  maintenance_policy {
    recurring_window {
      # Maintenance window: Sunday 02:00-06:00 UTC
      start_time = "2024-01-07T02:00:00Z"
      end_time   = "2024-01-07T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SU"
    }
  }

  # Binary Authorization -- only allow images from Artifact Registry
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  resource_labels = merge(var.tags, {
    environment = var.environment
    terraform   = "true"
  })
}

# Managed node pools
resource "google_container_node_pool" "pools" {
  for_each = var.node_pools

  name     = each.key
  cluster  = google_container_cluster.this.id
  location = var.region

  autoscaling {
    min_node_count = each.value.min_count
    max_node_count = each.value.max_count
  }

  initial_node_count = each.value.initial_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    preemptible  = each.value.preemptible
    spot         = each.value.spot

    service_account = google_service_account.gke_nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = var.workload_identity_enabled ? "GKE_METADATA" : "MODE_UNSPECIFIED"
    }

    labels = merge(each.value.labels, {
      environment = var.environment
    })

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
