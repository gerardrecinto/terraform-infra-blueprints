# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Swift lifecycle module -- analogous to the AWS s3_lifecycle, GCP gcs_lifecycle, and
# AliCloud oss_lifecycle modules
# Swift has no native storage-class tiering like the hyperscalers; retention here is
# enforced via per-object expiry (X-Delete-After) applied at write time by callers, plus
# container-level versioning so overwritten objects aren't silently lost before expiry

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}

# Versions container holds prior versions of objects in the primary container --
# created first so its name exists before the primary container references it
resource "openstack_objectstorage_container_v1" "versions" {
  region          = var.region
  name            = "${var.container_name}-versions"
  container_read  = ""
  container_write = ""

  metadata = {
    purpose = "version-history-for-${var.container_name}"
  }
}

resource "openstack_objectstorage_container_v1" "this" {
  region = var.region
  name   = var.container_name

  # Private by default -- caller must explicitly widen container_read for public assets
  container_read  = var.public_read ? ".r:*" : ""
  container_write = ""

  versioning_legacy {
    location = openstack_objectstorage_container_v1.versions.name
    type     = "versions"
  }

  metadata = merge(var.metadata, {
    environment      = var.environment
    default_ttl_days = tostring(var.default_object_ttl_days)
    terraform        = "true"
  })
}

# Temp URL key so short-lived signed download links can be issued without making
# the whole container public
resource "openstack_objectstorage_tempurl_v1" "download" {
  count     = var.enable_tempurl_key ? 1 : 0
  container = openstack_objectstorage_container_v1.this.name
  object    = var.tempurl_probe_object
  method    = "get"
  ttl       = var.tempurl_ttl_seconds
}
