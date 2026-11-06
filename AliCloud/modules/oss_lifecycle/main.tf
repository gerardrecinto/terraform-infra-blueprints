# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# OSS lifecycle module -- analogous to the AWS s3_lifecycle and GCP gcs_lifecycle modules
# Tiers objects from Standard -> IA -> Archive -> Cold Archive
# Useful for log retention and backup tiering on AliCloud-side workloads

terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.99"
    }
  }
}

resource "alicloud_oss_bucket" "this" {
  bucket = var.bucket_name

  versioning {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }

  # Server-side encryption -- KMS-backed when a key is supplied, else AES256
  server_side_encryption_rule {
    sse_algorithm     = var.kms_key_id != "" ? "KMS" : "AES256"
    kms_master_key_id = var.kms_key_id != "" ? var.kms_key_id : null
  }

  lifecycle_rule {
    id      = "${var.object_prefix}-tiering"
    prefix  = var.object_prefix
    enabled = true

    transitions {
      days          = var.transition_to_ia_days
      storage_class = "IA"
    }

    transitions {
      days          = var.transition_to_archive_days
      storage_class = "Archive"
    }

    transitions {
      days          = var.transition_to_cold_archive_days
      storage_class = "ColdArchive"
    }

    expiration {
      days = var.expiration_days
    }

    # Clean up incomplete multipart uploads so they don't accrue storage cost silently
    abort_multipart_upload {
      days = 7
    }
  }

  logging {
    target_bucket = var.access_log_bucket != "" ? var.access_log_bucket : var.bucket_name
    target_prefix = "access-logs/"
  }

  tags = merge(var.tags, {
    environment = var.environment
    terraform   = "true"
  })
}

# Private ACL -- separate resource per provider >= 1.220.0
resource "alicloud_oss_bucket_acl" "this" {
  bucket = alicloud_oss_bucket.this.bucket
  acl    = "private"
}

# Block public access -- belt and suspenders alongside the private ACL above
resource "alicloud_oss_bucket_public_access_block" "this" {
  bucket              = alicloud_oss_bucket.this.bucket
  block_public_access = true
}
