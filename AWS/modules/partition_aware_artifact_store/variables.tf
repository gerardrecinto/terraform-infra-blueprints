variable "bucket_name" {
  description = "Globally unique name for the artifact bucket"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3 to 63 characters of lowercase letters, digits, dots and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment; merged into resource tags"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "reader_role_name" {
  description = "Name of the IAM role that can read the bucket"
  type        = string
  default     = "artifact-reader"
}

variable "reader_service_principal" {
  description = "AWS service allowed to assume the reader role (same name in the aws and aws-us-gov partitions)"
  type        = string
  default     = "ecs-tasks.amazonaws.com"
}

variable "kms_key_arn" {
  description = "KMS key ARN for bucket encryption; empty string uses the AWS managed S3 key (SSE-S3 is NOT used, aws:kms is always set)"
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws(-us-gov|-cn)?:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a KMS key ARN in the aws, aws-us-gov or aws-cn partition."
  }
}

variable "use_fips_endpoints" {
  description = "Build the documented S3 endpoint output with the FIPS hostname"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags for every resource"
  type        = map(string)
  default     = {}
}
