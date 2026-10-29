mock_provider "aws" {
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000001"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::blueprints-dev-migration-snapshots"
    }
  }
}

# Snapshot policy is tested independently of the destination domain module.
override_module {
  target  = module.opensearch
  outputs = {}
}

variables {
  domain_name              = "blueprints"
  environment              = "dev"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  create_cognito_resources = false
  cognito_user_pool_id     = "us-west-2_example"
  cognito_identity_pool_id = "us-west-2:00000000-0000-0000-0000-000000000001"
}

run "snapshots_use_rotating_customer_key" {
  # All provider operations are mocked; this does not call Azure or AWS.
  command = apply
  assert {
    condition     = aws_kms_key.migration_snapshots.enable_key_rotation && aws_kms_key.migration_snapshots.deletion_window_in_days == 30
    error_message = "Snapshot key rotation and a 30-day deletion window must remain enabled."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.migration_snapshots.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "Snapshot objects must use explicit KMS encryption by default."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.migration_snapshots.rule).apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.migration_snapshots.arn
    error_message = "Snapshot encryption must use the rotating customer-managed key."
  }
  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_role_policy.snapshot_restore.policy).Statement : s.Action]), "kms:Decrypt")
    error_message = "The snapshot restore role needs permission to read the encrypted snapshots."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.migration_snapshots.block_public_acls && aws_s3_bucket_public_access_block.migration_snapshots.block_public_policy
    error_message = "Snapshot buckets must continue to block public access."
  }
}
