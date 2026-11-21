variable "name" {
  description = "Name prefix for the node group and the checkpoint bucket."
  type        = string
}

variable "cluster_name" {
  description = "Existing EKS cluster the GPU node group joins."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role the nodes run as. Needs the standard EKS worker, CNI and ECR read policies."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the nodes."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids needs at least one subnet."
  }
}

variable "instance_types" {
  description = "GPU instance types, in order of preference."
  type        = list(string)
  default     = ["g5.2xlarge", "g5.4xlarge"]
}

variable "capacity_type" {
  description = "SPOT is cheaper but nodes can be reclaimed, so training must checkpoint. ON_DEMAND for runs that cannot restart."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.capacity_type)
    error_message = "capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "min_size" {
  description = "Smallest node count. 0 lets the group scale to nothing between runs."
  type        = number
  default     = 0
}

variable "max_size" {
  description = "Largest node count. This is the cost ceiling."
  type        = number
  default     = 4

  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be at least 1."
  }
}

variable "desired_size" {
  description = "Starting node count. Later changes are ignored so an autoscaler can own it."
  type        = number
  default     = 0
}

variable "disk_size_gb" {
  description = "Root volume size. Datasets and image layers land here, so size it for the biggest job."
  type        = number
  default     = 200
}

variable "checkpoint_bucket_name" {
  description = "Globally unique name for the bucket that holds training checkpoints."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key that encrypts the checkpoint bucket. The training role is allowed to use it through checkpoint_access_policy_json."
  type        = string
}

variable "checkpoint_retention_days" {
  description = "Checkpoints older than this are deleted. Copy the ones you keep to a model registry first."
  type        = number
  default     = 14

  validation {
    condition     = var.checkpoint_retention_days >= 1
    error_message = "checkpoint_retention_days must be at least 1."
  }
}

variable "tags" {
  description = "Tags added to everything the module creates."
  type        = map(string)
  default     = {}
}

check "spot_needs_more_than_one_type" {
  assert {
    condition     = var.capacity_type != "SPOT" || length(var.instance_types) >= 2
    error_message = "SPOT with one instance type fails whenever that type is out of capacity. Give two or more in instance_types, or use ON_DEMAND."
  }
}

check "size_order" {
  assert {
    condition     = var.min_size <= var.desired_size && var.desired_size <= var.max_size
    error_message = "Sizes must satisfy min_size <= desired_size <= max_size."
  }
}
