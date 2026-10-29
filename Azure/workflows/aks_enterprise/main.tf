terraform {
  required_version = ">= 1.5"

  backend "azurerm" {
    resource_group_name  = "PLACEHOLDER_TFSTATE_RG"
    storage_account_name = "PLACEHOLDER_TFSTATE_SA"
    container_name       = "tfstate"
    key                  = "workloads/aks.tfstate"
    use_oidc             = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
  use_oidc        = true
  subscription_id = var.subscription_id
}

data "azurerm_subnet" "nodes" {
  name                 = var.aks_nodes_subnet_name
  virtual_network_name = var.aks_vnet_name
  resource_group_name  = var.networking_resource_group
}


resource "azurerm_resource_group" "aks" {
  name     = "${var.prefix}-aks-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.prefix}-aks-identity"
  resource_group_name = azurerm_resource_group.aks.name
  location            = var.location
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = data.azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                      = "${var.prefix}-aks"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.aks.name
  dns_prefix                = var.prefix
  kubernetes_version        = var.kubernetes_version
  automatic_channel_upgrade = "patch"

  private_cluster_enabled             = true
  private_dns_zone_id                 = "System"
  private_cluster_public_fqdn_enabled = false
  role_based_access_control_enabled   = true

  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    tenant_id              = var.azure_ad_tenant_id
    admin_group_object_ids = var.azure_ad_admin_group_ids
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # CNI Overlay: pods use an overlay CIDR, not VNet IPs.
  # Prevents IP exhaustion that classic Azure CNI causes on large clusters.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "userDefinedRouting"
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_pool_vm_size
    node_count                   = var.system_pool_node_count
    vnet_subnet_id               = data.azurerm_subnet.nodes.id
    zones                        = var.availability_zones
    os_disk_type                 = "Ephemeral"
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtemp"
    node_labels                  = { "nodepool-type" = "system" }
  }

  # Workload Identity replaces pod-managed identity (NMI).
  # Federated OIDC tokens are bound per ServiceAccount, eliminating the
  # SSRF escalation path where any pod could reach the node IMDS endpoint.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  azure_policy_enabled   = true
  local_account_disabled = true

  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  tags = var.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  name                  = "workload"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.workload_pool_vm_size
  node_count            = var.workload_pool_node_count
  zones                 = var.availability_zones
  vnet_subnet_id        = data.azurerm_subnet.nodes.id
  os_disk_type          = "Ephemeral"
  mode                  = "User"
  node_labels           = { "nodepool-type" = "workload" }
  tags                  = var.tags
}

# Spot pool for batch workloads — eviction policy Delete (not Deallocate) avoids orphaned disks
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.deploy_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.spot_pool_vm_size
  node_count            = 0
  min_count             = 0
  max_count             = var.spot_pool_max_count
  enable_auto_scaling   = true
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  vnet_subnet_id        = data.azurerm_subnet.nodes.id
  os_disk_type          = "Ephemeral"
  mode                  = "User"

  node_labels = { "kubernetes.azure.com/scalesetpriority" = "spot" }
  node_taints = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
  tags        = var.tags
}
