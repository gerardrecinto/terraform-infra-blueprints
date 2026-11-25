output "node_group_name" {
  description = "Name of the GPU node group."
  value       = aws_eks_node_group.training.node_group_name
}

output "checkpoint_bucket" {
  description = "Bucket that holds training checkpoints."
  value       = aws_s3_bucket.checkpoints.bucket
}

output "checkpoint_access_policy_json" {
  description = "IAM policy for the training service account: read and write checkpoints, nothing else."
  value       = data.aws_iam_policy_document.checkpoint_access.json
}

output "pod_scheduling" {
  description = "What a training pod needs to land on these nodes."
  value = {
    node_selector = { workload = "ml-training" }
    toleration    = { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }
    gpu_limit     = "nvidia.com/gpu"
  }
}
