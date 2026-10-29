# NOTE: Published as supporting evidence for skills on resume.
# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# AKS module -- Azure Kubernetes Service
# Covers IoT telemetry platform on Azure AKS (ExampleCorp platform engineering)
# Includes: Azure AD RBAC, ACR integration, Container Insights, NGINX ingress

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "${var.cluster_name}-${var.environment}"
  kubernetes_version  = var.kubernetes_version

  # No internet-facing control-plane endpoint or local admin credentials.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  role_based_access_control_enabled   = true
  local_account_disabled              = true

  # System node pool -- separate from workload pools for stability
  default_node_pool {
    name                         = "system"
    node_count                   = var.system_node_count
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = var.vnet_subnet_id
    os_disk_size_gb              = 128
    os_disk_type                 = "Managed"
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true # taint system pool for system pods only

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure AD-backed RBAC -- ties cluster access to Azure AD groups
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    tenant_id              = var.azure_ad_tenant_id
    admin_group_object_ids = var.azure_ad_admin_group_ids
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  # Container Insights for pod/node metrics and logs
  dynamic "oms_agent" {
    for_each = var.log_analytics_workspace_id != "" ? [1] : []
    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  # Azure Key Vault secrets provider for workload secrets
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # Workload identity for pod-level Azure AD auth (replaces aad-pod-identity)
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  auto_scaler_profile {
    balance_similar_node_groups = true
    expander                    = "least-waste"
    scale_down_delay_after_add  = "10m"
    scale_down_unneeded         = "10m"
  }

  tags = merge(var.tags, {
    Environment = var.environment
    Terraform   = "true"
  })
}

# Additional user node pools
resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  for_each = var.node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  vnet_subnet_id        = var.vnet_subnet_id
  os_disk_size_gb       = 128
  os_type               = "Linux"

  enable_auto_scaling = true
  min_count           = each.value.min_count
  max_count           = each.value.max_count
  node_count          = each.value.node_count

  node_labels = each.value.labels
  node_taints = each.value.taints

  upgrade_settings {
    max_surge = "33%"
  }

  tags = merge(var.tags, { Environment = var.environment })
}

# Grant AcrPull to kubelet identity so pods can pull from ACR without imagePullSecrets
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.acr_id != "" ? 1 : 0
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
