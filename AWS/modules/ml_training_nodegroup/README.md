# ml_training_nodegroup

A GPU node group for model training on an existing EKS cluster, plus the encrypted bucket training jobs write checkpoints to. Terraform validation and mocked plan tests only; nothing here has been applied to a real account.

## Use it

```hcl
module "training" {
  source                 = "./AWS/modules/ml_training_nodegroup"
  name                   = "research"
  cluster_name           = "ml-east"
  node_role_arn          = aws_iam_role.nodes.arn
  subnet_ids             = var.private_subnet_ids
  checkpoint_bucket_name = "research-ml-checkpoints"
  kms_key_arn            = aws_kms_key.ml.arn
  max_size               = 4
}
```

Attach `module.training.checkpoint_access_policy_json` to the IRSA role of the training service account. A pod lands on these nodes with the `pod_scheduling` output: the `workload=ml-training` selector, a toleration for `nvidia.com/gpu`, and a `nvidia.com/gpu` limit.

## Defaults and why

- SPOT, scaling from 0 to 4. A GPU idle between runs costs money, and `max_size` is the cost ceiling.
- Spot needs two or more instance types. One type fails whenever it is out of capacity, so the plan warns.
- Spot nodes can be reclaimed, so the job must write checkpoints to the bucket and resume from the newest one. Use `ON_DEMAND` for a run that cannot restart.
- The bucket blocks public access, uses your KMS key and enables versioning to recover overwritten or deleted checkpoints. Current objects expire after `checkpoint_retention_days` (14). Previous versions expire the same number of days after becoming noncurrent, so this is not a total object-age limit. Copy a checkpoint you want to keep to a model registry first.
- Restoring an older version needs `s3:GetObjectVersion`, which the training policy does not grant. Give that permission to a separate recovery role. S3 access logging is not configured by this module; configure it separately if your audit policy requires it.

## Check it

```sh
cd AWS/modules/ml_training_nodegroup
terraform init -backend=false && terraform validate && terraform test
```

Needs Terraform 1.7 or later and no credentials.

## Roll back

`terraform destroy` removes the node group and the bucket. A bucket that still holds checkpoints, previous versions or delete markers will not delete until it is emptied, which is deliberate.

## Not covered

The NVIDIA device plugin, the cluster itself, the node IAM role and the KMS key. Autoscaling beyond the node group's own scaling bounds, multi-node networking (EFA, placement groups) and Slurm are not included. Instance prices and Spot availability change; check them for your region.
