output "gateway_url" {
  description = "Public URL of the ESPv2 gateway."
  value       = google_cloud_run_v2_service.gateway.uri
}

output "backend_url" {
  description = "Private URL of the FastAPI backend (403 without an ID token)."
  value       = google_cloud_run_v2_service.backend.uri
}

output "endpoints_service" {
  value = google_endpoints_service.orders.service_name
}

output "api_key" {
  description = "Read it with: terraform output -raw api_key"
  value       = google_apikeys_key.client.key_string
  sensitive   = true
}
