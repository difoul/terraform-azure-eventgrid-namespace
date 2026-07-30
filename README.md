# terraform-azure-eventgrid-namespace

Deploys one Azure Event Grid **Namespace** per application per environment,
together with its namespace topics, its optional MQTT broker, and its private
endpoints. Public network access is off and cannot be turned on.

The module is control plane only: it builds the namespace, its topics and its
endpoints, and grants **no** RBAC. Data-plane access is the **central assignment
layer**'s.

> **The namespace is not fully wireable in Terraform.** azurerm ships exactly two
> resources for this service — `azurerm_eventgrid_namespace` and
> `azurerm_eventgrid_namespace_topic`. There is **no** resource for topic spaces,
> MQTT clients, client groups, CA certificates, permission bindings, or
> namespace-topic event subscriptions. This is a provider gap, not a scope
> decision, and it has two consequences you must plan for:
>
> - **MQTT is unusable until you configure it outside Terraform.** A client cannot
>   connect without a topic space and a permission binding, and MQTT access control
>   is permission bindings — *not* Azure RBAC — so the central assignment layer does
>   not cover it. Use `azapi`, the CLI, or the portal.
> - **Pull delivery needs an event subscription on the namespace topic,** which the
>   provider cannot create either. `azurerm_eventgrid_event_subscription` targets
>   Basic-tier topics and resource scopes, not namespace topics.

This module covers the namespace model (MQTT broker, pull delivery, namespace
topics). Custom topics (`azurerm_eventgrid_topic`) and domains
(`azurerm_eventgrid_domain`) are different services with different modules.

## Tier

Bronze. It implements `networking`, plus the supporting `managed_identity` and
`lock` interfaces.

| Interface | Status |
|---|---|
| `networking` | ✓ one private endpoint per requested sub-resource |
| `encryption` | **omitted** — `azurerm_eventgrid_namespace` exposes no `customer_managed_key` block, and the Azure security baseline for Event Grid records CMK as unsupported (MCSB DP-5). A no-op knob would be worse than its absence; data at rest is encrypted with Microsoft-managed keys |
| `high_availability` | Silver, out of tier. There is also no `zones` argument — a namespace is zone-redundant automatically in regions that support availability zones |
| `backup` | Gold, out of tier. Event Grid has no backup concept at all, so this interface stays absent at every tier |
| `multi_region` | Platinum, out of tier |
| `managed_identity` | ✓ optional system-assigned identity, exported for the central layer |
| `lock` | ✓ |

## What it enforces

| Setting | Value | Why |
|---|---|---|
| `public_network_access` | `"Disabled"` (hardcoded) | Private networking only |
| `sku` | `"Standard"` (hardcoded) | The only value the provider accepts; not a caller decision |
| `inbound_ip_rule` | not exposed | Meaningless with public access disabled |
| `mqtt.route_topic_id` | rejected | Azure fails MQTT routing when public network access is disabled ([docs](https://learn.microsoft.com/azure/event-grid/mqtt-routing#routing-configuration)). Terraform would apply the config and the messages would never arrive |
| `mqtt.*_routing_enrichments` | rejected | Only decorate routed messages, so dead for the same reason |
| Private DNS zone group | none | DNS is wired externally |
| Name | composed, never passed in | The naming convention is enforced, not trusted |
| Role assignments | none | Nothing the module creates needs a grant at create time |

## Usage

```hcl
module "eventgrid_namespace" {
  source = "git::https://<host>/terraform-azure-eventgrid-namespace.git?ref=v0.1.0"

  application_code           = "myapp"
  environment                = "prd"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-prd-001"

  company = "contoso"
  owner   = "platform-team"

  capacity = 4

  topics = {
    "orders"    = { event_retention_in_days = 7 }
    "inventory" = {}
  }

  networking = {
    subnet_id = azurerm_subnet.privatelink.id
    # Optional: pin a static IP, or narrow which sub-resources get an endpoint.
    # private_endpoints = { topic = { private_ip_address = "10.0.1.10" } }
  }

  lock = {
    enabled = true
    level   = "CanNotDelete"
  }

  # source_repo is set by the pipeline via TF_VAR_source_repo.
}
```

With the MQTT broker:

```hcl
module "eventgrid_namespace" {
  # ... as above ...

  mqtt = {
    enabled                                         = true
    maximum_client_sessions_per_authentication_name = 10
    maximum_session_expiry_in_hours                 = 8
    alternative_authentication_name_sources         = ["ClientCertificateDns"]
  }
}
```

This gives you a broker and a `topicspace` private endpoint, and nothing else.
Creating the topic spaces, clients, client groups and permission bindings that
make it usable is a separate, non-Terraform step — see the note at the top.
`mqtt.route_topic_id` is rejected; MQTT routing cannot work on a private-only
namespace.

Register DNS from the output:

```hcl
# Feed module.eventgrid_namespace.private_endpoint_dns into your Private DNS
# registration. Namespace endpoints resolve in:
#   privatelink.eventgrid.azure.net      ("topic")
#   privatelink.ts.eventgrid.azure.net   ("topicspace", MQTT)
output "eventgrid_dns" {
  value = module.eventgrid_namespace.private_endpoint_dns
}
```

## Inputs

| Name | Type | Default | Required |
|---|---|---|---|
| `application_code` | `string` (1–36 lowercase alphanumeric) | — | yes |
| `environment` | `string` (`dev`/`sim`/`uat`/`prd`) | — | yes |
| `location` | `string` | — | yes |
| `object_index` | `string` (3 digits, `000`=random) | `"000"` | no |
| `target_resource_group_name` | `string` | — | yes |
| `company` | `string` | — | yes |
| `owner` | `string` | — | yes |
| `tags` | `map(string)` | `{}` | no |
| `source_repo` | `string` | — | yes (pipeline) |
| `capacity` | `number` (1–40) | `1` | no |
| `topics` | `map(object({ event_retention_in_days = optional(number, 7) }))` | `{}` | no |
| `mqtt` | `object` | `{ enabled = false }` | no |
| `networking` | `object` | — | yes |
| `managed_identity` | `object` | `{ enabled = false }` | no |
| `lock` | `object` | `{ enabled = false }` | no |

## Outputs

| Name | Description |
|---|---|
| `id` | Event Grid Namespace resource ID |
| `name` | Composed namespace name |
| `topic_ids` | Namespace topic resource IDs, keyed by topic name |
| `identity_principal_id` | System-assigned identity principal ID, or `null` when disabled |
| `private_endpoint_dns` | FQDN + IP pairs for external DNS registration |

## Notes

- **Naming:** the module composes `evgns-<application_code>-<environment>-<object_index>`
  and enforces the 50-character Event Grid limit (`application_code` ≤ 36 chars).
  Namespace names must be unique within a region, not globally.
- **`topic_spaces_configuration` is create-only.** Turning `mqtt.enabled` on or
  off, or changing any value inside the `mqtt` object, forces a **new namespace** —
  the existing one is destroyed and recreated, and all MQTT sessions and
  undelivered events are lost. Decide on MQTT before the first apply.
- **MQTT routing is rejected, not merely unimplemented.** Azure documents that
  [disabling public network access causes MQTT routing to fail](https://learn.microsoft.com/azure/event-grid/mqtt-routing#routing-configuration),
  and this module disables it unconditionally. Setting `mqtt.route_topic_id` (or
  either routing enrichment map) fails at plan. Terraform would otherwise apply
  the routing config successfully and the messages would silently never arrive —
  the worst kind of no-op knob. If you need MQTT routing, you need a namespace
  with public access enabled, which is out of scope for this module.
- **Those three fields are still declared in the `mqtt` type,** which looks odd
  until you know why: Terraform silently discards object attributes that are not
  in the declared type. Removing them would not produce an error — it would drop
  the caller's routing config without a word and hand back a namespace that
  quietly does not route. Declaring them is what lets the module reject them at
  plan with an explanation. They are never read.
- **`managed_identity` has no consumer inside the module,** because routing is
  rejected. It stays because it is a standard supporting interface and the
  identity is exported for the central layer, but enabling it changes nothing
  about how the namespace behaves on its own.
- **No endpoint output.** `azurerm_eventgrid_namespace` exports only `id`; the
  provider surfaces no hostname attribute. Consumers derive the endpoint from
  the namespace name, or read it from `private_endpoint_dns`.
- **`topics` uses `for_each`,** so adding or removing one topic does not disturb
  the others. Topic names are 3–50 characters, alphanumerics and hyphens.
  `event_retention_in_days` is capped at 7 by the service.
- **Namespace topics carry no tags.** The provider gives
  `azurerm_eventgrid_namespace_topic` no `tags` argument; there is nowhere to
  put them. Every other resource this module creates is tagged.
- **The provider is behind the API here.** `azurerm_eventgrid_namespace` is built
  on the `2023-12-15-preview` Event Grid API, while topics and domains are on
  `2025-02-15` GA. Some namespace properties present in the ARM schema — CMK
  among them — are not yet exposed by azurerm. If CMK becomes a hard requirement
  before the provider catches up, the namespace resource would have to move to
  `azapi`; the interfaces, naming, tags and endpoints would not change.
- **`.terraform.lock.hcl`** is written and committed by the release pipeline.
- **Before use:** the service assessment (usage guidelines and any per-environment
  custom roles for publisher/subscriber access) must be complete.
