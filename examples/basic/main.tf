# Minimal Bronze call: a private, pull-delivery Event Grid Namespace with two
# topics. MQTT stays off, so the module creates a single private endpoint on the
# "topic" sub-resource.

variable "subnet_id" {
  description = "Existing app-owned subnet for the private endpoint."
  type        = string
}

module "eventgrid_namespace" {
  source = "../../"

  application_code           = "myapp"
  environment                = "dev"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-dev-001"

  company = "contoso"
  owner   = "platform-team"

  capacity = 1

  topics = {
    "orders"    = { event_retention_in_days = 7 }
    "inventory" = {}
  }

  networking = {
    subnet_id = var.subnet_id
  }

  lock = {
    enabled = true
    level   = "CanNotDelete"
  }

  # source_repo is set by the pipeline via TF_VAR_source_repo.
  source_repo = "example"
}

# Feed this into your Private DNS registration — the module never creates a
# private_dns_zone_group. Namespace endpoints resolve in privatelink.eventgrid.azure.net
# ("topic") and privatelink.ts.eventgrid.azure.net ("topicspace").
output "private_endpoint_dns" {
  description = "FQDN + private IP pairs for external Private DNS registration."
  value       = module.eventgrid_namespace.private_endpoint_dns
}
