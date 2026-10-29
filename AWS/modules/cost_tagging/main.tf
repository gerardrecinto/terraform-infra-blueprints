# Cost tag consistency and reporting module.
# Defines tag-key case compliance on configured resource types, activates
# cost allocation tags, and creates team budgets. This policy does not add
# missing tags or prevent every untagged resource from being created.
# See README.md for the enforcement boundary.
#
# Usage: Apply at the AWS Organizations root or per-OU for multi-team enforcement.
# This pattern is a standard approach for reducing unattributed spend in large,
# multi-region deployments; no production metrics are claimed here.

resource "aws_organizations_policy" "cost_tagging" {
  count = var.enable_org_policy ? 1 : 0

  name        = "${var.policy_name_prefix}-cost-tagging"
  description = "Standardize configured tag-key case on supported tagged resources"
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      for tag in var.required_tags : tag => {
        tag_key = {
          "@@assign" = tag
        }
        enforced_for = {
          "@@assign" = var.enforced_resource_types
        }
      }
    }
  })
}

resource "aws_organizations_policy_attachment" "cost_tagging" {
  count     = var.enable_org_policy && var.target_id != "" ? 1 : 0
  policy_id = aws_organizations_policy.cost_tagging[0].id
  target_id = var.target_id
}

# Cost allocation tag activation (must be enabled before tags appear in Cost Explorer)
resource "aws_ce_cost_allocation_tag" "required" {
  for_each = toset(var.required_tags)

  tag_key = each.value
  status  = "Active"
}

# Budget alarm per cost-center tag (catches runaway spend early)
resource "aws_budgets_budget" "per_team" {
  for_each = var.team_budgets

  name              = "${each.key}-monthly"
  budget_type       = "COST"
  limit_amount      = each.value
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = formatdate("YYYY-MM-01_00:00", timestamp())

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:team$${each.key}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
