variable "name" {
  description = "Base name for the web ACL and its related resources (lowercase letters, digits and hyphens)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2 to 41 characters of lowercase letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod); used in resource names and tags"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "scope" {
  description = "WAF scope: REGIONAL for ALB, API Gateway or AppSync, CLOUDFRONT for CloudFront (CLOUDFRONT web ACLs must be created in us-east-1)"
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "CLOUDFRONT"], var.scope)
    error_message = "scope must be REGIONAL or CLOUDFRONT."
  }
}

variable "associate_resource_arns" {
  description = "ARNs of the regional resources (for example Application Load Balancers) to attach the web ACL to; ignored for CLOUDFRONT scope, where the ACL is attached from the distribution"
  type        = list(string)
  default     = []
}

variable "rate_limit_per_5min" {
  description = "Maximum requests per source IP in a rolling 5-minute window before the rate rule triggers (WAF allows 10 to 2,000,000,000)"
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit_per_5min >= 10 && var.rate_limit_per_5min <= 2000000000
    error_message = "rate_limit_per_5min must be between 10 and 2000000000."
  }
}

variable "rate_limit_action" {
  description = "What the rate rule does when the limit is exceeded: block, or count to observe first (recommended when rolling out a new limit)"
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "count"], var.rate_limit_action)
    error_message = "rate_limit_action must be block or count."
  }
}

variable "managed_rule_groups" {
  description = "AWS managed rule groups to attach, keyed by rule group name. priority must be 10 or higher and unique; count_only observes without blocking so a new group can be rolled out safely"
  type = map(object({
    priority   = number
    count_only = optional(bool, false)
  }))
  default = {
    AWSManagedRulesCommonRuleSet          = { priority = 10 }
    AWSManagedRulesKnownBadInputsRuleSet  = { priority = 20 }
    AWSManagedRulesSQLiRuleSet            = { priority = 30 }
    AWSManagedRulesAmazonIpReputationList = { priority = 40 }
  }

  validation {
    condition     = alltrue([for g in values(var.managed_rule_groups) : g.priority >= 10])
    error_message = "Every managed rule group priority must be 10 or higher (0 to 9 are reserved for the IP block lists and the rate rule)."
  }

  validation {
    condition     = length(distinct([for g in values(var.managed_rule_groups) : g.priority])) == length(var.managed_rule_groups)
    error_message = "Managed rule group priorities must be unique."
  }
}

variable "blocked_ipv4_cidrs" {
  description = "IPv4 CIDR ranges to block outright (for example addresses identified during an incident)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.blocked_ipv4_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry in blocked_ipv4_cidrs must be a valid IPv4 CIDR such as 203.0.113.0/24."
  }
}

variable "blocked_ipv6_cidrs" {
  description = "IPv6 CIDR ranges to block outright"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.blocked_ipv6_cidrs : can(regex("^[0-9a-fA-F:]+/[0-9]{1,3}$", c))])
    error_message = "Every entry in blocked_ipv6_cidrs must be a valid IPv6 CIDR such as 2001:db8::/32."
  }
}

variable "enable_logging" {
  description = "Send full web ACL logs to a CloudWatch Logs group (the group name is prefixed aws-waf-logs- as WAF requires)"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the WAF log group in days (must be a value CloudWatch Logs accepts)"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention value supported by CloudWatch Logs, for example 30, 90 or 365."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key ARN used to encrypt the WAF log group; leave empty for the CloudWatch default encryption"
  type        = string
  default     = ""
}

variable "redacted_headers" {
  description = "Request header names (lowercase) removed from WAF logs so credentials and session cookies never reach the log store"
  type        = list(string)
  default     = ["authorization", "cookie"]
}

variable "create_log_resource_policy" {
  description = "Create the CloudWatch Logs resource policy that lets the WAF log delivery service write to the group; set false if one account-wide policy already covers aws-waf-logs-* groups (AWS allows only a small number per region)"
  type        = bool
  default     = true
}

variable "enable_shield_advanced" {
  description = "Create AWS Shield Advanced protections for shield_protected_resources (requires an active Shield Advanced subscription on the account)"
  type        = bool
  default     = false
}

variable "shield_protected_resources" {
  description = "Map of protection name to resource ARN (ALB, CloudFront distribution, Elastic IP or Route 53 hosted zone) protected by Shield Advanced when enable_shield_advanced is true"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Extra tags merged into every taggable resource"
  type        = map(string)
  default     = {}
}
