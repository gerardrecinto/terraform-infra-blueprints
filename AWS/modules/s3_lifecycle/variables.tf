variable "bucket_name" {
  description = "Globally unique S3 bucket name"
  type        = string

  validation {
    condition     = length(var.bucket_name) > 0
    error_message = "bucket_name must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod); merged into resource tags"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "log_prefix" {
  description = "Prefix filter -- target specific log paths (e.g., \"app-logs/\"); empty string applies rules to the whole bucket"
  type        = string
  default     = ""
}

variable "transition_to_ia_days" {
  description = "Days in S3 Standard before moving to Standard-IA"
  type        = number
  default     = 30

  validation {
    condition     = var.transition_to_ia_days >= 30 && floor(var.transition_to_ia_days) == var.transition_to_ia_days
    error_message = "transition_to_ia_days must be a whole number of at least 30 days, as required for Standard-IA."
  }
}

variable "transition_to_glacier_days" {
  description = "Object age in days before archiving to Glacier Deep Archive; must be at least 30 days after transition_to_ia_days"
  type        = number
  default     = 90

  validation {
    condition     = var.transition_to_glacier_days >= 1 && floor(var.transition_to_glacier_days) == var.transition_to_glacier_days
    error_message = "transition_to_glacier_days must be a positive whole number of days."
  }
}

variable "expiration_days" {
  description = "Hard delete after N days -- set to 0 to disable"
  type        = number
  default     = 0

  validation {
    condition     = var.expiration_days >= 0 && floor(var.expiration_days) == var.expiration_days
    error_message = "expiration_days must be a whole number of zero or greater (0 disables expiration)."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN for SSE-KMS; leave empty for SSE-S3"
  type        = string
  default     = ""
}

variable "enforce_encryption_policy" {
  description = "Explicit deny for non-HTTPS and non-KMS access"
  type        = bool
  default     = true
}

variable "replication_regions" {
  description = "Additional regions to replicate to (e.g., ap-south-1, eu-central-1)"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional resource tags merged with the environment and terraform-managed tags"
  type        = map(string)
  default     = {}
}
