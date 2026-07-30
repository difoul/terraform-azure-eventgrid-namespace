# ------------------------------------------------------------------------------
# Base variables (shared by every module)
# ------------------------------------------------------------------------------

variable "application_code" {
  description = "Short application code, used to compose the resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,36}$", var.application_code))
    error_message = "application_code must be 1-36 lowercase alphanumeric characters (the composed namespace name must stay within 50 characters)."
  }
}

variable "environment" {
  description = "Environment. Drives the custom-role lookup (e.g. prd -> [PRD] ...)."
  type        = string

  validation {
    condition     = contains(["dev", "sim", "uat", "prd"], var.environment)
    error_message = "environment must be one of: dev, sim, uat, prd."
  }
}

variable "location" {
  description = "Azure region the Event Grid Namespace is deployed into."
  type        = string
}

variable "object_index" {
  description = "3-digit object index. 000 means the module generates a random index."
  type        = string
  default     = "000"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.object_index))
    error_message = "object_index must be exactly 3 digits."
  }
}

variable "target_resource_group_name" {
  description = "Existing resource group the module deploys into. The module never creates a resource group."
  type        = string
}

variable "company" {
  description = "Required governance tag."
  type        = string
}

variable "owner" {
  description = "Required governance tag."
  type        = string
}

variable "tags" {
  description = "Extra business tags. Cannot override governance or tracking tags."
  type        = map(string)
  default     = {}
}

variable "source_repo" {
  description = "Consumer repo that triggered the deploy. Set by the pipeline via TF_VAR_source_repo."
  type        = string
}

# ------------------------------------------------------------------------------
# Service-specific variables (Event Grid Namespace)
# ------------------------------------------------------------------------------

variable "capacity" {
  description = "Throughput units for the namespace. Each unit adds ingress/egress capacity and connection quota."
  type        = number
  default     = 1

  validation {
    condition     = var.capacity >= 1 && var.capacity <= 40
    error_message = "capacity must be between 1 and 40."
  }
}

variable "topics" {
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
      t.event_retention_in_days >= 1 && t.event_retention_in_days <= 7
    ])
    error_message = "topics[*].event_retention_in_days must be between 1 and 7."
  }
}

variable "mqtt" {
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

  validation {
    condition = (
      var.mqtt.maximum_client_sessions_per_authentication_name == null ||
      (var.mqtt.maximum_client_sessions_per_authentication_name >= 1 &&
      var.mqtt.maximum_client_sessions_per_authentication_name <= 100)
    )
    error_message = "mqtt.maximum_client_sessions_per_authentication_name must be between 1 and 100."
  }

  validation {
    condition = (
      var.mqtt.maximum_session_expiry_in_hours == null ||
      (var.mqtt.maximum_session_expiry_in_hours >= 1 &&
      var.mqtt.maximum_session_expiry_in_hours <= 8)
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
  validation {
    condition = (
      length(var.mqtt.static_routing_enrichments) == 0 &&
      length(var.mqtt.dynamic_routing_enrichments) == 0
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

  validation {
    condition = alltrue([
      for k in keys(var.networking.private_endpoints) :
      contains(["topic", "topicspace"], k)
    ])
    error_message = "Supported private endpoint sub-resources: topic, topicspace."
  }

  validation {
    condition = alltrue([
      for pe in values(var.networking.private_endpoints) :
      pe.private_ip_address == null || can(cidrhost("${pe.private_ip_address}/32", 0))
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
  description = <<-EOT
    Optional system-assigned managed identity on the namespace. Enable it when
    the namespace must reach another resource — MQTT routing to a route topic is
    the usual case. The identity's principal ID is exported so the central
    assignment layer can grant it access; this module grants nothing.
  EOT
  type = object({
    enabled = optional(bool, false)
  })
  default = { enabled = false }
}

variable "lock" {
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
    condition     = contains(["CanNotDelete", "ReadOnly"], var.lock.level)
    error_message = "lock.level must be one of: CanNotDelete, ReadOnly."
  }
}
