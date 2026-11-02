variable "name" {
  description = "Service name; used for the cluster, task family, log group and role names"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 characters: lowercase letters, digits and hyphens, starting with a letter."
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

variable "vpc_id" {
  description = "VPC that holds the service"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the tasks"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Use at least two subnets in different availability zones."
  }
}

variable "container_image" {
  description = "Image reference. Pin a digest (name@sha256:...) for anything beyond a lab."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "cpu" {
  description = "Fargate task CPU units"
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096."
  }
}

variable "memory" {
  description = "Fargate task memory in MiB; must be a valid pairing for the chosen cpu"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks"
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed to reach container_port. Empty means no inbound rule."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.ingress_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "ingress_cidrs must be valid CIDR blocks and must not be 0.0.0.0/0."
  }
}

variable "egress_cidrs" {
  description = "CIDR blocks the tasks may reach on 443 (registry, AWS endpoints)"
  type        = list(string)
  default     = ["10.0.0.0/8"]

  validation {
    condition     = alltrue([for c in var.egress_cidrs : can(cidrhost(c, 0))])
    error_message = "egress_cidrs must be valid CIDR blocks."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch accepts."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN for the log group; empty string leaves the default"
  type        = string
  default     = ""
}

variable "min_capacity" {
  description = "Autoscaling minimum tasks"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Autoscaling maximum tasks"
  type        = number
  default     = 6

  validation {
    condition     = var.max_capacity >= 1
    error_message = "max_capacity must be at least 1."
  }
}

variable "cpu_target_percent" {
  description = "Average CPU percent the autoscaler holds"
  type        = number
  default     = 60

  validation {
    condition     = var.cpu_target_percent > 10 && var.cpu_target_percent < 95
    error_message = "cpu_target_percent must be between 11 and 94."
  }
}

variable "tags" {
  description = "Extra tags for every resource"
  type        = map(string)
  default     = {}
}
