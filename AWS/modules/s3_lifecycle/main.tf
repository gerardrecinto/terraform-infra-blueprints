# NOTE: Published as supporting evidence for skills on resume.
# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# S3 lifecycle module
# Transitions log data from S3-Standard -> Standard-IA -> Glacier Deep Archive,
# with optional cross-region replication and KMS enforcement. Models a common
# cost-optimization pattern for large, append-only log buckets; no production
# metrics are claimed here.

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    Environment = var.environment
    Terraform   = "true"
  })
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != "" ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    bucket_key_enabled = var.kms_key_arn != "" ? true : false
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  lifecycle {
    precondition {
      condition     = var.transition_to_glacier_days >= var.transition_to_ia_days + 30
      error_message = "transition_to_glacier_days is the object age and must be at least 30 days after transition_to_ia_days for the Standard-IA minimum storage duration."
    }
    precondition {
      condition     = var.expiration_days == 0 || var.expiration_days > var.transition_to_glacier_days
      error_message = "expiration_days must be 0 (disabled) or greater than transition_to_glacier_days so expiration does not override tiering."
    }
  }

  rule {
    id     = "log-tiering"
    status = "Enabled"

    filter {
      prefix = var.log_prefix
    }

    # Move to IA after 30 days -- saves ~45% vs Standard
    transition {
      days          = var.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    # Move to Glacier Deep Archive after 90 days -- saves ~95% vs Standard
    transition {
      days          = var.transition_to_glacier_days
      storage_class = "DEEP_ARCHIVE"
    }

    dynamic "expiration" {
      for_each = var.expiration_days > 0 ? [1] : []
      content {
        days = var.expiration_days
      }
    }

    # Clean up incomplete multipart uploads -- common with large log uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Expire old non-current versions after 30 days to control versioning costs
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny HTTP always. With a KMS key set, also deny PutObject that does not use that key.
# Without a key the second statement is omitted (it used to be an Allow for "*", which grants public writes).
resource "aws_s3_bucket_policy" "this" {
  count  = var.enforce_encryption_policy ? 1 : 0
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.this.arn,
          "${aws_s3_bucket.this.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      ], var.kms_key_arn != "" ? [
      {
        Sid       = "DenyNonKMSEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = var.kms_key_arn
          }
        }
      }
    ] : [])
  })
}

# Replication to additional regions for global coverage
resource "aws_s3_bucket_replication_configuration" "this" {
  count = length(var.replication_regions) > 0 ? 1 : 0

  role   = aws_iam_role.replication[0].arn
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.replication_regions
    content {
      id     = "replicate-to-${rule.value}"
      status = "Enabled"

      filter {}

      destination {
        bucket        = "arn:aws:s3:::${var.bucket_name}-${rule.value}"
        storage_class = "STANDARD_IA"
      }

      delete_marker_replication {
        status = "Enabled"
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_iam_role" "replication" {
  count = length(var.replication_regions) > 0 ? 1 : 0
  name  = "${var.bucket_name}-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  count = length(var.replication_regions) > 0 ? 1 : 0
  role  = aws_iam_role.replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${aws_s3_bucket.this.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = [for r in var.replication_regions : "arn:aws:s3:::${var.bucket_name}-${r}/*"]
      }
    ]
  })
}
