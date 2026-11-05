variable "domain_name" {
  description = "Akamai GTM domain, which must end in .akadns.net (for example shop.example.akadns.net); customers reach it through a CNAME from their own hostname"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\\.akadns\\.net$", var.domain_name))
    error_message = "domain_name must be a lowercase DNS name ending in .akadns.net."
  }
}

variable "property_name" {
  description = "Name of the GTM property (the hostname label that is load balanced, for example www)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.property_name))
    error_message = "property_name must be a lowercase DNS label."
  }
}

variable "domain_type" {
  description = "GTM domain type. weighted supports weighted and failover properties; failover-only restricts the domain to failover properties"
  type        = string
  default     = "weighted"

  validation {
    condition     = contains(["weighted", "failover-only", "basic", "full"], var.domain_type)
    error_message = "domain_type must be one of weighted, failover-only, basic or full."
  }
}

variable "contract_id" {
  description = "Akamai contract ID that owns the domain (for example ctr_C-0N7RAC7); left empty to use the provider default"
  type        = string
  default     = null
}

variable "group_id" {
  description = "Akamai group ID that owns the domain (for example grp_12345); left empty to use the provider default"
  type        = string
  default     = null
}

variable "notification_emails" {
  description = "Email addresses that receive GTM liveness and failover notifications; at least one so a site failure is never silent"
  type        = list(string)

  validation {
    condition     = length(var.notification_emails) > 0
    error_message = "Provide at least one notification email."
  }
}

variable "mode" {
  description = "failover sends all traffic to the lowest precedence live site and moves to the next one when its liveness test fails; weighted spreads traffic by weight and removes a failed site from the answers"
  type        = string
  default     = "failover"

  validation {
    condition     = contains(["failover", "weighted"], var.mode)
    error_message = "mode must be failover or weighted."
  }
}

variable "sites" {
  description = "Sites (data centers or cloud regions) that can serve the property, keyed by a short name such as dc-east or aws-west. servers are the IPv4 addresses answered for the site. precedence (0 is first) is used in failover mode. weight (0 to 100) is used in weighted mode: set a site to 0 to drain it before a pull-the-plug"
  type = map(object({
    nickname   = string
    city       = string
    country    = string
    latitude   = number
    longitude  = number
    servers    = list(string)
    precedence = optional(number, 0)
    weight     = optional(number, 50)
    enabled    = optional(bool, true)
  }))

  validation {
    condition     = length(var.sites) >= 2
    error_message = "Define at least two sites, otherwise there is nothing to fail over to."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : length(s.servers) > 0])
    error_message = "Every site needs at least one server address."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : s.weight >= 0 && s.weight <= 100])
    error_message = "Site weights must be between 0 and 100."
  }
}

variable "health_check" {
  description = "Liveness test run by Akamai against every site. interval and timeout are in seconds; a failing site is removed from answers after failover_delay seconds and returned after failback_delay seconds"
  type = object({
    protocol       = optional(string, "HTTPS")
    port           = optional(number, 443)
    path           = optional(string, "/healthz")
    interval       = optional(number, 30)
    timeout        = optional(number, 10)
    failover_delay = optional(number, 0)
    failback_delay = optional(number, 300)
  })
  default = {}

  validation {
    condition     = contains(["HTTP", "HTTPS", "TCP"], var.health_check.protocol)
    error_message = "health_check.protocol must be HTTP, HTTPS or TCP."
  }

  validation {
    condition     = var.health_check.timeout < var.health_check.interval
    error_message = "health_check.timeout must be shorter than health_check.interval."
  }
}
