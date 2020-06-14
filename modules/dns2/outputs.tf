output "static_ip" {
  description = "Static IP created and associated with host record"
  value       = google_compute_address.static.address
}

output "fqdn" {
  description = "Fully qualified hostname with domain name"
  value       = trimsuffix(google_dns_record_set.hostname.name,".")
}
