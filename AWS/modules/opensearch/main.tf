# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# OpenSearch module with OIDC/Cognito SSO
# Covers the on-prem Elasticsearch -> AWS OpenSearch migration (ExampleCorp Senior IT)
# Auth: OIDC + Azure AD federated through Amazon Cognito
# Includes SAML option for direct Azure AD federation without Cognito

resource "aws_opensearch_domain" "this" {
  domain_name    = "${var.domain_name}-${var.environment}"
  engine_version = var.engine_version

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = var.instance_count
    zone_awareness_enabled = var.instance_count > 1

    dynamic "zone_awareness_config" {
      for_each = var.instance_count > 1 ? [1] : []
      content {
        availability_zone_count = min(var.instance_count, 3)
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.ebs_volume_size_gb
  }

  vpc_options {
    subnet_ids         = var.instance_count > 1 ? var.subnet_ids : [var.subnet_ids[0]]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  # KMS encryption at rest
  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # Cognito auth -- fronts OpenSearch Dashboards with Cognito user pool
  # Azure AD identity provider configured in the Cognito user pool separately
  dynamic "cognito_options" {
    for_each = var.cognito_enabled && var.cognito_user_pool_id != "" ? [1] : []
    content {
      enabled          = true
      user_pool_id     = var.cognito_user_pool_id
      identity_pool_id = var.cognito_identity_pool_id
      role_arn         = aws_iam_role.cognito_opensearch[0].arn
    }
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = var.saml_enabled ? false : true
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch.arn
    log_type                 = "SEARCH_SLOW_LOGS"
  }

  tags = merge(var.tags, {
    Environment = var.environment
    Terraform   = "true"
  })

  depends_on = [aws_cloudwatch_log_resource_policy.opensearch]
}

# SAML for direct Azure AD federation without Cognito -- this is a separate
# resource in the AWS provider (aws_opensearch_domain_saml_options), not a
# nested block on aws_opensearch_domain.
resource "aws_opensearch_domain_saml_options" "this" {
  count       = var.saml_enabled && var.saml_metadata_content != "" ? 1 : 0
  domain_name = aws_opensearch_domain.this.domain_name

  saml_options {
    enabled = true
    idp {
      entity_id        = "https://sts.windows.net/${var.saml_master_backend_role}/"
      metadata_content = var.saml_metadata_content
    }
    master_backend_role     = var.saml_master_backend_role
    roles_key               = "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"
    session_timeout_minutes = 60
  }
}

resource "aws_security_group" "opensearch" {
  name        = "${var.domain_name}-${var.environment}-sg"
  description = "OpenSearch domain SG"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = concat(["10.0.0.0/8"], var.allowed_cidr_blocks)
    description = "HTTPS from VPC and allowed CIDRs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.domain_name}-${var.environment}-sg" })
}

resource "aws_cloudwatch_log_group" "opensearch" {
  name              = "/aws/opensearch/${var.domain_name}-${var.environment}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  policy_name = "opensearch-${var.domain_name}-${var.environment}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = ["logs:PutLogEvents", "logs:PutLogEventsBatch", "logs:CreateLogStream"]
      Resource  = "arn:aws:logs:*"
    }]
  })
}

# IAM role for Cognito to access OpenSearch
resource "aws_iam_role" "cognito_opensearch" {
  count = var.cognito_enabled ? 1 : 0
  name  = "${var.domain_name}-${var.environment}-cognito"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cognito_opensearch" {
  count      = var.cognito_enabled ? 1 : 0
  role       = aws_iam_role.cognito_opensearch[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonOpenSearchServiceCognitoAccess"
}
