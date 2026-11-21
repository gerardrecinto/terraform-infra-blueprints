resource "aws_eks_node_group" "training" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.name}-training"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type
  ami_type        = "AL2023_x86_64_NVIDIA"
  disk_size       = var.disk_size_gb

  scaling_config {
    min_size     = var.min_size
    max_size     = var.max_size
    desired_size = var.desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "ml-training"
  }

  # Only pods that ask for a GPU and tolerate this taint land here.
  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, { Name = "${var.name}-training" })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_s3_bucket" "checkpoints" {
  bucket = var.checkpoint_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "checkpoints" {
  bucket                  = aws_s3_bucket.checkpoints.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    id     = "expire-old-checkpoints"
    status = "Enabled"
    filter {}

    expiration {
      days = var.checkpoint_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Attach this to the IRSA role of the training service account.
data "aws_iam_policy_document" "checkpoint_access" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.checkpoints.arn}/*"]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.checkpoints.arn]
  }
}
