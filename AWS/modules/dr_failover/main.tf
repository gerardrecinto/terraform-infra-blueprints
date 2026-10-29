# Weighted DNS with health checks for switching traffic between sites.
#
# The same name is published once per site with a weight. Normal operation splits traffic
# by weight (for example 100/0 for an active-passive pair, or 50/50 for active-active).
# A planned "pull the plug" drains a site by setting its weight to 0 and applying; an
# unplanned failure is handled automatically because each site's health check removes it
# from DNS answers once it fails failure_threshold checks in a row.
#
# Reference implementation of a common pattern; it carries no production metrics. The
# procedure around it is in docs/pull-the-plug-runbook.md.

locals {
  checked = { for k, v in var.endpoints : k => v if v.health_check_enabled }

  total_weight = sum([for e in values(var.endpoints) : e.weight])

  tags = merge(
    {
      managed-by = "terraform"
      module     = "dr_failover"
    },
    var.tags,
  )
}

resource "aws_route53_health_check" "this" {
  for_each = local.checked

  type              = each.value.health_check_protocol
  fqdn              = each.value.target
  port              = each.value.health_check_port
  resource_path     = each.value.health_check_path
  failure_threshold = var.failure_threshold
  request_interval  = var.request_interval
  measure_latency   = true
  enable_sni        = each.value.health_check_protocol == "HTTPS"

  tags = merge(local.tags, { Name = "${var.record_name}-${each.key}" })
}

resource "aws_route53_record" "this" {
  for_each = var.endpoints

  zone_id         = var.zone_id
  name            = var.record_name
  type            = "CNAME"
  ttl             = var.ttl
  set_identifier  = each.key
  records         = [each.value.target]
  health_check_id = each.value.health_check_enabled ? aws_route53_health_check.this[each.key].id : null

  weighted_routing_policy {
    weight = each.value.weight
  }
}
