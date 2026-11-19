locals {
  is_private = var.visibility == "private"
}

resource "google_dns_managed_zone" "this" {
  project    = var.project_id
  name       = var.zone_name
  dns_name   = var.dns_name
  visibility = var.visibility
  labels     = var.labels

  dynamic "private_visibility_config" {
    for_each = local.is_private ? [1] : []
    content {
      dynamic "networks" {
        for_each = var.private_networks
        content {
          network_url = networks.value
        }
      }
    }
  }

  dynamic "dnssec_config" {
    for_each = !local.is_private && var.dnssec_enabled ? [1] : []
    content {
      state = "on"
    }
  }
}

resource "google_dns_record_set" "this" {
  for_each = var.records

  project      = var.project_id
  managed_zone = google_dns_managed_zone.this.name
  name         = each.value.name == "@" ? var.dns_name : "${each.value.name}.${var.dns_name}"
  type         = each.value.type
  ttl          = each.value.ttl
  rrdatas      = each.value.rrdatas
}
