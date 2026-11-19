output "record_ids" {
  description = "Cloudflare record IDs keyed like the records input"
  value       = { for k, r in cloudflare_dns_record.this : k => r.id }
}
