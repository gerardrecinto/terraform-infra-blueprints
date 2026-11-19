variable "project_id" {
  description = "GCP project that owns the zone"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "zone_name" {
  description = "Resource name of the managed zone (lowercase letters, digits and dashes)"
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.zone_name))
    error_message = "zone_name must start with a letter and use only lowercase letters, digits and dashes."
  }
}

variable "dns_name" {
  description = "DNS name of the zone with a trailing dot, for example internal.example.com."
  type        = string

  validation {
    condition     = can(regex("^([a-zA-Z0-9-]+\\.)+$", var.dns_name))
    error_message = "dns_name must be a fully qualified name that ends with a dot."
  }
}

variable "visibility" {
  description = "private resolves only inside the listed VPC networks; public is served on the internet"
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "public"], var.visibility)
    error_message = "visibility must be private or public."
  }
}

variable "private_networks" {
  description = "Self links of the VPC networks that may resolve a private zone"
  type        = list(string)
  default     = []

  validation {
    condition     = var.visibility == "public" || length(var.private_networks) > 0
    error_message = "A private zone needs at least one network in private_networks."
  }
}

variable "dnssec_enabled" {
  description = "Sign a public zone with DNSSEC; ignored for private zones, which Cloud DNS cannot sign"
  type        = bool
  default     = true
}

variable "records" {
  description = "Record sets keyed by a short label. name is relative to the zone (use @ for the apex), rrdatas are the values"
  type = map(object({
    name    = string
    type    = string
    ttl     = optional(number, 300)
    rrdatas = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.records) : contains(["A", "AAAA", "CNAME", "TXT", "MX", "SRV", "CAA", "NS"], r.type)])
    error_message = "Record type must be one of A, AAAA, CNAME, TXT, MX, SRV, CAA, NS."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : r.ttl >= 30 && r.ttl <= 86400])
    error_message = "Record ttl must be between 30 and 86400 seconds."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : length(r.rrdatas) > 0])
    error_message = "Every record needs at least one value in rrdatas."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : r.type != "CNAME" || length(r.rrdatas) == 1])
    error_message = "A CNAME record set takes exactly one value."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : !(r.name == "@" && r.type == "CNAME")])
    error_message = "A CNAME cannot sit at the zone apex."
  }
}

variable "labels" {
  description = "Labels applied to the zone"
  type        = map(string)
  default     = {}
}
