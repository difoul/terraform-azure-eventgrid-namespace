# ------------------------------------------------------------------------------
# Base variables (shared by every module)
# ------------------------------------------------------------------------------

variable "application_code" {
  nullable    = false
  description = "Short application code, used to compose the resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,36}$", var.application_code))
    error_message = "application_code must be 1-36 lowercase alphanumeric characters (the composed namespace name must stay within 50 characters)."
  }
}

variable "environment" {
  nullable    = false
  description = "Environment. Drives the custom-role lookup (e.g. prd -> [PRD] ...)."
  type        = string

  validation {
    condition     = contains(["dev", "sim", "uat", "prd"], var.environment)
    error_message = "environment must be one of: dev, sim, uat, prd."
  }
}

variable "location" {
  nullable    = false
  description = "Azure region the Event Grid Namespace is deployed into."
  type        = string
}

variable "object_index" {
  nullable    = false
  description = "3-digit object index. 000 means the module generates a random index."
  type        = string
  default     = "000"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.object_index))
    error_message = "object_index must be exactly 3 digits."
  }
}

variable "target_resource_group_name" {
  nullable    = false
  description = "Existing resource group the module deploys into. The module never creates a resource group."
  type        = string
}

variable "company" {
  nullable    = false
  description = "Required governance tag."
  type        = string
}

variable "owner" {
  nullable    = false
  description = "Required governance tag."
  type        = string
}

variable "tags" {
  nullable    = false
  description = "Extra business tags. Cannot override governance or tracking tags."
  type        = map(string)
  default     = {}
}

variable "source_repo" {
  nullable    = false
  description = "Consumer repo that triggered the deploy. Set by the pipeline via TF_VAR_source_repo."
  type        = string
}

# ------------------------------------------------------------------------------
# Service-specific variables (Event Grid Namespace)
# ------------------------------------------------------------------------------

variable "capacity" {
  nullable    = false
  description = "Throughput units for the namespace. Each unit adds ingress/egress capacity and connection quota."
  type        = number
  default     = 1

  validation {
    condition     = var.capacity >= 1 && var.capacity <= 40
    error_message = "capacity must be between 1 and 40."
  }
}

variable "topics" {
  nullable    = false
  description = <<-EOT
    Namespace topics to create, keyed by topic name. Adding or removing one
    does not disturb the others.
      - event_retention_in_days: how long an unconsumed event is kept (1-7).
  EOT
  type = map(object({
    event_retention_in_days = optional(number, 7)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k in keys(var.topics) : can(regex("^[a-zA-Z0-9-]{3,50}$", k))
    ])
    error_message = "Each topic name must be 3-50 characters of alphanumerics and hyphens."
  }

  validation {
    condition = alltrue([
      for t in values(var.topics) :
      coalesce(t.event_retention_in_days, 7) >= 1 && coalesce(t.event_retention_in_days, 7) <= 7
    ])
    error_message = "topics[*].event_retention_in_days must be between 1 and 7."
  }
}

variable "mqtt" {
  nullable    = false
  description = <<-EOT
    MQTT broker (topic spaces) configuration. Disabled by default; the namespace
    then serves pull and push delivery only.

    Enabling or disabling MQTT after creation forces a new namespace — the
    underlying block is create-only. See the README.
      - enabled: turn the MQTT broker on
      - maximum_client_sessions_per_authentication_name: concurrent sessions per client (1-100)
      - maximum_session_expiry_in_hours: longest session expiry a client may request (1-8)
      - alternative_authentication_name_sources: client certificate fields accepted
          as the authentication name, in addition to the default
      - route_topic_id: rejected. MQTT routing cannot work in this module —
          Azure fails routing on any namespace with public network access
          disabled, and this module disables it unconditionally. See the README.
      - static_routing_enrichments / dynamic_routing_enrichments: key/value pairs
          added to routed messages. Only meaningful with routing, so these are
          rejected for the same reason.
  EOT
  type = object({
    enabled                                         = optional(bool, false)
    maximum_client_sessions_per_authentication_name = optional(number)
    maximum_session_expiry_in_hours                 = optional(number)
    alternative_authentication_name_sources         = optional(list(string))

    # Declared only so the validations below can reject them — main.tf never reads
    # these three. Terraform silently discards object attributes that are not in
    # the declared type, so deleting them would turn a plan-time error into no
    # feedback at all: the caller's routing config would vanish and the namespace
    # would come up with routing quietly absent.
    route_topic_id              = optional(string)
    static_routing_enrichments  = optional(map(string), {})
    dynamic_routing_enrichments = optional(map(string), {})
  })
  default = { enabled = false }

  # Both optional and unset by default, so both are null on a normal call. Guard
  # that with coalesce and never with `x == null || x >= 1`: Terraform does not
  # guarantee short-circuit evaluation of || and &&, so the comparison can still be
  # evaluated against the null and abort the plan with "argument must not be null".
  # The fallback is 1 because it is in range for both rules and is also Azure's own
  # default for both properties, so a null reads as "leave it to the service".
  validation {
    condition = (
      coalesce(var.mqtt.maximum_client_sessions_per_authentication_name, 1) >= 1 &&
      coalesce(var.mqtt.maximum_client_sessions_per_authentication_name, 1) <= 100
    )
    error_message = "mqtt.maximum_client_sessions_per_authentication_name must be between 1 and 100."
  }

  validation {
    condition = (
      coalesce(var.mqtt.maximum_session_expiry_in_hours, 1) >= 1 &&
      coalesce(var.mqtt.maximum_session_expiry_in_hours, 1) <= 8
    )
    error_message = "mqtt.maximum_session_expiry_in_hours must be between 1 and 8."
  }

  validation {
    condition = alltrue([
      for s in coalesce(var.mqtt.alternative_authentication_name_sources, []) :
      contains([
        "ClientCertificateDns", "ClientCertificateEmail", "ClientCertificateIp",
        "ClientCertificateSubject", "ClientCertificateUri"
      ], s)
    ])
    error_message = "mqtt.alternative_authentication_name_sources must be drawn from: ClientCertificateDns, ClientCertificateEmail, ClientCertificateIp, ClientCertificateSubject, ClientCertificateUri."
  }

  # MQTT routing needs public network access on the namespace, which this module
  # disables unconditionally. Terraform would apply a routing config happily and
  # the messages would then never arrive, so reject it at plan time instead of
  # shipping a knob that silently does nothing.
  validation {
    condition     = var.mqtt.route_topic_id == null
    error_message = "mqtt.route_topic_id is not supported: Azure fails MQTT routing on any namespace with public network access disabled, and this module hardcodes public_network_access = \"Disabled\". Route MQTT messages from a namespace built outside this module, or consume them from a topic space directly. See https://learn.microsoft.com/azure/event-grid/mqtt-routing#routing-configuration"
  }

  # Enrichments only decorate routed messages, so they are dead for the same reason.
  # coalesce, not a bare length(): an explicitly null map would make length() abort
  # the whole plan with "argument must not be null" instead of reporting this rule.
  validation {
    condition = (
      length(coalesce(var.mqtt.static_routing_enrichments, {})) == 0 &&
      length(coalesce(var.mqtt.dynamic_routing_enrichments, {})) == 0
    )
    error_message = "mqtt.static_routing_enrichments and mqtt.dynamic_routing_enrichments only apply to routed messages, and mqtt.route_topic_id is not supported by this module. Leave both empty."
  }
}

# ------------------------------------------------------------------------------
# Standard interface: networking (Bronze)
#
# The encryption (CMK) interface is deliberately absent: azurerm_eventgrid_namespace
# exposes no customer_managed_key block, and the Azure security baseline records
# CMK as unsupported for Event Grid. See the README.
# ------------------------------------------------------------------------------

variable "networking" {
  nullable    = false
  description = <<-EOT
    Private networking. Endpoints are never registered in a Private DNS zone —
    DNS is wired externally from the private_endpoint_dns output.
      - subnet_id: subnet for the private endpoint(s) (app-owned)
      - private_endpoints: which sub-resources to expose privately, keyed by
          sub-resource name, each with an optional static IP. Leave empty and the
          module creates the namespace's standard set with dynamic IPs: "topic",
          plus "topicspace" when mqtt.enabled. Event Grid namespaces support
          only those two sub-resources.
      - integration_subnet_id: unused by Event Grid (PE-only service). Leave null.
  EOT
  type = object({
    subnet_id = string
    private_endpoints = optional(map(object({
      private_ip_address = optional(string)
    })), {})
    integration_subnet_id = optional(string)
  })

  # coalesce on private_endpoints, and coalesce inside the IP check rather than an
  # `== null ||` guard, for the same reason as the mqtt rules above: no reliance on
  # short-circuit evaluation or on a null being replaced by the optional default.
  validation {
    condition = alltrue([
      for k in keys(coalesce(var.networking.private_endpoints, {})) :
      contains(["topic", "topicspace"], k)
    ])
    error_message = "Supported private endpoint sub-resources: topic, topicspace."
  }

  validation {
    condition = alltrue([
      for pe in values(coalesce(var.networking.private_endpoints, {})) :
      can(cidrhost("${coalesce(pe.private_ip_address, "0.0.0.0")}/32", 0))
    ])
    error_message = "Each private_endpoints[*].private_ip_address must be a valid IP address."
  }

  validation {
    condition     = var.networking.integration_subnet_id == null
    error_message = "networking.integration_subnet_id does not apply to Event Grid (PE-only). Leave it null."
  }
}

# ------------------------------------------------------------------------------
# Supporting interfaces: managed_identity, lock
# ------------------------------------------------------------------------------

variable "managed_identity" {
  nullable    = false
  description = <<-EOT
    Optional system-assigned managed identity on the namespace.

    Nothing this module builds consumes it. The one case that would have — MQTT
    routing to a route topic, where the namespace authenticates as itself — is
    rejected outright, because routing cannot work on a namespace with public
    network access disabled. So enabling this changes nothing about how the
    namespace behaves on its own.

    It stays because it is a standard supporting interface and the identity has
    to exist before anything can be granted to it: the principal ID is exported
    as identity_principal_id for the central assignment layer. Enable it when
    that layer needs a principal to grant. This module grants nothing.
  EOT
  type = object({
    enabled = optional(bool, false)
  })
  default = { enabled = false }
}

variable "lock" {
  nullable    = false
  description = <<-EOT
    Optional resource lock to prevent accidental deletion.
      - enabled: create the management lock
      - level: CanNotDelete or ReadOnly
  EOT
  type = object({
    enabled = optional(bool, false)
    level   = optional(string, "CanNotDelete")
  })
  default = { enabled = false }

  validation {
    condition     = contains(["CanNotDelete", "ReadOnly"], coalesce(var.lock.level, "CanNotDelete"))
    error_message = "lock.level must be one of: CanNotDelete, ReadOnly."
  }
}
