# nginx-public-service

Internet-facing NGINX web service: ALB in public subnets, Auto Scaling group
of NGINX instances in private subnets with no public IP and no SSH ingress.

```
Internet
  -> ALB (public subnets, SG: 80/443 from 0.0.0.0/0)
       -> Target Group (HTTP:80)
            -> NGINX ASG (private subnets, SG: 80 from ALB SG only)
```

## Why ALB over NLB here

This is an HTTP web service, not a raw TCP/long-lived-connection workload, so
Layer 7 routing, HTTP health checks, and TLS termination at the load balancer
are the right fit. The `device-connectivity` environment makes the opposite
call (NLB), because it carries long-lived device connections.

## Security decisions

- **`0.0.0.0/0` on the ALB security group is intentional** and documented in
  the resource description -- it's the public entry point by design. Nothing
  else in this module allows `0.0.0.0/0` ingress.
- App instances accept traffic **only from the ALB security group**
  (security-group-to-security-group reference, not a CIDR).
- Instances have **no SSH ingress at all** and no key pair. Administrative
  access is via Session Manager, using the same IAM pattern as
  `private-compute-access` (`AmazonSSMManagedInstanceCore` on the instance
  role).
- IMDSv2 is enforced (`http_tokens = "required"`), EBS is encrypted, hop
  limit is 1 (no container on this instance should be able to reach the
  metadata service through a proxy).

## HTTP-only demo mode

If `certificate_arn` is left empty, the module deploys with only an HTTP
listener -- no redirect, no TLS. This is fine for proving the pattern works
end-to-end without owning a domain, but it is explicitly **not** a mode to
put real traffic through. Supply an ACM certificate ARN to get the HTTPS
listener, HTTP->HTTPS redirect, and TLS 1.2+ policy.

## Cost notes

- ALB: ~$0.0225/hr + LCU charges (2025 us-east-1 pricing; check current AWS
  pricing for your region) -- this runs whenever the environment is up.
- ASG: billed per running EC2 instance; `desired_capacity = 1` is the
  cost-conscious default, `2` across 2 AZs demonstrates HA.
- No NAT Gateway from this module directly, but `dnf install nginx` in
  user_data needs outbound reachability to the Amazon Linux package repos --
  see the note at the top of `main.tf`.

## Known, accepted trivy finding

Same as the `network` module: `map_public_ip_on_launch` isn't set here, but
`trivy` will flag the ALB's `0.0.0.0/0` ingress rules (public HTTP/HTTPS
listener rules) as high-severity. That's the intended, documented design for
a public-facing load balancer -- see "Security decisions" above.
