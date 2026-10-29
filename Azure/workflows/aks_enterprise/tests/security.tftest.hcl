mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/blueprints-rg/providers/Microsoft.Network/virtualNetworks/test/subnets/nodes"
    }
  }
}

variables {
  subscription_id            = "00000000-0000-0000-0000-000000000001"
  prefix                     = "blueprints"
  location                   = "westus2"
  networking_resource_group  = "blueprints-rg"
  aks_vnet_name              = "blueprints-vnet"
  aks_nodes_subnet_name      = "nodes"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/blueprints-rg/providers/Microsoft.OperationalInsights/workspaces/test"
  pod_cidr                   = "10.244.0.0/16"
  service_cidr               = "10.0.0.0/16"
  dns_service_ip             = "10.0.0.10"
  azure_ad_tenant_id         = "00000000-0000-0000-0000-000000000001"
}

run "private_overlay_with_identity_and_policy" {
  command = plan
  assert {
    condition     = azurerm_kubernetes_cluster.main.private_cluster_enabled && !azurerm_kubernetes_cluster.main.private_cluster_public_fqdn_enabled
    error_message = "The enterprise control plane must remain private."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.role_based_access_control_enabled && azurerm_kubernetes_cluster.main.local_account_disabled && azurerm_kubernetes_cluster.main.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    error_message = "The enterprise cluster must enforce Entra RBAC with no local administrator credentials."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.network_profile[0].network_policy == "calico"
    error_message = "Overlay networking must include a policy engine."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.default_node_pool[0].pod_subnet_id == null && azurerm_kubernetes_cluster_node_pool.workload.pod_subnet_id == null
    error_message = "Overlay node pools must not also request Azure CNI pod-subnet addressing."
  }
}

run "invalid_tenant_rejected" {
  command = plan
  variables { azure_ad_tenant_id = "not-a-tenant-uuid" }
  expect_failures = [var.azure_ad_tenant_id]
}
