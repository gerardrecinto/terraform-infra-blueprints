output "slo_id" {
  description = "ID of the availability SLO"
  value       = dynatrace_slo_v2.availability.id
}

output "alerting_profile_id" {
  description = "ID of the alerting profile to attach to a problem notification (PagerDuty, Slack, email)"
  value       = dynatrace_alerting.oncall.id
}
