# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Apigee module
# Covers: Apigee API proxy provisioning with token auth, path routing, and rate limiting
# Each proxy includes:
#   - JS policy for Bearer token validation before forwarding to backend
#   - Path-based routing policies to direct traffic to different backend URLs
#   - Spike arrest and quota policies for rate limiting
#   - Shared flow attachment for common auth + logging logic

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "apigee" {
  for_each = toset([
    "apigee.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# VPC peering for Apigee managed runtime
resource "google_compute_global_address" "apigee_peering" {
  name          = "apigee-peering-${var.environment}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = split("/", var.vpc_peering_cidr)[1]
  network       = "projects/${var.project_id}/global/networks/${var.vpc_network_name}"
}

resource "google_service_networking_connection" "apigee_vpc_peering" {
  network                 = "projects/${var.project_id}/global/networks/${var.vpc_network_name}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.apigee_peering.name]

  depends_on = [google_project_service.apigee]
}

# Apigee organization
resource "google_apigee_organization" "this" {
  analytics_region   = var.region
  project_id         = var.project_id
  authorized_network = "projects/${var.project_id}/global/networks/${var.vpc_network_name}"
  runtime_type       = "CLOUD"

  depends_on = [
    google_project_service.apigee,
    google_service_networking_connection.apigee_vpc_peering,
  ]
}

# Apigee environment (dev / stage / prod)
resource "google_apigee_environment" "this" {
  name         = var.apigee_env_name
  description  = "${var.environment} environment"
  display_name = title(var.environment)
  org_id       = google_apigee_organization.this.id
}

# Environment group (maps hostname -> environment)
resource "google_apigee_envgroup" "this" {
  name      = "${var.environment}-group"
  hostnames = [var.apigee_env_group_hostname]
  org_id    = google_apigee_organization.this.id
}

resource "google_apigee_envgroup_attachment" "this" {
  envgroup_id = google_apigee_envgroup.this.id
  environment = google_apigee_environment.this.name
}

# Apigee instance (runtime node in the region)
resource "google_apigee_instance" "this" {
  name     = "${var.project_id}-${var.region}"
  location = var.region
  org_id   = google_apigee_organization.this.id

  peering_cidr_range = "SLASH_22"

  depends_on = [google_service_networking_connection.apigee_vpc_peering]
}

resource "google_apigee_instance_attachment" "this" {
  instance_id = google_apigee_instance.this.id
  environment = google_apigee_environment.this.name
}

# Render proxy bundle for each API proxy
data "archive_file" "proxy_bundle" {
  for_each = var.api_proxies

  type        = "zip"
  output_path = "/tmp/apigee-${each.key}-bundle.zip"

  # ProxyEndpoint: defines base path, route rules, and request/response flows
  source {
    filename = "apiproxy/proxies/default.xml"
    content = templatefile("${path.module}/templates/proxy_endpoint.xml.tpl", {
      proxy_name  = each.key
      base_path   = each.value.base_path
      target_name = "default"
      path_routes = each.value.path_routes
    })
  }

  # TargetEndpoint: backend URL
  source {
    filename = "apiproxy/targets/default.xml"
    content = templatefile("${path.module}/templates/target_endpoint.xml.tpl", {
      target_url = each.value.target_url
    })
  }

  # API proxy descriptor
  source {
    filename = "apiproxy/${each.key}.xml"
    content = templatefile("${path.module}/templates/api_proxy.xml.tpl", {
      proxy_name   = each.key
      display_name = each.value.display_name
      description  = each.value.description
      base_path    = each.value.base_path
    })
  }

  # JS policy: token validation (Bearer token -> token introspection endpoint)
  source {
    filename = "apiproxy/policies/JS-ValidateToken.xml"
    content = templatefile("${path.module}/templates/js_validate_token_policy.xml.tpl", {
      enabled = each.value.token_auth_enabled
    })
  }

  source {
    filename = "apiproxy/resources/jsc/validateToken.js"
    content = templatefile("${path.module}/templates/validateToken.js.tpl", {
      token_validation_url = var.token_validation_url
    })
  }

  # JS policy: path-based routing (rewrites target URL based on request path)
  source {
    filename = "apiproxy/policies/JS-PathRouter.xml"
    content  = file("${path.module}/templates/js_path_router_policy.xml.tpl")
  }

  source {
    filename = "apiproxy/resources/jsc/pathRouter.js"
    content = templatefile("${path.module}/templates/pathRouter.js.tpl", {
      path_routes = each.value.path_routes
    })
  }

  # Spike arrest: rate limiting to protect backends
  source {
    filename = "apiproxy/policies/SpikeArrest.xml"
    content  = file("${path.module}/templates/spike_arrest.xml.tpl")
  }
}

# Upload + deploy each proxy bundle to the environment.
#
# The google provider has no resource for individual API proxy bundles --
# Apigee proxy revisions are only manageable through the Apigee Management
# API / gcloud, not through native Terraform resources (google_apigee_api
# and google_apigee_api_deployment, used previously here, don't exist in
# the provider). This shells out to gcloud, which is the documented
# workaround. Re-runs on any change to the rendered bundle contents.
resource "null_resource" "proxy_deploy" {
  for_each = var.api_proxies

  triggers = {
    bundle_sha256 = data.archive_file.proxy_bundle[each.key].output_sha
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REV=$(gcloud apigee apis create ${each.key} \
        --project=${var.project_id} \
        --organization=${google_apigee_organization.this.name} \
        --bundle-file=${data.archive_file.proxy_bundle[each.key].output_path} \
        --format="value(revision)")
      gcloud apigee apis deploy \
        --project=${var.project_id} \
        --organization=${google_apigee_organization.this.name} \
        --environment=${google_apigee_environment.this.name} \
        --api=${each.key} \
        --revision="$REV" \
        --override
    EOT
  }

  depends_on = [google_apigee_instance_attachment.this]
}

# Service account for Apigee proxy to call backend services
resource "google_service_account" "apigee_proxy" {
  account_id   = "apigee-proxy-${var.environment}"
  display_name = "Apigee Proxy SA (${var.environment})"
}

resource "google_project_iam_member" "apigee_proxy_invoke" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.apigee_proxy.email}"
}
