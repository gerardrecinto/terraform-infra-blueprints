variable "zone_id" {
  description = "ID of the Route 53 hosted zone that holds the record"
  type        = string

  validation {
    condition     = length(var.zone_id) > 0
    error_message = "zone_id must not be empty."
  }
}

variable "record_name" {
  description = "Fully qualified name clients resolve (for example app.example.com); the same name is published once per site"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$", var.record_name))
    error_message = "record_name must be a valid DNS name."
  }
}

variable "ttl" {
  description = "TTL in seconds for the record; keep it low (30 to 60) so a traffic switch takes effect quickly"
  type        = number
  default     = 30

  validation {
    condition     = var.ttl >= 1 && var.ttl <= 300
    error_message = "ttl must be between 1 and 300 seconds so that a traffic switch is not delayed by caches."
  }
}

variable "endpoints" {
  description = "Sites that can serve the record, keyed by a short site name such as dc-east or aws-west. weight (0 to 255) is the share of traffic: set a site to 0 to drain it. Health checks remove an unhealthy site automatically regardless of weight"
  type = map(object({
    target                = string
    weight                = number
    health_check_enabled  = optional(bool, true)
    health_check_protocol = optional(string, "HTTPS")
    health_check_port     = optional(number, 443)
    health_check_path     = optional(string, "/healthz")
  }))

  validation {
    condition     = length(var.endpoints) >= 2
    error_message = "endpoints needs at least two sites, otherwise there is nothing to fail over to."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.weight >= 0 && e.weight <= 255])
    error_message = "Every endpoint weight must be between 0 and 255."
  }

  validation {
    condition     = anytrue([for e in values(var.endpoints) : e.weight > 0])
    error_message = "At least one endpoint must have a weight above 0; Route 53 treats an all-zero set as equal weights, which would send traffic to a site you meant to drain."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : contains(["HTTP", "HTTPS"], e.health_check_protocol)])
    error_message = "health_check_protocol must be HTTP or HTTPS."
  }
}

variable "failure_threshold" {
  description = "Consecutive failed health checks before a site is marked unhealthy and removed from DNS answers"
  type        = number
  default     = 3

  validation {
    condition     = var.failure_threshold >= 1 && var.failure_threshold <= 10
    error_message = "failure_threshold must be between 1 and 10."
  }
}

variable "request_interval" {
  description = "Seconds between health checks: 10 (fast, higher cost) or 30 (standard)"
  type        = number
  default     = 10

  validation {
    condition     = contains([10, 30], var.request_interval)
    error_message = "request_interval must be 10 or 30."
  }
}

variable "tags" {
  description = "Extra tags merged into the health checks"
  type        = map(string)
  default     = {}
}
