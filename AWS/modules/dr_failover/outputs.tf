output "fqdn" {
  description = "Name clients resolve"
  value       = var.record_name
}

output "traffic_percent" {
  description = "Intended share of traffic per site in percent, from the weights; actual shares also depend on health checks"
  value = {
    for k, v in var.endpoints : k => floor(100 * v.weight / local.total_weight)
  }
}

output "health_check_ids" {
  description = "Route 53 health check IDs per site, for alarms (health check metrics live in us-east-1) and dashboards"
  value       = { for k, h in aws_route53_health_check.this : k => h.id }
}

output "drained_sites" {
  description = "Sites currently set to weight 0 (drained)"
  value       = [for k, v in var.endpoints : k if v.weight == 0]
}
