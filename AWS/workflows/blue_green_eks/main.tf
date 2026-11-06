# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Blue-green migration: Elastic Beanstalk -> EKS
# This workflow models a zero-downtime cutover pattern:
#   1. EKS cluster and target group already running in parallel
#   2. ALB listener rule shifted from Beanstalk TG to EKS TG in one apply
#   3. Beanstalk env decommissioned after validation
#
# Traffic shift is controlled by target_group_weight -- start at 0,
# gradually increase while monitoring 5XX rates, then flip to 100.

locals {
  service_name = "app"
  environment  = var.environment
  region       = var.aws_region
}

provider "aws" {
  region = local.region
}

# Existing ALB -- shared between Beanstalk and EKS during migration
data "aws_lb" "shared" {
  name = "${local.service_name}-${local.environment}-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

# EKS target group -- created by TargetGroupBinding in K8s before this apply
data "aws_lb_target_group" "eks" {
  name = "${local.service_name}-${local.environment}-eks"
}

# Beanstalk target group -- existing, traffic drains from here
data "aws_lb_target_group" "beanstalk" {
  name = "${local.service_name}-${local.environment}-eb"
}

# The key resource: weighted forward rule
# Setting eks weight to 100 and beanstalk to 0 is the cutover moment
resource "aws_lb_listener_rule" "weighted" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = data.aws_lb_target_group.eks.arn
        weight = var.eks_traffic_weight # 0 -> 10 -> 50 -> 100 during migration
      }
      target_group {
        arn    = data.aws_lb_target_group.beanstalk.arn
        weight = 100 - var.eks_traffic_weight
      }

      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

# TargetGroupBinding -- links the K8s Service to the AWS Target Group
# Applied to the EKS cluster before shifting traffic
resource "kubernetes_manifest" "tgb" {
  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = "${local.service_name}-tgb"
      namespace = var.k8s_namespace
    }
    spec = {
      serviceRef = {
        name = local.service_name
        port = 8080
      }
      targetGroupARN = data.aws_lb_target_group.eks.arn
      targetType     = "ip"
      vpcID          = var.vpc_id
    }
  }
}

# CloudWatch alarm -- watched during migration; if 5XX spikes, revert eks weight to 0
resource "aws_cloudwatch_metric_alarm" "migration_5xx" {
  alarm_name          = "${local.service_name}-${local.environment}-migration-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "5XX spike during blue-green migration -- consider reverting eks_traffic_weight to 0"

  dimensions = {
    LoadBalancer = data.aws_lb.shared.arn_suffix
  }

  alarm_actions = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []
}
