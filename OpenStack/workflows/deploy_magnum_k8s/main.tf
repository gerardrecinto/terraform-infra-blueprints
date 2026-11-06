# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders. This is an original portfolio
# implementation demonstrating the Magnum + Swift + Octavia composition pattern generically.

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }

  backend "swift" {
    container         = "example-terraform-state"
    archive_container = "example-terraform-state-archive"
  }
}

module "k8s" {
  source = "../../modules/magnum_k8s"

  cluster_name        = "platform-${var.environment}"
  environment         = var.environment
  external_network_id = var.external_network_id
  keypair_name        = var.keypair_name
  master_count        = var.environment == "prod" ? 3 : 1
  initial_node_count  = var.environment == "prod" ? 3 : 2
}

module "backup_storage" {
  source = "../../modules/swift_lifecycle"

  container_name = "platform-${var.environment}-backups"
  environment    = var.environment
  public_read    = false

  # Backups get a year of retention; callers set X-Delete-After on write to enforce it
  default_object_ttl_days = 365
}

module "ingress" {
  source = "../../modules/octavia_ingress"

  lb_name           = "platform-${var.environment}-ingress"
  environment       = var.environment
  vip_subnet_id     = var.vip_subnet_id
  member_subnet_id  = var.member_subnet_id
  tls_container_ref = var.tls_container_ref

  # cluster-ingress-node -- one member per Magnum worker fronting the in-cluster
  # ingress controller's NodePort; scale this map as the node pool grows
  backend_members = {
    for idx, addr in var.ingress_node_addresses : "cluster-ingress-node-${idx}" => {
      address = addr
      port    = 30443
      weight  = 1
    }
  }
}
