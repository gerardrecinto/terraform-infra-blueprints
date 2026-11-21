mock_provider "aws" {}

variables {
  name                   = "research"
  cluster_name           = "ml-east"
  node_role_arn          = "arn:aws:iam::123456789012:role/ml-nodes"
  subnet_ids             = ["subnet-aaa", "subnet-bbb"]
  checkpoint_bucket_name = "research-ml-checkpoints"
  kms_key_arn            = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
}

run "defaults_scale_to_zero_and_keep_non_gpu_pods_off" {
  command = plan

  assert {
    condition     = aws_eks_node_group.training.scaling_config[0].min_size == 0 && aws_eks_node_group.training.capacity_type == "SPOT"
    error_message = "The default group must scale to zero and use SPOT."
  }

  assert {
    condition     = one([for t in aws_eks_node_group.training.taint : t.key]) == "nvidia.com/gpu" && one([for t in aws_eks_node_group.training.taint : t.effect]) == "NO_SCHEDULE"
    error_message = "GPU nodes must carry a NoSchedule taint so other workloads stay off them."
  }

  assert {
    condition     = aws_eks_node_group.training.ami_type == "AL2023_x86_64_NVIDIA"
    error_message = "GPU nodes need the NVIDIA AMI."
  }
}

run "checkpoint_bucket_is_private_encrypted_and_expires" {
  command = plan

  variables {
    checkpoint_retention_days = 7
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.checkpoints.block_public_acls && aws_s3_bucket_public_access_block.checkpoints.block_public_policy && aws_s3_bucket_public_access_block.checkpoints.ignore_public_acls && aws_s3_bucket_public_access_block.checkpoints.restrict_public_buckets
    error_message = "The checkpoint bucket must block all public access."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.checkpoints.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm]) == "aws:kms"
    error_message = "Checkpoints must be encrypted with KMS."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.checkpoints.rule : r.apply_server_side_encryption_by_default[0].kms_master_key_id]) == var.kms_key_arn
    error_message = "The bucket must use the customer-managed key that was passed in."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.checkpoints.rule : one(r.expiration).days]) == 7
    error_message = "Checkpoints must expire after checkpoint_retention_days."
  }
}

run "spot_with_one_instance_type_is_warned_about" {
  command = plan

  variables {
    instance_types = ["g5.2xlarge"]
  }

  expect_failures = [check.spot_needs_more_than_one_type]
}

run "on_demand_with_one_instance_type_is_fine" {
  command = plan

  variables {
    instance_types = ["p4d.24xlarge"]
    capacity_type  = "ON_DEMAND"
  }

  assert {
    condition     = aws_eks_node_group.training.capacity_type == "ON_DEMAND"
    error_message = "ON_DEMAND must pass through."
  }
}

run "bad_capacity_type_fails_at_plan" {
  command = plan

  variables {
    capacity_type = "RESERVED"
  }

  expect_failures = [var.capacity_type]
}

run "sizes_out_of_order_are_caught" {
  command = plan

  variables {
    min_size     = 3
    desired_size = 1
    max_size     = 2
  }

  expect_failures = [check.size_order]
}
