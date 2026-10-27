output "web_acl_arn" {
  description = "ARN of the web ACL; attach it to a CloudFront distribution with web_acl_id when scope is CLOUDFRONT"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "ID of the web ACL"
  value       = aws_wafv2_web_acl.this.id
}

output "web_acl_name" {
  description = "Name of the web ACL, also the base for its CloudWatch metric names"
  value       = aws_wafv2_web_acl.this.name
}

output "log_group_name" {
  description = "Name of the CloudWatch Logs group receiving WAF logs, or empty when logging is disabled"
  value       = local.logging ? aws_cloudwatch_log_group.waf[0].name : ""
}

output "rate_limit_metric_name" {
  description = "CloudWatch metric name of the per-IP rate rule, for alarms and dashboards"
  value       = "${local.acl_name}-rate-limit-per-ip"
}

output "associated_resource_arns" {
  description = "Resources the web ACL is attached to"
  value       = [for a in aws_wafv2_web_acl_association.this : a.resource_arn]
}
