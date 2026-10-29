variable "subscription_id" {
  description = "Azure subscription ID the AKS cluster and its supporting resources are provisioned in"
  type        = string

  validation {
    condition     = length(var.subscription_id) > 0
    error_message = "subscription_id must not be empty."
  }
}

variable "prefix" {
  description = "Naming prefix applied to the AKS cluster and its node pools"
  type        = string
  default     = "PLACEHOLDER_PREFIX"
}

variable "location" {
  description = "Azure region the AKS cluster is created in"
  type        = string
  default     = "PLACEHOLDER_AZURE_REGION"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the AKS control plane and node pools"
  type        = string
  default     = "1.29"
}

variable "networking_resource_group" {
  type        = string
  description = "RG containing the spoke VNets from hub_spoke_network."
}

variable "aks_vnet_name" {
  description = "Name of the spoke VNet the cluster's nodes and pods attach to"
  type        = string
}

variable "aks_nodes_subnet_name" {
  description = "Subnet within aks_vnet_name that cluster nodes attach to"
  type        = string
}

variable "aks_pods_subnet_name" {
  default     = ""
  description = "Deprecated compatibility input; ignored because this workflow uses Azure CNI Overlay and pod_cidr rather than an Azure CNI pod subnet"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Container Insights"
  type        = string
}

variable "pod_cidr" {
  description = "CIDR block for pod IPs when not using Azure CNI pod subnets"
  type        = string
  default     = "PLACEHOLDER_POD_CIDR"
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes Service cluster IPs; must not overlap the VNet's address space"
  type        = string
  default     = "PLACEHOLDER_SVC_CIDR"
}

variable "dns_service_ip" {
  description = "IP address within service_cidr reserved for the cluster's DNS service"
  type        = string
  default     = "PLACEHOLDER_DNS_SVC_IP"
}

variable "system_pool_vm_size" {
  description = "VM size for the system node pool"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_pool_node_count" {
  description = "Fixed node count for the system node pool"
  type        = number
  default     = 3

  validation {
    condition     = var.system_pool_node_count > 0
    error_message = "system_pool_node_count must be greater than zero."
  }
}

variable "workload_pool_vm_size" {
  description = "VM size for the general workload node pool"
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "workload_pool_node_count" {
  description = "Fixed node count for the general workload node pool"
  type        = number
  default     = 3

  validation {
    condition     = var.workload_pool_node_count > 0
    error_message = "workload_pool_node_count must be greater than zero."
  }
}

variable "deploy_spot_pool" {
  description = "Deploy an additional Spot-priority node pool for interruptible, cost-optimized workloads"
  type        = bool
  default     = false
}

variable "spot_pool_vm_size" {
  description = "VM size for the Spot node pool; used only when deploy_spot_pool is true"
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "spot_pool_max_count" {
  description = "Maximum autoscaled node count for the Spot node pool"
  type        = number
  default     = 10

  validation {
    condition     = var.spot_pool_max_count > 0
    error_message = "spot_pool_max_count must be greater than zero."
  }
}

variable "availability_zones" {
  description = "Availability zones node pools are spread across"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "tags" {
  description = "Additional resource tags merged with terraform-managed tags"
  type        = map(string)
  default = {
    managed-by  = "terraform"
    environment = "PLACEHOLDER_ENV"
  }
}

variable "azure_ad_tenant_id" {
  description = "Microsoft Entra tenant ID used for managed AKS authentication"
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_ad_tenant_id))
    error_message = "azure_ad_tenant_id must be a tenant UUID."
  }
}

variable "azure_ad_admin_group_ids" {
  description = "Microsoft Entra group object IDs granted cluster administration; Azure role assignments are managed separately"
  type        = list(string)
  default     = []
}
