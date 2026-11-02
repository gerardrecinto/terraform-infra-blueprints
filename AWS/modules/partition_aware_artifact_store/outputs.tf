output "partition" {
  description = "AWS partition the module planned in (aws, aws-us-gov, aws-cn)"
  value       = local.partition
}

output "bucket_arn" {
  description = "Bucket ARN built from the active partition"
  value       = local.bucket_arn
}

output "reader_role_arn" {
  description = "ARN of the read-only role"
  value       = aws_iam_role.reader.arn
}

output "s3_endpoint_host" {
  description = "S3 hostname built from region, partition DNS suffix and the FIPS flag. Built by rule, not tested against a live endpoint."
  value       = local.s3_host
}
