# Changelog

All notable changes to `terraform-azure-eventgrid-namespace` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Per the module standard, any breaking change — including renaming an interface or
a variable — increments MAJOR.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-07-29

Initial release. Bronze tier.

### Added

- `azurerm_eventgrid_namespace`, deployed into an existing resource group. SKU is
  hardcoded to `Standard` (the only value the provider accepts) and
  `public_network_access` to `Disabled`.
- Composed naming: `evgns-<application_code>-<environment>-<object_index>`, with
  a random 3-digit index when `object_index` is `000`. `application_code` is
  bounded to 36 characters against the 50-character Event Grid limit.
- Governance tags (`company`, `owner`) and tracking tags (`managed_by`,
  `source_repo`, `module_name`, `module_version`, `deployed_by`) on every
  resource that accepts tags. Caller tags cannot override either set.
- **`networking` interface** — private endpoints on the `topic` sub-resource, and
  on `topicspace` when MQTT is enabled. No `private_dns_zone_group`; the
  `private_endpoint_dns` output carries FQDN/IP pairs for external registration.
- **`managed_identity` interface** — optional system-assigned identity, exported
  as `identity_principal_id` for the central assignment layer.
- **`lock` interface** — optional `CanNotDelete` / `ReadOnly` management lock.
- Namespace topics via a `for_each` map (`topics`), so adding or removing one
  does not disturb the others. `event_retention_in_days` is validated to 1–7.
- MQTT broker support via the `mqtt` object: session limits, alternative
  authentication name sources, route topic, and static/dynamic routing
  enrichments.
- `capacity` (throughput units), validated to 1–40.
- A precondition requiring `managed_identity.enabled` when `mqtt.route_topic_id`
  is set — the namespace routes to that topic as itself.
- `examples/basic/` and 18 `terraform test` validation runs covering every
  validation rule, both preconditions, the defaults, and the fullest
  configuration.

### Deliberately omitted

- **`encryption` (CMK)** — `azurerm_eventgrid_namespace` exposes no
  `customer_managed_key` block, and the Azure security baseline records CMK as
  unsupported for Event Grid (MCSB DP-5). Reaching it would require moving the
  resource to `azapi`.
- **`high_availability`, `backup`, `multi_region`** — above Bronze. Event Grid
  also has no backup concept at any tier, and no `zones` argument.
- **Role assignments** — nothing the module creates needs a grant at create time.

### Known limitations

- The composed-name precondition cannot fail through valid input
  (`application_code` ≤ 36 puts the longest name at exactly 50). It is retained
  as defense in depth against a future prefix change and has no test.
- `topic_spaces_configuration` is create-only: changing anything inside `mqtt`,
  including `enabled`, forces namespace replacement and loses MQTT sessions and
  undelivered events.
- The provider builds this resource on the `2023-12-15-preview` Event Grid API
  while topics and domains are on `2025-02-15` GA; some ARM properties are not
  yet exposed.
- `azurerm_eventgrid_namespace` exports no endpoint attribute, so the module has
  no endpoint output.

[Unreleased]: https://github.com/difoul/terraform-azure-eventgrid-namespace/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/difoul/terraform-azure-eventgrid-namespace/releases/tag/v0.1.0
