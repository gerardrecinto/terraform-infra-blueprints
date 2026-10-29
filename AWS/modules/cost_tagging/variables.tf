variable "enable_org_policy" {
  description = "Apply tag policy at AWS Organizations level (requires Organizations management account)"
  type        = bool
  default     = false
}

variable "policy_name_prefix" {
  description = "Prefix for the Organizations tag policy name"
  type        = string
  default     = "infra"
}

variable "target_id" {
  description = "AWS Organizations OU or account ID to attach the tag policy to"
  type        = string
  default     = ""
}

variable "required_tags" {
  description = "List of tag keys to enforce on all resources"
  type        = list(string)
  default     = ["cost-center", "environment", "team", "service"]
}

variable "enforced_resource_types" {
  description = "Resource types on which tag compliance is enforced when these tag keys are supplied; missing tags are not required by this policy"
  type        = list(string)
  default = [
    "ec2:instance",
    "ec2:volume",
    "s3:bucket",
    "rds:db",
    "eks:cluster",
    "lambda:function"
  ]
}

variable "team_budgets" {
  description = "Map of team name to monthly budget in USD (e.g. { platform = '5000' })"
  type        = map(string)
  default     = {}
}

variable "budget_alert_emails" {
  description = "Email addresses to notify on budget threshold breaches"
  type        = list(string)
  default     = []
}
