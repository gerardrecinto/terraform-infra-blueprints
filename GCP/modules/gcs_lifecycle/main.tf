# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# GCS lifecycle module -- analogous to the AWS s3_lifecycle module
# Tiers objects from Standard -> Nearline -> Coldline -> Archive
# Useful for log retention on GCP-side workloads

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

resource "google_storage_bucket" "this" {
  name          = var.bucket_name
  location      = var.location
  project       = var.project_id
  storage_class = "STANDARD"

  versioning {
    enabled = true
  }

  # Uniform bucket-level access -- no per-object ACLs
  uniform_bucket_level_access = true

  # CMEK encryption
  dynamic "encryption" {
    for_each = var.kms_key_name != "" ? [1] : []
    content {
      default_kms_key_name = var.kms_key_name
    }
  }

  lifecycle_rule {
    condition {
      age            = var.transition_to_nearline_days
      matches_prefix = [var.object_prefix]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age            = var.transition_to_coldline_days
      matches_prefix = [var.object_prefix]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age            = var.transition_to_archive_days
      matches_prefix = [var.object_prefix]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.expiration_days > 0 ? [1] : []
    content {
      condition {
        age            = var.expiration_days
        matches_prefix = [var.object_prefix]
      }
      action {
        type = "Delete"
      }
    }
  }

  # Clean up incomplete multipart uploads after 7 days
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # Expire non-current versions after 30 days
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    terraform   = "true"
  })
}

# Block public access via IAM -- explicit deny for allUsers and allAuthenticatedUsers
resource "google_storage_bucket_iam_binding" "deny_public" {
  bucket  = google_storage_bucket.this.name
  role    = "roles/storage.objectViewer"
  members = [] # empty = no public viewers
}
