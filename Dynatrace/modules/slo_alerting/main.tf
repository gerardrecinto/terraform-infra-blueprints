# One availability SLO with error budget burn rate, plus an alerting profile that pages on
# availability problems at once and on errors and slowdowns only when they persist.

resource "dynatrace_slo_v2" "availability" {
  name               = "${var.service_name} availability"
  enabled            = true
  custom_description = "Share of successful server requests for ${var.service_name}"
  evaluation_type    = "AGGREGATE"
  evaluation_window  = var.evaluation_window
  filter             = "type(\"SERVICE\"),entityName.equals(\"${var.service_name}\")"
  metric_name        = "slo_${replace(lower(var.service_name), "/[^a-z0-9]/", "_")}_availability"
  metric_expression  = "(100)*(builtin:service.errors.server.successCount:splitBy())/(builtin:service.requestCount.server:splitBy())"
  target_success     = var.availability_target
  target_warning     = min(var.availability_target + var.warning_margin, 99.99)

  error_budget_burn_rate {
    burn_rate_visualization_enabled = true
    fast_burn_threshold             = var.fast_burn_threshold
  }
}

resource "dynatrace_alerting" "oncall" {
  name = var.alerting_profile_name

  rules {
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "AVAILABILITY"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = var.page_after_minutes
      severity_level   = "ERROR"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = var.page_after_minutes
      severity_level   = "PERFORMANCE"
    }
  }
}
