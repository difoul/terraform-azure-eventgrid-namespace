# An MQTT-enabled namespace, plus the sub-resources that make it usable.
#
# The module builds the namespace and its two private endpoints. Everything
# inside the namespace — topic spaces, client groups, clients, permission
# bindings — has no azurerm resource at all, so it is created with azapi against
# the same namespace. This is a provider gap, not a scope decision: azurerm ships
# only azurerm_eventgrid_namespace and azurerm_eventgrid_namespace_topic.
#
# All four types are ARM children of the namespace, so parent_id is the module's
# id output and Terraform derives the dependency from it — no depends_on needed.

variable "subnet_id" {
  description = "Existing app-owned subnet for the private endpoints."
  type        = string
}

variable "sensor_thumbprint" {
  description = "SHA-1 thumbprint of the client certificate presented by sensor-001."
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

  # Enabling MQTT is create-only: turning it on or off later replaces the
  # namespace and drops every session and undelivered event.
  mqtt = {
    enabled                                         = true
    maximum_client_sessions_per_authentication_name = 1
    maximum_session_expiry_in_hours                 = 8
  }

  # With mqtt.enabled the module creates endpoints on both "topic" and
  # "topicspace" — the latter is the one MQTT clients connect through.
  networking = {
    subnet_id = var.subnet_id
  }

  source_repo = "example"
}

locals {
  namespace_id = module.eventgrid_namespace.id
}

# ------------------------------------------------------------------------------
# Topic space — the set of MQTT topics clients are allowed to use
#
# The ${...} in a topic template is Event Grid's own placeholder syntax, not
# Terraform's, so it is escaped as $${...} to survive HCL interpolation. Getting
# this wrong is a plan-time error, not a silent one.
# ------------------------------------------------------------------------------

resource "azapi_resource" "topic_space" {
  type      = "Microsoft.EventGrid/namespaces/topicSpaces@2025-02-15"
  name      = "devices"
  parent_id = local.namespace_id

  body = {
    properties = {
      description = "Per-device telemetry and commands."
      topicTemplates = [
        "devices/$${principal.deviceId}/telemetry",
        "devices/+/commands",
      ]
    }
  }
}

# ------------------------------------------------------------------------------
# Client group — a query over client attributes
#
# A built-in "$all" group already contains every client, so this is only needed
# to narrow access. Binding permissions to "$all" is fine in dev and too broad
# in production.
# ------------------------------------------------------------------------------

resource "azapi_resource" "client_group" {
  type      = "Microsoft.EventGrid/namespaces/clientGroups@2025-02-15"
  name      = "sensors"
  parent_id = local.namespace_id

  body = {
    properties = {
      description = "All sensor devices."
      query       = "attributes.deviceType IN ['sensor']"
    }
  }
}

# ------------------------------------------------------------------------------
# Client — one device identity
#
# attributes are what client_group queries match on, so the two have to agree.
# ------------------------------------------------------------------------------

resource "azapi_resource" "client" {
  type      = "Microsoft.EventGrid/namespaces/clients@2025-02-15"
  name      = "sensor-001"
  parent_id = local.namespace_id

  body = {
    properties = {
      description        = "Floor 3 temperature sensor."
      authenticationName = "sensor-001"
      state              = "Enabled"

      attributes = {
        deviceType = "sensor"
        floor      = 3
      }

      clientCertificateAuthentication = {
        validationScheme   = "ThumbprintMatch"
        allowedThumbprints = [var.sensor_thumbprint]
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Permission bindings
#
# permission takes ONE of Publisher / Subscriber, not a list. A client group that
# both publishes and subscribes therefore needs two bindings against the same
# topic space. Forgetting the second one is the usual cause of a client that
# connects and authenticates but never receives anything.
# ------------------------------------------------------------------------------

resource "azapi_resource" "sensors_publish" {
  type      = "Microsoft.EventGrid/namespaces/permissionBindings@2025-02-15"
  name      = "sensors-publish"
  parent_id = local.namespace_id

  body = {
    properties = {
      description     = "Sensors publish telemetry."
      clientGroupName = azapi_resource.client_group.name
      topicSpaceName  = azapi_resource.topic_space.name
      permission      = "Publisher"
    }
  }
}

resource "azapi_resource" "sensors_subscribe" {
  type      = "Microsoft.EventGrid/namespaces/permissionBindings@2025-02-15"
  name      = "sensors-subscribe"
  parent_id = local.namespace_id

  body = {
    properties = {
      description     = "Sensors receive commands."
      clientGroupName = azapi_resource.client_group.name
      topicSpaceName  = azapi_resource.topic_space.name
      permission      = "Subscriber"
    }
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

# Namespace endpoints resolve in privatelink.eventgrid.azure.net ("topic") and
# privatelink.ts.eventgrid.azure.net ("topicspace", the MQTT endpoint). The
# module registers neither — feed this into your Private DNS registration.
output "private_endpoint_dns" {
  description = "FQDN + private IP pairs for external Private DNS registration."
  value       = module.eventgrid_namespace.private_endpoint_dns
}

output "topic_space_name" {
  description = "Topic space MQTT clients publish to and subscribe from."
  value       = azapi_resource.topic_space.name
}
