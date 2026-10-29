# NOTE: Published as supporting evidence for skills on resume.
# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# On-prem Elasticsearch -> AWS OpenSearch migration workflow
# Covers the ExampleCorp IT project: migrated to OpenSearch with OIDC + Azure AD + Cognito SSO
# Uses the opensearch module for the target cluster, then drives index migration via snapshot

provider "aws" {
  region = var.aws_region
}

module "opensearch" {
  source = "../../modules/opensearch"

  domain_name        = var.domain_name
  environment        = var.environment
  engine_version     = var.engine_version
  instance_type      = var.instance_type
  instance_count     = var.instance_count
  ebs_volume_size_gb = var.ebs_volume_size_gb
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  kms_key_arn        = var.kms_key_arn

  # Cognito SSO -- Azure AD federated as external IDP
  cognito_enabled          = true
  cognito_user_pool_id     = var.cognito_user_pool_id
  cognito_identity_pool_id = var.cognito_identity_pool_id

  allowed_cidr_blocks = var.allowed_cidr_blocks

  tags = local.tags
}

locals {
  tags = {
    Environment  = var.environment
    Project      = var.domain_name
    Terraform    = "true"
    MigratedFrom = "on-prem-elasticsearch"
  }
}

# S3 bucket for Elasticsearch snapshot-based migration
# On-prem ES snapshots to this bucket; OpenSearch restores from it
resource "aws_s3_bucket" "migration_snapshots" {
  bucket = "${var.domain_name}-${var.environment}-migration-snapshots"
  tags   = local.tags
}

# A customer-managed key makes snapshot encryption and its reader permissions
# explicit in the configuration, independent of S3's service-managed default.
resource "aws_kms_key" "migration_snapshots" {
  description             = "Encrypt ${var.domain_name} migration snapshots"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "migration_snapshots" {
  bucket = aws_s3_bucket.migration_snapshots.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.migration_snapshots.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "migration_snapshots" {
  bucket                  = aws_s3_bucket.migration_snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for OpenSearch to read snapshots from S3
resource "aws_iam_role" "snapshot_restore" {
  name = "${var.domain_name}-${var.environment}-snapshot-restore"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "snapshot_restore" {
  role = aws_iam_role.snapshot_restore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.migration_snapshots.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.migration_snapshots.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.migration_snapshots.arn
      }
    ]
  })
}

# Cognito User Pool -- Azure AD OIDC connected as external IDP
resource "aws_cognito_user_pool" "opensearch" {
  count = var.create_cognito_resources ? 1 : 0
  name  = "${var.domain_name}-${var.environment}"

  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_domain" "opensearch" {
  count        = var.create_cognito_resources ? 1 : 0
  domain       = "${var.domain_name}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.opensearch[0].id
}

# Azure AD OIDC identity provider in Cognito
resource "aws_cognito_identity_provider" "azure_ad" {
  count         = var.create_cognito_resources && var.azure_ad_client_id != "" ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.opensearch[0].id
  provider_name = "AzureAD"
  provider_type = "OIDC"

  provider_details = {
    client_id                 = var.azure_ad_client_id
    client_secret             = var.azure_ad_client_secret
    attributes_request_method = "GET"
    oidc_issuer               = "https://login.microsoftonline.com/${var.azure_tenant_id}/v2.0"
    authorize_scopes          = "openid email profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

resource "aws_cognito_identity_pool" "opensearch" {
  count                            = var.create_cognito_resources ? 1 : 0
  identity_pool_name               = "${var.domain_name}-${var.environment}"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.opensearch[0].id
    provider_name           = aws_cognito_user_pool.opensearch[0].endpoint
    server_side_token_check = false
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_client" "opensearch" {
  count        = var.create_cognito_resources ? 1 : 0
  name         = "${var.domain_name}-${var.environment}-client"
  user_pool_id = aws_cognito_user_pool.opensearch[0].id

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls = [
    "https://${module.opensearch.dashboard_endpoint}/_dashboards/app/home"
  ]
  supported_identity_providers = ["AzureAD"]
}
