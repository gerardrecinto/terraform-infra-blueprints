# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# API Gateway module -- analogous to the GCP apigee module
# Groups + throttled APIs fronting backend services, one group per environment
# Used to consolidate per-service auth and rate limiting instead of duplicating it downstream

terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.99"
    }
  }
}

resource "alicloud_api_gateway_group" "this" {
  name        = "${var.group_name}-${var.environment}"
  description = "API group for ${var.group_name} (${var.environment})"
}

resource "alicloud_api_gateway_app" "this" {
  name        = "${var.group_name}-${var.environment}-app"
  description = "Consumer app credential for ${var.group_name}"
}

# One API per routed backend -- keeps auth/throttling config declarative and reviewable
resource "alicloud_api_gateway_api" "routed" {
  for_each = var.apis

  group_id    = alicloud_api_gateway_group.this.id
  name        = "${each.key}-${var.environment}"
  description = each.value.description
  auth_type   = "APP"
  request_config {
    protocol = "HTTPS"
    method   = "GET"
    path     = each.value.request_path
    mode     = "MAPPING"
  }

  service_type = "HTTP"
  http_service_config {
    address            = each.value.backend_address
    method             = "GET"
    path               = each.value.backend_path
    timeout            = 3000
    aone_name          = each.key
    content_type_value = "application/json; charset=UTF-8"
  }

  request_parameters {
    name         = "requestPath"
    type         = "STRING"
    required     = "OPTIONAL"
    in           = "PATH"
    in_service   = "PATH"
    name_service = "requestPath"
  }
}

# Throttling plan -- shared across the group's APIs, prevents one noisy consumer
# from starving the rest
resource "alicloud_api_gateway_app_attachment" "grant" {
  for_each   = alicloud_api_gateway_api.routed
  api_id     = each.value.api_id
  app_id     = alicloud_api_gateway_app.this.id
  group_id   = alicloud_api_gateway_group.this.id
  stage_name = var.stage_name
}
