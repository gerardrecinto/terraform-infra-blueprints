# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Magnum K8s module -- managed Kubernetes cluster on private OpenStack clouds
# Analogous to the EKS/AKS/GKE/ACK modules for the hyperscalers
# Magnum drives Nova, Neutron, and Cinder underneath to stand up the cluster's VMs,
# networking, and volumes; this module owns the cluster template and cluster resources

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}

# Cluster template pins the image, flavor, and network policy for every cluster
# built from it -- keeps fleet-wide upgrades to one resource instead of N clusters
resource "openstack_containerinfra_clustertemplate_v1" "this" {
  name                  = "${var.cluster_name}-template"
  image                 = var.cluster_image
  coe                   = "kubernetes"
  master_flavor         = var.master_flavor
  flavor                = var.node_flavor
  external_network_id   = var.external_network_id
  network_driver        = "calico"
  volume_driver         = "cinder"
  docker_storage_driver = "overlay2"
  dns_nameserver        = var.dns_nameserver
  master_lb_enabled     = true
  floating_ip_enabled   = false

  labels = {
    kube_tag             = var.kubernetes_version
    cloud_provider_tag   = var.kubernetes_version
    container_runtime    = "containerd"
    auto_healing_enabled = "true"
    auto_scaling_enabled = "true"
    availability_zone    = var.availability_zone
  }
}

resource "openstack_containerinfra_cluster_v1" "this" {
  name                = var.cluster_name
  cluster_template_id = openstack_containerinfra_clustertemplate_v1.this.id
  master_count        = var.master_count
  node_count          = var.initial_node_count
  keypair             = var.keypair_name

  merge_labels = true
  labels = {
    environment = var.environment
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
