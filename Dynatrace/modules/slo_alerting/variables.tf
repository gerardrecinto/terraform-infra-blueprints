variable "service_name" {
  description = "Name of the Dynatrace service the SLO measures (the entity name Dynatrace discovered, for example checkout-api)"
  type        = string

  validation {
    condition     = length(var.service_name) > 0 && !can(regex("[\"\\\\]", var.service_name))
    error_message = "service_name must not be empty or contain quotes or backslashes, because it is placed inside an entity selector."
  }
}

variable "availability_target" {
  description = "Availability the service must meet over the evaluation window, as a percentage (99.9 means 0.1 percent of requests may fail)"
  type        = number
  default     = 99.9

  validation {
    condition     = var.availability_target > 90 && var.availability_target < 100
    error_message = "availability_target must be above 90 and below 100."
  }
}

variable "warning_margin" {
  description = "Percentage points above the target at which the SLO turns to warning, so a team hears about a shrinking error budget before it is spent"
  type        = number
  default     = 0.05

  validation {
    condition     = var.warning_margin > 0 && var.warning_margin < 1
    error_message = "warning_margin must be greater than 0 and less than 1."
  }
}

variable "evaluation_window" {
  description = "Rolling window the SLO is evaluated over, in Dynatrace timeframe syntax (-7d, -30d)"
  type        = string
  default     = "-7d"

  validation {
    condition     = can(regex("^-[0-9]+[hdw]$", var.evaluation_window))
    error_message = "evaluation_window must look like -24h, -7d or -4w."
  }
}

variable "fast_burn_threshold" {
  description = "Error budget burn rate that counts as a fast burn; 10 means the budget would be gone in a tenth of the window"
  type        = number
  default     = 10

  validation {
    condition     = var.fast_burn_threshold >= 1
    error_message = "fast_burn_threshold must be 1 or more."
  }
}

variable "alerting_profile_name" {
  description = "Name of the alerting profile that decides which problems page someone"
  type        = string
  default     = "platform-oncall"
}

variable "page_after_minutes" {
  description = "Minutes an error or slowdown problem must persist before it pages, so a short blip does not wake anyone; availability problems page immediately"
  type        = number
  default     = 5

  validation {
    condition     = var.page_after_minutes >= 0 && var.page_after_minutes <= 60
    error_message = "page_after_minutes must be between 0 and 60."
  }
}
