output "zone_name" {
  description = "Name of the managed zone"
  value       = google_dns_managed_zone.this.name
}

output "name_servers" {
  description = "Name servers to delegate to (public zones)"
  value       = google_dns_managed_zone.this.name_servers
}

output "record_fqdns" {
  description = "Fully qualified names of the record sets, keyed like the records input"
  value       = { for k, r in google_dns_record_set.this : k => r.name }
}
