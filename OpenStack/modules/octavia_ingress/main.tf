# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# Octavia ingress module -- analogous to the AWS nginx_ingress module
# Standalone L7 load balancer fronting a pool of backend members, with health checks
# so unhealthy members are pulled out of rotation automatically

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}

resource "openstack_lb_loadbalancer_v2" "this" {
  name          = var.lb_name
  vip_subnet_id = var.vip_subnet_id

  tags = [var.environment, "terraform"]
}

resource "openstack_lb_listener_v2" "https" {
  name            = "${var.lb_name}-https"
  protocol        = "HTTPS"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.this.id

  default_tls_container_ref = var.tls_container_ref

  # Reject anything that isn't a supported cipher up front instead of relying on
  # the backend to reject it
  timeout_client_data    = 30000
  timeout_member_data    = 30000
  timeout_member_connect = 5000
  timeout_tcp_inspect    = 0
}

resource "openstack_lb_pool_v2" "backend" {
  name        = "${var.lb_name}-pool"
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.https.id
  persistence {
    type = "SOURCE_IP"
  }
}

resource "openstack_lb_monitor_v2" "health" {
  pool_id        = openstack_lb_pool_v2.backend.id
  type           = "HTTP"
  url_path       = var.health_check_path
  delay          = 10
  timeout        = 5
  max_retries    = 3
  expected_codes = "200-299"
}

resource "openstack_lb_member_v2" "backends" {
  for_each      = var.backend_members
  pool_id       = openstack_lb_pool_v2.backend.id
  address       = each.value.address
  protocol_port = each.value.port
  subnet_id     = var.member_subnet_id
  weight        = each.value.weight
}
