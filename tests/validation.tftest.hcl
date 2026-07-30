// A module declares no provider, but terraform test configures one before
// evaluating anything — without the mock, a real azurerm provider tries to
// authenticate and the whole suite fails on credentials rather than running.
mock_provider "azurerm" {}

variables {
  application_code           = "myapp"
  environment                = "dev"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-dev-001"
  company                    = "contoso"
  owner                      = "platform-team"
  source_repo                = "test"
  networking                 = { subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink" }
}

# ------------------------------------------------------------------------------
# Resource wiring — no validation rule would catch a mistake here.
# ------------------------------------------------------------------------------

run "defaults_plan_cleanly" {
  command = plan
}

run "fullest_configuration_plans_cleanly" {
  command = plan

  variables {
    object_index = "007"
    capacity     = 12

    topics = {
      "orders"    = { event_retention_in_days = 7 }
      "inventory" = {}
    }

    mqtt = {
      enabled                                         = true
      maximum_client_sessions_per_authentication_name = 10
      maximum_session_expiry_in_hours                 = 8
      alternative_authentication_name_sources         = ["ClientCertificateDns"]
    }

    managed_identity = { enabled = true }

    networking = {
      subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink"
      private_endpoints = {
        topic      = { private_ip_address = "10.0.1.10" }
        topicspace = {}
      }
    }

    lock = { enabled = true, level = "ReadOnly" }
  }
}

# ------------------------------------------------------------------------------
# Base variable validation
# ------------------------------------------------------------------------------

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "prod" # the valid value is prd
  }

  expect_failures = [var.environment]
}

run "rejects_non_three_digit_object_index" {
  command = plan

  variables {
    object_index = "12"
  }

  expect_failures = [var.object_index]
}

run "rejects_uppercase_application_code" {
  command = plan

  variables {
    application_code = "MyApp"
  }

  expect_failures = [var.application_code]
}

run "rejects_application_code_over_name_budget" {
  command = plan

  variables {
    application_code = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # 37 chars
  }

  expect_failures = [var.application_code]
}

# ------------------------------------------------------------------------------
# Service-specific validation
# ------------------------------------------------------------------------------

run "rejects_capacity_above_forty" {
  command = plan

  variables {
    capacity = 41
  }

  expect_failures = [var.capacity]
}

run "rejects_invalid_topic_name" {
  command = plan

  variables {
    topics = { "bad_topic_name" = {} }
  }

  expect_failures = [var.topics]
}

run "rejects_topic_retention_over_seven_days" {
  command = plan

  variables {
    topics = { "orders" = { event_retention_in_days = 30 } }
  }

  expect_failures = [var.topics]
}

run "rejects_too_many_client_sessions" {
  command = plan

  variables {
    mqtt = {
      enabled                                         = true
      maximum_client_sessions_per_authentication_name = 101
    }
  }

  expect_failures = [var.mqtt]
}

run "rejects_session_expiry_over_eight_hours" {
  command = plan

  variables {
    mqtt = {
      enabled                         = true
      maximum_session_expiry_in_hours = 9
    }
  }

  expect_failures = [var.mqtt]
}

run "rejects_unknown_alternative_authentication_name_source" {
  command = plan

  variables {
    mqtt = {
      enabled                                 = true
      alternative_authentication_name_sources = ["ClientCertificateThumbprint"]
    }
  }

  expect_failures = [var.mqtt]
}

# ------------------------------------------------------------------------------
# networking interface validation
# ------------------------------------------------------------------------------

run "rejects_unsupported_private_endpoint_subresource" {
  command = plan

  variables {
    networking = {
      subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink"
      private_endpoints = { namespace = {} }
    }
  }

  expect_failures = [var.networking]
}

run "rejects_malformed_private_ip_address" {
  command = plan

  variables {
    networking = {
      subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink"
      private_endpoints = { topic = { private_ip_address = "10.0.1" } }
    }
  }

  expect_failures = [var.networking]
}

run "rejects_integration_subnet_id" {
  command = plan

  variables {
    networking = {
      subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink"
      integration_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-delegated"
    }
  }

  expect_failures = [var.networking]
}

run "rejects_invalid_lock_level" {
  command = plan

  variables {
    lock = { enabled = true, level = "DoNotTouch" }
  }

  expect_failures = [var.lock]
}

# ------------------------------------------------------------------------------
# Null handling
#
# Every optional variable is nullable = false, so an explicit null falls back to
# the default. Without that, a null aborted the plan with an internal "attribute
# from null value" / "argument must not be null" error before any validation could
# report anything useful.
# ------------------------------------------------------------------------------

run "explicit_nulls_fall_back_to_defaults" {
  command = plan

  variables {
    mqtt             = null
    lock             = null
    topics           = null
    tags             = null
    capacity         = null
    managed_identity = null
    object_index     = null
  }
}

run "null_inside_mqtt_falls_back_to_defaults" {
  command = plan

  variables {
    mqtt = {
      enabled                     = true
      static_routing_enrichments  = null
      dynamic_routing_enrichments = null
    }
  }
}

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

run "rejects_topicspace_endpoint_without_mqtt" {
  command = plan

  variables {
    networking = {
      subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-dev-001/providers/Microsoft.Network/virtualNetworks/vnet-myapp-dev-001/subnets/snet-privatelink"
      private_endpoints = { topicspace = {} }
    }
  }

  expect_failures = [azurerm_private_endpoint.this]
}

// MQTT routing needs public network access, which the module always disables.
run "rejects_route_topic_id" {
  command = plan

  variables {
    mqtt = {
      enabled        = true
      route_topic_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.EventGrid/namespaces/ns/topics/route"
    }
    managed_identity = { enabled = true }
  }

  expect_failures = [var.mqtt]
}

run "rejects_static_routing_enrichments" {
  command = plan

  variables {
    mqtt = {
      enabled                    = true
      static_routing_enrichments = { tenant = "contoso" }
    }
  }

  expect_failures = [var.mqtt]
}

run "rejects_dynamic_routing_enrichments" {
  command = plan

  variables {
    mqtt = {
      enabled                     = true
      dynamic_routing_enrichments = { device = "$${client.authenticationName}" }
    }
  }

  expect_failures = [var.mqtt]
}
