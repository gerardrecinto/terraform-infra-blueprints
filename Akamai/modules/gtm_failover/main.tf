# Akamai Global Traffic Management: one domain, one property, one liveness test, N sites.
# Use it for the "pull the plug" switch between data centers: set mode to failover and let
# the liveness test move traffic, or set mode to weighted and drain a site by setting its weight to 0.

resource "akamai_gtm_domain" "this" {
  name                    = var.domain_name
  type                    = var.domain_type
  contract                = var.contract_id
  group                   = var.group_id
  email_notification_list = var.notification_emails
  comment                 = "Managed by Terraform (gtm_failover module)"
  wait_on_complete        = true
}

resource "akamai_gtm_datacenter" "site" {
  for_each = var.sites

  domain           = akamai_gtm_domain.this.name
  nickname         = each.value.nickname
  city             = each.value.city
  country          = each.value.country
  latitude         = each.value.latitude
  longitude        = each.value.longitude
  wait_on_complete = true
}

resource "akamai_gtm_property" "this" {
  domain                 = akamai_gtm_domain.this.name
  name                   = var.property_name
  type                   = var.mode == "failover" ? "failover" : "weighted-round-robin"
  handout_mode           = "normal"
  handout_limit          = var.mode == "failover" ? 1 : length(var.sites)
  score_aggregation_type = "worst"
  failover_delay         = var.health_check.failover_delay
  failback_delay         = var.health_check.failback_delay
  wait_on_complete       = true

  liveness_test {
    name                 = "${var.property_name}-health"
    test_object_protocol = var.health_check.protocol
    test_object_port     = var.health_check.port
    test_object          = var.health_check.protocol == "TCP" ? null : var.health_check.path
    test_interval        = var.health_check.interval
    test_timeout         = var.health_check.timeout
  }

  dynamic "traffic_target" {
    for_each = var.sites

    content {
      datacenter_id = akamai_gtm_datacenter.site[traffic_target.key].datacenter_id
      enabled       = traffic_target.value.enabled
      servers       = traffic_target.value.servers
      weight        = var.mode == "weighted" ? traffic_target.value.weight : null
      precedence    = var.mode == "failover" ? traffic_target.value.precedence : null
    }
  }
}
