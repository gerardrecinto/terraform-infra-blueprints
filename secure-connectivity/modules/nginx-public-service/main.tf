# NGINX public web service: internet-facing ALB -> private-subnet Auto Scaling
# group. Instances have no public IP and no SSH ingress; administrative access
# is via Session Manager (see the private-compute-access module for the IAM
# pattern this reuses).
#
# Package installation in user_data (dnf install nginx) requires that the
# private subnets can reach the Amazon Linux package repos, which are backed
# by S3. Either enable_nat_gateway on the network module, or add an S3
# gateway endpoint to the VPC -- this module does not create that endpoint
# itself so it stays decoupled from the network module's implementation.
# See README.md for the tradeoff.

locals {
  tags = merge(var.tags, {
    Module    = "nginx-public-service"
    ManagedBy = "terraform"
  })

  https_enabled = length(var.certificate_arn) > 0
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

check "access_logs_bucket_required" {
  assert {
    condition     = !var.enable_access_logs || length(var.access_logs_bucket) > 0
    error_message = "access_logs_bucket must be set when enable_access_logs is true."
  }
}

# --- Security groups --------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB ingress from the internet on 80/443"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP listener -- intentional, this is the public entry point"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = local.https_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Public HTTPS listener -- intentional, this is the public entry point"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to app instances only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "NGINX instances -- ingress only from the ALB security group"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB only, never from the internet directly"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS egress for SSM, package repos, CloudWatch"
  # SSM/package-repo/CloudWatch endpoints have no fixed IPs; scoped to port
  # 443 only, no ingress on this SG at all.
  # tfsec:ignore:aws-vpc-no-public-egress-sgr
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP egress for package repo mirrors"
  # package mirrors have no fixed IPs; scoped to port 80 only, no ingress on
  # this SG at all.
  # tfsec:ignore:aws-vpc-no-public-egress-sgr
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}

# --- IAM: SSM-only administrative access, no SSH key ------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json

  tags = local.tags
}

# AWS-managed policy tradeoff: AmazonSSMManagedInstanceCore grants the SSM
# Agent everything it needs (Session Manager, Run Command, inventory) but is
# broader than the exact 4-5 API calls actually used. A stricter
# customer-managed policy would enumerate ssm:UpdateInstanceInformation,
# ssmmessages:*, ec2messages:* explicitly -- worth doing before real
# production use, left as an AWS-managed policy here for portfolio clarity.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name

  tags = local.tags
}

# --- Launch template + Auto Scaling group -----------------------------------

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2 enforced
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf install -y nginx
    INSTANCE_ID=$(TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    echo "<html><body><h1>${var.name}</h1><p>Served by $INSTANCE_ID</p></body></html>" > /usr/share/nginx/html/index.html
    systemctl enable nginx
    systemctl start nginx
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.name}-instance" })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = "${var.name}-instance" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# --- ALB ---------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = var.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      enabled = true
    }
  }

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  name     = "${var.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # HTTP-only demo mode when no certificate is supplied. When https_enabled
  # is true, this listener redirects instead of serving traffic directly --
  # do not send confidential data over the HTTP-only path.
  dynamic "default_action" {
    for_each = local.https_enabled ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.https_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# --- Observability -----------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/nginx-public-service/${var.name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "One or more targets are failing ALB health checks."

  dimensions = {
    TargetGroup  = aws_lb_target_group.this.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  tags = local.tags
}
