# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders. This is an original portfolio
# implementation demonstrating the Apigee proxy-consolidation pattern generically.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "example-terraform-state"
    prefix = "apigee"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "apigee" {
  source = "../../modules/apigee"

  project_id                = var.project_id
  org_id                    = var.project_id
  environment               = var.environment
  region                    = var.region
  apigee_env_name           = var.environment
  apigee_env_group_hostname = var.api_hostname
  vpc_network_name          = var.vpc_network
  vpc_peering_cidr          = var.vpc_peering_cidr
  token_validation_url      = var.token_validation_url

  api_proxies = {
    # device-api -- example device-management API
    # Handles device auth tokens and routes to different device backend services
    device_api = {
      display_name       = "Device API"
      description        = "Device management API proxy -- token auth, path routing to device management and SSH gateway services"
      base_path          = "/device-api/v2"
      target_url         = "https://${var.device_api_backend_host}"
      token_auth_enabled = true
      path_routes = {
        "/devices"    = "https://${var.device_api_backend_host}/api/devices"
        "/ssh"        = "https://${var.device_api_backend_host}/api/ssh-gateway"
        "/workspaces" = "https://${var.device_api_backend_host}/api/workspaces"
        "/builds"     = "https://${var.device_api_backend_host}/api/builds"
      }
    }

    # package-api -- example software package delivery API
    # Pre-signed URL generation is handled by a backend service behind this proxy
    package_api = {
      display_name       = "Package API"
      description        = "Package delivery API proxy -- validates tokens and routes to package delivery service (pre-signed URL generator)"
      base_path          = "/package-api/v2"
      target_url         = "https://${var.package_api_backend_host}"
      token_auth_enabled = true
      path_routes = {
        "/packages" = "https://${var.package_api_backend_host}/api/packages"
        "/download" = "https://${var.package_api_backend_host}/api/presigned"
        "/catalog"  = "https://${var.package_api_backend_host}/api/catalog"
        "/releases" = "https://${var.package_api_backend_host}/api/releases"
      }
    }

    # inference-api -- example AI model inference API
    # Routes to different model serving endpoints based on path
    inference_api = {
      display_name       = "Inference API"
      description        = "Model inference API proxy -- model inference, deployment, and benchmark routing with token auth"
      base_path          = "/inference-api/v2"
      target_url         = "https://${var.inference_api_backend_host}"
      token_auth_enabled = true
      path_routes = {
        "/models"     = "https://${var.inference_api_backend_host}/api/models"
        "/inference"  = "https://${var.inference_api_backend_host}/api/inference"
        "/benchmarks" = "https://${var.inference_api_backend_host}/api/benchmarks"
        "/compile"    = "https://${var.inference_api_backend_host}/api/compile"
        "/profile"    = "https://${var.inference_api_backend_host}/api/profile"
      }
    }
  }

  tags = local.tags
}

locals {
  tags = {
    environment = var.environment
    project     = "platform"
    terraform   = "true"
  }
}

# GCS bucket for Apigee proxy bundle artifacts and Terraform state
module "apigee_artifacts" {
  source = "../../modules/gcs_lifecycle"

  project_id                  = var.project_id
  bucket_name                 = "${var.project_id}-apigee-artifacts-${var.environment}"
  location                    = "US"
  environment                 = var.environment
  object_prefix               = "bundles/"
  transition_to_nearline_days = 30
  transition_to_coldline_days = 90
  transition_to_archive_days  = 365
  labels                      = local.tags
}
