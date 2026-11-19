variable "zone_id" {
  description = "Cloudflare zone ID that holds the records"
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{32}$", var.zone_id))
    error_message = "zone_id must be a 32 character hex Cloudflare zone ID."
  }
}

variable "records" {
  description = "DNS records keyed by a short label. name is the full record name (or @ for the apex). ttl 1 means automatic; proxied traffic must use ttl 1"
  type = map(object({
    name    = string
    type    = string
    content = string
    ttl     = optional(number, 300)
    proxied = optional(bool, false)
    comment = optional(string)
  }))

  validation {
    condition     = alltrue([for r in values(var.records) : contains(["A", "AAAA", "CNAME", "TXT", "MX", "CAA", "SRV"], r.type)])
    error_message = "Record type must be one of A, AAAA, CNAME, TXT, MX, CAA, SRV."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : r.ttl == 1 || (r.ttl >= 60 && r.ttl <= 86400)])
    error_message = "ttl must be 1 (automatic) or between 60 and 86400 seconds."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : !r.proxied || (r.ttl == 1 && contains(["A", "AAAA", "CNAME"], r.type))])
    error_message = "Only A, AAAA and CNAME records can be proxied, and a proxied record must use ttl 1."
  }

  validation {
    condition     = alltrue([for r in values(var.records) : r.type != "TXT" || length(r.content) <= 2048])
    error_message = "TXT content must be 2048 characters or fewer."
  }
}
