# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# PrivateLink module -- cross-account endpoint service backed by NLB
# Example use case: SSH gateway (NGINX TCP/SSH ingress on port 22) across account boundaries
# Also applicable to MSK, SQS, and other internal service connectivity

# Endpoint service (provider side) -- expose NLB to other accounts
resource "aws_vpc_endpoint_service" "this" {
  acceptance_required        = false
  network_load_balancer_arns = [var.nlb_arn]
  allowed_principals         = var.allowed_principals

  tags = merge(var.tags, {
    Name        = "${var.service_name}-endpoint-service"
    Environment = var.environment
  })
}

# VPC endpoint (consumer side) -- connect to the service from another account/VPC
resource "aws_vpc_endpoint" "this" {
  count = var.consumer_vpc_id != "" ? 1 : 0

  vpc_id              = var.consumer_vpc_id
  service_name        = aws_vpc_endpoint_service.this.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = false # manage DNS via Route53 alias records

  tags = merge(var.tags, {
    Name        = "${var.service_name}-endpoint"
    Environment = var.environment
  })
}

# Security group allowing inbound on the specified TCP ports
resource "aws_security_group" "endpoint" {
  name        = "${var.service_name}-endpoint-sg"
  description = "PrivateLink endpoint SG for ${var.service_name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.tcp_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/8"]
      description = "PrivateLink TCP ${ingress.value}"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.service_name}-endpoint-sg"
  })
}

# Route53 alias record pointing to endpoint DNS for clean internal hostname
resource "aws_route53_record" "endpoint" {
  count = var.consumer_vpc_id != "" ? 1 : 0

  zone_id = data.aws_route53_zone.internal.zone_id
  name    = "${var.service_name}.internal"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.this[0].dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.this[0].dns_entry[0].hosted_zone_id
    evaluate_target_health = true
  }
}

data "aws_route53_zone" "internal" {
  name         = "internal."
  private_zone = true
  vpc_id       = var.vpc_id
}
