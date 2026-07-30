# Changelog

All notable changes to `terraform-azure-eventgrid-namespace` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Per the module standard, any breaking change — including renaming an interface or
a variable — increments MAJOR.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-07-30

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
- MQTT broker support via the `mqtt` object: session limits and alternative
  authentication name sources.
- `capacity` (throughput units), validated to 1–40.
- `examples/basic/`, `examples/mqtt/` and 25 `terraform test` validation runs
  covering every validation rule, the precondition, the defaults, null handling,
  and the fullest configuration. `examples/mqtt/` shows the `azapi` companions an
  MQTT namespace needs — topic space, client group, client, permission bindings —
  since azurerm has no resources for them.

### Deliberately omitted

- **`encryption` (CMK)** — `azurerm_eventgrid_namespace` exposes no
  `customer_managed_key` block, and the Azure security baseline records CMK as
  unsupported for Event Grid (MCSB DP-5). Reaching it would require moving the
  resource to `azapi`.
- **`high_availability`, `backup`, `multi_region`** — above Bronze. Event Grid also
  has no backup concept at any tier. Zone redundancy is not a `zones` argument: ARM
  has `isZoneRedundant`, azurerm exposes nothing equivalent, and it is immutable
  after create — so the Silver upgrade cannot enable it on an existing namespace.
- **Role assignments** — nothing the module creates needs a grant at create time.
- **MQTT routing** — `mqtt.route_topic_id` and the two routing enrichment maps are
  rejected at plan rather than exposed. Azure documents that
  [disabling public network access causes MQTT routing to fail](https://learn.microsoft.com/azure/event-grid/mqtt-routing#routing-configuration),
  and this module hardcodes `public_network_access = "Disabled"`, so Terraform
  would apply a routing config successfully and the messages would silently never
  arrive. The three fields remain declared in the `mqtt` object type because
  Terraform silently discards object attributes it does not know: removing them
  would drop a caller's routing config with no error at all, which is worse than
  the plan-time rejection. Routing needs a namespace with public access enabled,
  which is out of scope here.
  Consequently `managed_identity` has no consumer inside the module; it is retained
  as a standard supporting interface and exported for the central layer.

### Known limitations

- The composed-name precondition cannot fail through valid input
  (`application_code` ≤ 36 puts the longest name at exactly 50). It is retained
  as defense in depth against a future prefix change and has no test.
- `topic_spaces_configuration` is create-only: changing anything inside `mqtt`,
  including `enabled`, forces namespace replacement and loses MQTT sessions and
  undelivered events.
- The provider builds this resource on the `2023-12-15-preview` Event Grid API
  while topics and domains are on `2025-02-15` GA; some ARM properties are not
  yet exposed. Two matter: `minimumTlsVersionAllowed`, so the module cannot pin
  TLS 1.2 as the Well-Architected guide calls for, and `isZoneRedundant`.
- `checkov` and `trivy` both report zero findings, and that is not evidence of
  anything: neither ships a policy for `azurerm_eventgrid_namespace`. Checkov's
  Event Grid policies all target `azurerm_eventgrid_topic` / `_domain` (Basic
  tier); trivy has none. Do not treat a green scan here as a review.
- `azurerm_eventgrid_namespace` exports no endpoint attribute, so the module has
  no endpoint output.
- azurerm ships no resources for topic spaces, MQTT clients, client groups, CA
  certificates, permission bindings, or namespace-topic event subscriptions — only
  `azurerm_eventgrid_namespace` and `azurerm_eventgrid_namespace_topic`. An
  MQTT-enabled namespace therefore needs a non-Terraform step (`azapi`, CLI,
  portal) before any client can connect, and MQTT access control is permission
  bindings rather than Azure RBAC, so the central assignment layer does not cover
  it. Pull delivery likewise needs an event subscription the provider cannot
  create.

[Unreleased]: https://github.com/difoul/terraform-azure-eventgrid-namespace/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/difoul/terraform-azure-eventgrid-namespace/releases/tag/v0.1.0
