output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.this.name
}

output "execution_role_policy_arn" {
  description = "Managed policy ARN attached to the execution role, built from the active partition"
  value       = aws_iam_role_policy_attachment.execution.policy_arn
}

output "task_role_name" {
  description = "Task role name; attach application permissions here"
  value       = aws_iam_role.task.name
}

output "security_group_id" {
  description = "Security group of the tasks"
  value       = aws_security_group.this.id
}
