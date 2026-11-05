output "domain" {
  description = "GTM domain name; point the public hostname at it with a CNAME"
  value       = akamai_gtm_domain.this.name
}

output "property_hostname" {
  description = "Fully qualified name Akamai answers for the load balanced property"
  value       = "${akamai_gtm_property.this.name}.${akamai_gtm_domain.this.name}"
}

output "site_datacenter_ids" {
  description = "Akamai datacenter ID for every site key, used when referencing a site from other GTM resources"
  value       = { for k, v in akamai_gtm_datacenter.site : k => v.datacenter_id }
}
