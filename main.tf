data "azurerm_client_config" "current" {}

# ------------------------------------------------------------------------------
# Naming, tagging and derived locals
# ------------------------------------------------------------------------------

resource "random_integer" "index" {
  count = var.object_index == "000" ? 1 : 0
  min   = 1
  max   = 999
}

locals {
  type        = "evgns"               # baked per module
  module_name = "eventgrid-namespace" # baked per module

  object_index = var.object_index == "000" ? format("%03d", random_integer.index[0].result) : var.object_index

  name_raw = "${local.type}-${var.application_code}-${var.environment}-${local.object_index}"

  # Event Grid namespaces allow hyphens and fit the standard hyphenated pattern.
  name = local.name_raw

  # Computed from known values only: the object index is always 3 characters,
  # even when its value comes from random_integer and is unknown at plan.
  name_length = length(local.type) + 1 + length(var.application_code) + 1 + length(var.environment) + 1 + 3

  # Event Grid namespaces expose "topic" for pull/push delivery and "topicspace"
  # for the MQTT broker. The MQTT sub-resource only exists when MQTT is enabled.
  default_subresources = var.mqtt.enabled ? ["topic", "topicspace"] : ["topic"]

  pe_targets = length(var.networking.private_endpoints) > 0 ? var.networking.private_endpoints : {
    for s in local.default_subresources : s => { private_ip_address = null }
  }

  governance_tags = {
    company = var.company
    owner   = var.owner
  }

  tracking_tags = {
    managed_by     = "terraform"
    source_repo    = var.source_repo
    module_name    = local.module_name
    module_version = trimspace(file("${path.module}/VERSION"))
    deployed_by    = data.azurerm_client_config.current.object_id
  }

  # merge order: a caller's tags cannot override a governance or tracking tag.
  all_tags = merge(var.tags, local.governance_tags, local.tracking_tags)
}

# ------------------------------------------------------------------------------
# Event Grid Namespace
#
# No role assignments: nothing this module creates needs a grant at create time.
# Access — including any grant on an MQTT route topic — is the central layer's.
# ------------------------------------------------------------------------------

resource "azurerm_eventgrid_namespace" "this" {
  name                = local.name
  location            = var.location
  resource_group_name = var.target_resource_group_name
  capacity            = var.capacity

  # Forbidden configurations, enforced here. "Standard" is the only SKU the
  # provider accepts, so it is baked rather than exposed as a knob.
  sku                   = "Standard"
  public_network_access = "Disabled"

  dynamic "identity" {
    for_each = var.managed_identity.enabled ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  # MQTT broker. Changing this block forces a new namespace — see the README.
  #
  # No route_topic_id and no routing enrichments: MQTT routing requires public
  # network access, which this module disables unconditionally, so var.mqtt
  # rejects all three. Restoring them means dropping those validations and
  # exposing public_network_access — not one without the other.
  dynamic "topic_spaces_configuration" {
    for_each = var.mqtt.enabled ? [var.mqtt] : []
    content {
      alternative_authentication_name_source          = topic_spaces_configuration.value.alternative_authentication_name_sources
      maximum_client_sessions_per_authentication_name = topic_spaces_configuration.value.maximum_client_sessions_per_authentication_name
      maximum_session_expiry_in_hours                 = topic_spaces_configuration.value.maximum_session_expiry_in_hours
    }
  }

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = local.name_length <= 50
      error_message = "Composed namespace name '${local.name_raw}' exceeds 50 characters; shorten application_code."
    }
  }
}

# ------------------------------------------------------------------------------
# Namespace topics
# ------------------------------------------------------------------------------

resource "azurerm_eventgrid_namespace_topic" "this" {
  for_each = var.topics

  name                    = each.key
  eventgrid_namespace_id  = azurerm_eventgrid_namespace.this.id
  event_retention_in_days = each.value.event_retention_in_days

  # No tags argument on this resource — there is nowhere to put them.
}

# ------------------------------------------------------------------------------
# Private endpoint(s) — no Private DNS zone group; DNS is wired externally.
# ------------------------------------------------------------------------------

resource "azurerm_private_endpoint" "this" {
  for_each            = local.pe_targets
  name                = "pe-${local.name}-${each.key}"
  location            = var.location
  resource_group_name = var.target_resource_group_name
  subnet_id           = var.networking.subnet_id

  private_service_connection {
    name                           = "psc-${local.name}-${each.key}"
    private_connection_resource_id = azurerm_eventgrid_namespace.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  dynamic "ip_configuration" {
    for_each = each.value.private_ip_address != null ? [1] : []
    content {
      name               = "ipconfig-${each.key}"
      private_ip_address = each.value.private_ip_address
      subresource_name   = each.key
      member_name        = each.key
    }
  }

  tags = local.all_tags
  # No private_dns_zone_group — DNS is registered externally from the
  # private_endpoint_dns output.

  lifecycle {
    precondition {
      condition     = each.key != "topicspace" || var.mqtt.enabled
      error_message = "The \"topicspace\" private endpoint sub-resource requires mqtt.enabled = true."
    }
  }
}

# ------------------------------------------------------------------------------
# Optional management lock
# ------------------------------------------------------------------------------

resource "azurerm_management_lock" "this" {
  for_each = var.lock.enabled ? { this = var.lock } : {}

  name       = "lock-${local.name}"
  scope      = azurerm_eventgrid_namespace.this.id
  lock_level = each.value.level
  notes      = "Managed by the eventgrid-namespace module."
}
