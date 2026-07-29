output "id" {
  description = "Resource ID of the Event Grid Namespace. Used by the central assignment layer."
  value       = azurerm_eventgrid_namespace.this.id
}

output "name" {
  description = "Composed Event Grid Namespace name."
  value       = local.name
}

output "topic_ids" {
  description = "Resource IDs of the namespace topics, keyed by topic name."
  value       = { for k, t in azurerm_eventgrid_namespace_topic.this : k => t.id }
}

output "identity_principal_id" {
  description = "Principal ID of the namespace's system-assigned identity, or null when managed_identity is disabled. Feed this to the central assignment layer."
  value       = try(azurerm_eventgrid_namespace.this.identity[0].principal_id, null)
}

output "private_endpoint_dns" {
  description = "FQDN + private IP pairs for external Private DNS registration, across all endpoints."
  value       = flatten([for pe in azurerm_private_endpoint.this : pe.custom_dns_configs])
}
