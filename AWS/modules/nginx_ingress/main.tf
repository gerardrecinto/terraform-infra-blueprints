# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
#
# NGINX Ingress module -- SSH/ADB-style device gateway and streaming target
#
# Architecture:
#   PrivateLink IP (consumer VPC)
#     --> NLB (provider VPC, internal, target_type = ip)
#       --> NGINX on EKS (Helm release, fully Terraform-managed)
#         port 22  --> SSH/ADB gateway pods  (L4 TCP passthrough, no TLS termination)
#         port 443 --> device streaming pods (TLS passthrough)
#
# Why two separate NLB target groups instead of one:
#   - Scopes which pod IPs are exposed per gateway type (SSH vs streaming)
#   - Prevents cross-protocol leakage through the NLB listener
#   - Separate health checks per protocol (TCP:22 vs TCP:443)
#   - Independently scalable -- streaming pods can scale without touching SSH targets
#
# The hard part: pod IPs are ephemeral. Static target group entries break silently
# when pods reschedule -- old IPs stay registered, new IPs never get added.
# Solution: data sources query the live Kubernetes API for current pod IPs and
# for_each registers each pod as an NLB target with target_type = "ip" (direct
# pod routing, no NodePort NAT). terraform apply keeps targets in sync.
#
# ConfigMap-driven port mapping (tcp_services) keeps routing changes as config PRs,
# not helm upgrade commands. Full audit trail, peer-reviewed, rollback via revert.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  nlb_annotations = merge({
    "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = var.nlb_internal ? "internal" : "internet-facing"
    "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = tostring(var.nlb_cross_zone_enabled)
    "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                  = "tcp"
    # Preserve client IP end-to-end so SSH sessions see the actual source address.
    # Without this, all traffic appears to come from the NLB node IP.
    "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "preserve_client_ip.enabled=true"
  }, var.extra_annotations)
}

# ─── NGINX Helm Release ───────────────────────────────────────────────────────
# Tracked in Terraform so the chart version, replica count, and all runtime config
# are version-controlled and auditable. No ad-hoc helm upgrade commands in prod.
# Helm state is stored in the cluster (Kubernetes secret) and Terraform state tracks
# the release resource -- two complementary layers of state, not conflicting.

resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.10.1"
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode({
    controller = {
      replicaCount = var.replicas

      # Reference the TCP services ConfigMap that maps NLB ports to internal services.
      # This is what opens TCP stream listeners on port 22 and 443 inside NGINX --
      # distinct from the standard HTTP/HTTPS listeners on 80/443.
      tcp = {
        configMapNamespace = var.namespace
        configMapName      = "tcp-services"
      }

      service = {
        type        = "LoadBalancer"
        annotations = local.nlb_annotations

        # externalTrafficPolicy = Local: preserves the original client source IP
        # so SSH sessions and ADB connections see the real client address.
        # Cluster mode would SNAT to the node IP, breaking source-IP-based access control.
        externalTrafficPolicy = "Local"

        ports = {
          http    = 80
          https   = 443
          ssh-adb = 22
        }
      }

      config = {
        # Long timeouts for persistent SSH sessions and video streams.
        # Default 60s would terminate long-idle SSH connections mid-session.
        "proxy-read-timeout"    = "3600"
        "proxy-send-timeout"    = "3600"
        "proxy-connect-timeout" = "60"
        "proxy-body-size"       = "100m"
        # Required for WebSocket upgrade on device streaming connections
        "use-forwarded-headers" = "true"
        # Security headers applied to all HTTP responses (not TCP stream)
        "add-headers" = "${var.namespace}/custom-headers"
      }

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }

      # Hard pod anti-affinity: spread controller pods across nodes.
      # A single node failure must not take down all SSH and streaming sessions.
      # requiredDuringScheduling = hard constraint (not preferred) -- if only one
      # node is available, it's better to fail scheduling than to co-locate.
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = {
              matchExpressions = [{
                key      = "app.kubernetes.io/component"
                operator = "In"
                values   = ["controller"]
              }]
            }
            topologyKey = "kubernetes.io/hostname"
          }]
        }
      }

      metrics = {
        enabled        = true
        serviceMonitor = { enabled = true }
      }
    }
  })]
}

# ─── TCP Services ConfigMap ───────────────────────────────────────────────────
# Tells NGINX which internal Kubernetes services to TCP-proxy for each external port.
# Format: "external_port" = "namespace/service-name:internal_port"
#
# Port 22  --> SSH/ADB gateway service (L4 TCP; no TLS, NGINX passes bytes through)
# Port 443 --> device streaming service (TLS passthrough; NGINX does not terminate)
#
# This ConfigMap is the authoritative routing table for non-HTTP traffic.
# Changing a target service is a one-line config PR, not a Helm upgrade.
# NGINX controller watches this ConfigMap and hot-reloads stream blocks -- no downtime.

resource "kubernetes_config_map" "tcp_services" {
  metadata {
    name      = "tcp-services"
    namespace = var.namespace
    annotations = {
      "nginx.ingress.kubernetes.io/tcp-services-configmap" = "${var.namespace}/tcp-services"
    }
  }

  data = {
    "22"  = "${var.ssh_gateway_namespace}/${var.ssh_gateway_service}:22"
    "443" = "${var.device_streaming_namespace}/${var.device_streaming_service}:443"
  }

  depends_on = [helm_release.nginx_ingress]
}

# ─── Security Headers ConfigMap ───────────────────────────────────────────────
# Applied to HTTP responses only (not TCP streams).
# Managed in Terraform so AppSec policy changes go through PR review,
# not direct kubectl edits that leave no audit trail.

resource "kubernetes_config_map" "security_headers" {
  metadata {
    name      = "custom-headers"
    namespace = var.namespace
  }

  data = {
    "X-Frame-Options"           = "SAMEORIGIN"
    "X-Content-Type-Options"    = "nosniff"
    "X-XSS-Protection"          = "1; mode=block"
    "Referrer-Policy"           = "strict-origin-when-cross-origin"
    "Content-Security-Policy"   = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
    "Strict-Transport-Security" = "max-age=31536000; includeSubDomains"
  }

  depends_on = [helm_release.nginx_ingress]
}

# ─── Dynamic NLB Target Registration ─────────────────────────────────────────
# Context: NLB target_type = "ip" registers individual pod IPs directly as targets.
# This bypasses kube-proxy / NodePort NAT -- lower latency, true source IP preserved.
#
# Problem: pod IPs change on every rollout, reschedule, or node drain.
# A static target group would silently route to stale IPs -- connections time out
# with no obvious error, and the NLB health check may not catch it fast enough.
#
# Solution:
#   1. data sources query the live Kubernetes API for current pods by label selector
#   2. for_each over pod list builds one aws_lb_target_group_attachment per live pod IP
#   3. terraform apply re-evaluates data sources and converges targets to current state
#   4. Pods with no IP (Pending/Terminating) are filtered out before registration
#
# Two separate target groups -- one per gateway type -- enforce least-privilege:
# SSH/ADB pods are not reachable on port 443, streaming pods are not reachable on port 22.

# Live pod query -- SSH/ADB gateway pods
data "kubernetes_pod_v1" "ssh_adb_pods" {
  count = var.dynamic_pod_targeting ? 1 : 0

  metadata {
    namespace = var.ssh_gateway_namespace
    labels    = var.ssh_gateway_pod_labels
  }
}

# Live pod query -- device streaming pods
data "kubernetes_pod_v1" "device_streaming_pods" {
  count = var.dynamic_pod_targeting ? 1 : 0

  metadata {
    namespace = var.device_streaming_namespace
    labels    = var.device_streaming_pod_labels
  }
}

# NLB Target Group -- SSH/ADB gateway
# target_type = "ip" is required to register pod IPs directly.
# "instance" type only supports NodePort, which adds a NAT hop and breaks source IP.
resource "aws_lb_target_group" "ssh_adb" {
  count = var.dynamic_pod_targeting ? 1 : 0

  name        = "${var.cluster_name}-ssh-adb-${var.environment}"
  port        = 22
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = "22"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name        = "${var.cluster_name}-ssh-adb-tg"
    Environment = var.environment
    GatewayType = "ssh-adb"
  }
}

# NLB Target Group -- device streaming (port 443, TCP passthrough)
resource "aws_lb_target_group" "device_streaming" {
  count = var.dynamic_pod_targeting ? 1 : 0

  name        = "${var.cluster_name}-streaming-${var.environment}"
  port        = 443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = "443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name        = "${var.cluster_name}-streaming-tg"
    Environment = var.environment
    GatewayType = "device-streaming"
  }
}

# Dynamic attachment -- SSH/ADB pods
# for_each key = pod name (stable across the loop, unique per pod)
# target_id    = pod IP (what the NLB will actually route to)
# availability_zone = "all" is required for cross-AZ IP-type targets --
# without it, the NLB only routes to targets in its own AZ.
resource "aws_lb_target_group_attachment" "ssh_adb_pods" {
  for_each = var.dynamic_pod_targeting ? {
    for pod in try(data.kubernetes_pod_v1.ssh_adb_pods[0].metadata, []) :
    pod.name => pod
    if try(pod.status[0].pod_ip, "") != "" # exclude Pending/Terminating pods
  } : {}

  target_group_arn  = aws_lb_target_group.ssh_adb[0].arn
  target_id         = each.value.status[0].pod_ip
  port              = 22
  availability_zone = "all"
}

# Dynamic attachment -- device streaming pods
resource "aws_lb_target_group_attachment" "device_streaming_pods" {
  for_each = var.dynamic_pod_targeting ? {
    for pod in try(data.kubernetes_pod_v1.device_streaming_pods[0].metadata, []) :
    pod.name => pod
    if try(pod.status[0].pod_ip, "") != ""
  } : {}

  target_group_arn  = aws_lb_target_group.device_streaming[0].arn
  target_id         = each.value.status[0].pod_ip
  port              = 443
  availability_zone = "all"
}
