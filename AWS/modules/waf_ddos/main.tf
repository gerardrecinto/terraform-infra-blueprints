# WAF and DDoS protection for a public web tier.
#
# One web ACL with, in priority order: explicit IP block lists, a per-IP rate rule
# (the first line of defense against request floods and credential stuffing), and AWS
# managed rule groups for common web exploits. Logging redacts credential headers.
# Optional Shield Advanced protection covers volumetric attacks on the same resources.
#
# This is a reference implementation of a common pattern; it carries no production
# metrics and every limit should be tuned against real traffic, starting in count mode.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  acl_name = "${var.name}-${var.environment}"

  tags = merge(
    {
      environment = var.environment
      managed-by  = "terraform"
      module      = "waf_ddos"
    },
    var.tags,
  )

  block_rate = var.rate_limit_action == "block"
  logging    = var.enable_logging

  # CloudWatch Logs destinations for WAF must be named aws-waf-logs-*
  log_group_name = "aws-waf-logs-${local.acl_name}"
}

resource "aws_wafv2_ip_set" "blocked_v4" {
  count = length(var.blocked_ipv4_cidrs) > 0 ? 1 : 0

  name               = "${local.acl_name}-blocked-v4"
  description        = "IPv4 ranges blocked outright for ${local.acl_name}"
  scope              = var.scope
  ip_address_version = "IPV4"
  addresses          = var.blocked_ipv4_cidrs

  tags = local.tags
}

resource "aws_wafv2_ip_set" "blocked_v6" {
  count = length(var.blocked_ipv6_cidrs) > 0 ? 1 : 0

  name               = "${local.acl_name}-blocked-v6"
  description        = "IPv6 ranges blocked outright for ${local.acl_name}"
  scope              = var.scope
  ip_address_version = "IPV6"
  addresses          = var.blocked_ipv6_cidrs

  tags = local.tags
}

resource "aws_wafv2_web_acl" "this" {
  name        = local.acl_name
  description = "Web ACL for ${local.acl_name}: IP block lists, per-IP rate limit, AWS managed rules"
  scope       = var.scope

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = aws_wafv2_ip_set.blocked_v4
    content {
      name     = "block-listed-ipv4"
      priority = 0

      action {
        block {}
      }

      statement {
        ip_set_reference_statement {
          arn = rule.value.arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.acl_name}-block-listed-ipv4"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = aws_wafv2_ip_set.blocked_v6
    content {
      name     = "block-listed-ipv6"
      priority = 1

      action {
        block {}
      }

      statement {
        ip_set_reference_statement {
          arn = rule.value.arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.acl_name}-block-listed-ipv6"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 2

    action {
      dynamic "block" {
        for_each = local.block_rate ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.block_rate ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.acl_name}-rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = var.managed_rule_groups
    content {
      name     = rule.key
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.count_only ? [] : [1]
          content {}
        }
        dynamic "count" {
          for_each = rule.value.count_only ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.acl_name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.acl_name
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  for_each = var.scope == "REGIONAL" ? toset(var.associate_resource_arns) : toset([])

  resource_arn = each.value
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  count = local.logging ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn != "" ? var.log_kms_key_arn : null

  tags = local.tags
}

data "aws_iam_policy_document" "waf_log_delivery" {
  count = local.logging && var.create_log_resource_policy ? 1 : 0

  statement {
    sid     = "AWSLogDeliveryWrite"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    resources = ["${aws_cloudwatch_log_group.waf[0].arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  count = local.logging && var.create_log_resource_policy ? 1 : 0

  policy_name     = "${local.log_group_name}-delivery"
  policy_document = data.aws_iam_policy_document.waf_log_delivery[0].json
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = local.logging ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  dynamic "redacted_fields" {
    for_each = toset(var.redacted_headers)
    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}

resource "aws_shield_protection" "this" {
  for_each = var.enable_shield_advanced ? var.shield_protected_resources : {}

  name         = "${local.acl_name}-${each.key}"
  resource_arn = each.value

  tags = local.tags
}
