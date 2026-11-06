# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
#
# Root Terragrunt config. Every unit under live/ includes this file so the tags,
# provider pin, and environment-derived naming below are defined exactly once
# instead of copy-pasted into every dev/prod terragrunt.hcl.
#
# This repo standardized on Terraform (see go.yml/ci.yml pinning an exact
# toolchain version), not OpenTofu, so pin the binary explicitly rather than
# letting Terragrunt auto-detect.
terraform_binary = "terraform"

locals {
  # path_relative_to_include() from a leaf unit is e.g. "alicloud/dev/ack" --
  # split it once here instead of re-deriving cloud/environment in every leaf.
  path_parts  = split("/", path_relative_to_include())
  cloud       = local.path_parts[0]
  environment = local.path_parts[1]

  common_tags = {
    managed_by = "terragrunt"
    repo       = "terraform-infra-blueprints"
    cloud      = local.cloud
  }
}

# No remote_state block here on purpose: each source workflow under AWS/, GCP/,
# AliCloud/, and OpenStack/ already declares its own backend (see their
# versions.tf/main.tf), matching how this repo's workflows are meant to be run
# standalone too, not only through Terragrunt. This root config's job is DRY
# inputs and environment layout, not backend generation.
