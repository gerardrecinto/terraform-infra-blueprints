# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# SQS + SNS module with DLQ
# Reusable across multiple platforms/services: API event pipelines, device fleets, IoT telemetry

locals {
  queue_name = var.fifo ? "${var.name}-${var.environment}.fifo" : "${var.name}-${var.environment}"
  dlq_name   = var.fifo ? "${var.name}-${var.environment}-dlq.fifo" : "${var.name}-${var.environment}-dlq"
}

# Dead letter queue
resource "aws_sqs_queue" "dlq" {
  name                      = local.dlq_name
  fifo_queue                = var.fifo
  message_retention_seconds = 1209600 # 14 days for DLQ -- long enough to investigate
  kms_master_key_id         = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = merge(var.tags, {
    Environment = var.environment
    Type        = "dlq"
  })
}

# Main queue
resource "aws_sqs_queue" "this" {
  name                       = local.queue_name
  fifo_queue                 = var.fifo
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  kms_master_key_id          = var.kms_key_arn != "" ? var.kms_key_arn : null

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, {
    Environment = var.environment
    Type        = "main"
  })
}

# Queue policy -- allow SNS and specified AWS services to send
resource "aws_sqs_queue_policy" "this" {
  queue_url = aws_sqs_queue.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.create_sns_topic && var.subscribe_sqs_to_sns ? [{
        Sid       = "AllowSNSPublish"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.this.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_sns_topic.this[0].arn }
        }
      }] : [],
      length(var.allowed_aws_services) > 0 ? [{
        Sid       = "AllowAWSServices"
        Effect    = "Allow"
        Principal = { Service = var.allowed_aws_services }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.this.arn
      }] : []
    )
  })
}

# SNS topic
resource "aws_sns_topic" "this" {
  count = var.create_sns_topic ? 1 : 0
  name  = var.fifo ? "${var.name}-${var.environment}.fifo" : "${var.name}-${var.environment}"

  fifo_topic                  = var.fifo
  kms_master_key_id           = var.kms_key_arn != "" ? var.kms_key_arn : null
  content_based_deduplication = var.fifo ? true : false

  tags = merge(var.tags, {
    Environment = var.environment
  })
}

# Subscribe SQS to SNS
resource "aws_sns_topic_subscription" "sqs" {
  count = var.create_sns_topic && var.subscribe_sqs_to_sns ? 1 : 0

  topic_arn = aws_sns_topic.this[0].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.this.arn

  # Raw delivery skips the SNS envelope -- usually what you want for SQS consumers
  raw_message_delivery = true
}

# Additional subscribers (Lambda, HTTPS endpoints, etc.)
resource "aws_sns_topic_subscription" "extra" {
  for_each = var.create_sns_topic ? var.sns_subscriptions : {}

  topic_arn = aws_sns_topic.this[0].arn
  protocol  = each.value.protocol
  endpoint  = each.value.endpoint
}
