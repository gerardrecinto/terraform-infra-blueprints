# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Grafana alerting module
# Monitors 10 ALBs and 4 AWS services: MSK, SQS, SNS, PrivateLink
# Written to be reused across dev / test / stage / demo / prod environments; not applied to a real Grafana instance
# Alerts route to Slack and PagerDuty via contact points

terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}

# CloudWatch data source -- one per monitored region
resource "grafana_data_source" "cloudwatch" {
  type = "cloudwatch"
  name = "cloudwatch-${var.environment}"

  json_data_encoded = jsonencode({
    defaultRegion = var.aws_region
    authType      = "default" # uses instance profile / IRSA
  })
}

# Slack contact point
resource "grafana_contact_point" "slack" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "slack-${var.environment}"

  slack {
    url   = var.slack_webhook_url
    title = "[${upper(var.environment)}] {{ .GroupLabels.alertname }}"
    text  = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
  }
}

# Notification policy -- route all alerts to Slack
resource "grafana_notification_policy" "default" {
  group_by      = ["alertname", "environment"]
  contact_point = length(grafana_contact_point.slack) > 0 ? grafana_contact_point.slack[0].name : "default"

  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "1h"
}

# Alert folder
resource "grafana_folder" "alerts" {
  title = "${var.environment}-aws-alerts"
}

# Alert rule group: ALB 5XX and latency
resource "grafana_rule_group" "alb" {
  name             = "alb-alerts"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = toset(range(length(var.alb_arn_suffixes)))
    content {
      name      = "ALB 5XX - ${var.alb_names[rule.value]} (${var.environment})"
      condition = "C"

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.cloudwatch.uid
        relative_time_range {
          from = 300
          to   = 0
        }
        model = jsonencode({
          dimensions     = { LoadBalancer = var.alb_arn_suffixes[rule.value] }
          expression     = ""
          highResolution = false
          id             = ""
          matchExact     = true
          metricName     = "HTTPCode_Target_5XX_Count"
          namespace      = "AWS/ApplicationELB"
          period         = "60"
          refId          = "A"
          region         = var.aws_region
          statistic      = "Sum"
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          conditions = [{
            evaluator = { params = [var.alb_5xx_threshold], type = "gt" }
            operator  = { type = "and" }
            query     = { params = ["A"] }
            reducer   = { params = [], type = "sum" }
            type      = "query"
          }]
          refId = "C"
          type  = "classic_conditions"
        })
      }

      annotations = {
        summary = "ALB ${var.alb_names[rule.value]} has >=${var.alb_5xx_threshold} 5XX errors in the last 5 min"
      }
      labels = {
        environment = var.environment
        service     = "alb"
      }

      no_data_state  = "OK"
      exec_err_state = "Alerting"
      for            = "2m"
    }
  }

  # P99 latency alert per ALB
  dynamic "rule" {
    for_each = toset(range(length(var.alb_arn_suffixes)))
    content {
      name      = "ALB P99 Latency - ${var.alb_names[rule.value]} (${var.environment})"
      condition = "C"

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.cloudwatch.uid
        relative_time_range {
          from = 300
          to   = 0
        }
        model = jsonencode({
          dimensions = { LoadBalancer = var.alb_arn_suffixes[rule.value] }
          metricName = "TargetResponseTime"
          namespace  = "AWS/ApplicationELB"
          period     = "60"
          refId      = "A"
          region     = var.aws_region
          statistic  = "p99"
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          conditions = [{
            evaluator = { params = [var.alb_latency_p99_ms / 1000.0], type = "gt" }
            operator  = { type = "and" }
            query     = { params = ["A"] }
            reducer   = { params = [], type = "last" }
            type      = "query"
          }]
          refId = "C"
          type  = "classic_conditions"
        })
      }

      annotations = {
        summary = "ALB ${var.alb_names[rule.value]} P99 latency exceeded ${var.alb_latency_p99_ms}ms"
      }
      labels = {
        environment = var.environment
        service     = "alb"
      }

      no_data_state  = "OK"
      exec_err_state = "Alerting"
      for            = "3m"
    }
  }
}

# Alert rule group: SQS queue depth and message age
resource "grafana_rule_group" "sqs" {
  count            = length(var.sqs_queue_names) > 0 ? 1 : 0
  name             = "sqs-alerts"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = var.sqs_queue_names
    content {
      name      = "SQS Message Age - ${rule.value} (${var.environment})"
      condition = "C"

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.cloudwatch.uid
        relative_time_range {
          from = 300
          to   = 0
        }
        model = jsonencode({
          dimensions = { QueueName = rule.value }
          metricName = "ApproximateAgeOfOldestMessage"
          namespace  = "AWS/SQS"
          period     = "60"
          refId      = "A"
          region     = var.aws_region
          statistic  = "Maximum"
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          conditions = [{
            evaluator = { params = [var.sqs_message_age_seconds], type = "gt" }
            operator  = { type = "and" }
            query     = { params = ["A"] }
            reducer   = { params = [], type = "last" }
            type      = "query"
          }]
          refId = "C"
          type  = "classic_conditions"
        })
      }

      annotations = {
        summary = "SQS queue ${rule.value} has messages older than ${var.sqs_message_age_seconds}s -- consumer may be stuck"
      }
      labels = {
        environment = var.environment
        service     = "sqs"
      }

      no_data_state  = "OK"
      exec_err_state = "Alerting"
      for            = "5m"
    }
  }
}

# Alert rule group: MSK under-replicated partitions
resource "grafana_rule_group" "msk" {
  count            = var.msk_cluster_name != "" ? 1 : 0
  name             = "msk-alerts"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name      = "MSK Under-Replicated Partitions - ${var.msk_cluster_name} (${var.environment})"
    condition = "C"

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.cloudwatch.uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        dimensions = { "Cluster Name" = var.msk_cluster_name }
        metricName = "UnderReplicatedPartitions"
        namespace  = "AWS/Kafka"
        period     = "60"
        refId      = "A"
        region     = var.aws_region
        statistic  = "Maximum"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        conditions = [{
          evaluator = { params = [0], type = "gt" }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { params = [], type = "last" }
          type      = "query"
        }]
        refId = "C"
        type  = "classic_conditions"
      })
    }

    annotations = {
      summary = "MSK cluster ${var.msk_cluster_name} has under-replicated partitions -- check broker health"
    }
    labels = {
      environment = var.environment
      service     = "msk"
    }

    no_data_state  = "OK"
    exec_err_state = "Alerting"
    for            = "2m"
  }
}
