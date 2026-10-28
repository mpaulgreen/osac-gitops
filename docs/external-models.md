# External Models — Investigation & Status

**Status**: Open (blocked on upstream bug)  
**Tracker**: opendatahub-io/ai-gateway-controller#150  
**Branch**: `feature/rhoai-3.6`  
**Date**: 2026-10-28  

---

## Summary

Cross-cluster external model routing in RHOAI 3.6 is broken. The ai-gateway-controller v1.26.10 generates routing overlays that omit `path` and `targetModel` fields from ExternalModel CRDs. The ext-proc `intelligent_route` filter selects the correct candidate but cannot rewrite the path or body model name, and `credential_inject` never runs. Requests either hang (300s ext-proc timeout) or arrive at the spoke cluster without proper credentials.

The spoke model IS reachable at the full path (confirmed HTTP 200 with direct curl). The only gap is the translation layer in the ext-proc.

This is tracked in ai-gateway-controller#150. The controller ships with RHOAI 3.6.0 (no separate subscription), so a fix would come in a z-stream update.

---

## Architecture

### Clusters

| Role | Context | Domain |
|------|---------|--------|
| Hub (site-a) | `default/api-hub-kni-syseng-devcluster-openshift-com:6443/kube:admin` | `apps.hub.kni.syseng.devcluster.openshift.com` |
| Spoke (site-b) | `default/api-osacmaas-kni-syseng-devcluster-openshift-com:6443/kube:admin` | `apps.osacmaas.kni.syseng.devcluster.openshift.com` |

### Local Models (working)

| Cluster | Model | Namespace | Endpoint |
|---------|-------|-----------|----------|
| Hub | facebook-opt-125m | ai-grid-internal-models | `/v1/completions` |
| Spoke | granite-3-1-8b-fp8 | ai-grid-internal-models | `/v1/chat/completions` |

### External Models (broken)

| Cluster | ExternalModel | Target Cluster | Target Model | Upstream Path |
|---------|--------------|----------------|--------------|---------------|
| Hub | granite-remote | Spoke | granite-3.1-8b-instruct-fp8 | `/ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions` |
| Spoke | facebook-remote | Hub | facebook/opt-125m | `/ai-grid-internal-models/facebook-opt-125m/v1/chat/completions` |

### CRDs

**ExternalModel** (hub, granite-remote):
```yaml
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: granite-remote
  namespace: external-models
spec:
  externalProviderRefs:
    - ref:
        name: granite-remote-provider
      apiFormat: openai-chat
      targetModel: granite-3.1-8b-instruct-fp8
      path: /ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions
      weight: 1
```

**ExternalProvider** (hub, granite-remote):
```yaml
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
metadata:
  name: granite-remote-provider
  namespace: external-models
spec:
  endpoint: maas.apps.osacmaas.kni.syseng.devcluster.openshift.com
  provider: openai
  auth:
    type: apikey
    secretRef:
      name: granite-remote-key
```

### Ext-proc Services

Three separate ext-proc (praxis) services handle different stages:

1. **`payload-pre-processing`** (openshift-ingress:9004) — pre-auth, extracts model from body via `json_body` filter, sets `X-Gateway-Model-Name` header
2. **`payload-processing`** (openshift-ingress:9004) — post-auth for local models (IPP)
3. **`payload-processing-external-model`** (models-as-a-service:9004) — post-auth for external models, runs `intelligent_route` + `credential_inject` filters

### Routing Overlay

Located at `/etc/praxis/routing/routing-overlay.json` with `schema_version: "1.0.0"`. Contains candidates with `cluster`, `stable_id`, `kind`, `name`, `site`, `fresh`, `credential` fields — but **missing `path` and `targetModel` fields**. This is the root cause.

### Envoy Route Names (controller-generated, include hash)

- Hub: `external-models.external-model-granite-remote-292c28d58b49.{0,1,2,3}`
- Spoke: `external-models.external-model-facebook-remote-d97eb5087449.{0,1,2,3}`

---

## Root Cause Chain

1. **ai-gateway-controller v1.26.10** generates routing overlay without `path` and `targetModel`
2. The ext-proc `intelligent_route` filter selects the correct candidate from the overlay but has no path to rewrite to
3. `intelligent_route` rejects the request (HTTP 404 initially, then timeout after investigation)
4. `credential_inject` never runs because `intelligent_route` failed
5. Request arrives at spoke either:
   - Without credentials (spoke Authorino: `no such key: identity` → 403)
   - After a 300-second ext-proc timeout
   - With wrong path (`/v1/chat/completions` instead of `/ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions`)
   - With wrong model name in body (`granite-remote` instead of `granite-3.1-8b-instruct-fp8`)

---

## Investigation Timeline

### Phase 1: Initial ext-proc 404

Tested external model endpoint:
```bash
curl -sk "https://maas.${HUB_DOMAIN}/external-models/granite-remote/v1/chat/completions" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"model":"granite-remote","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```
**Result**: HTTP 404 from ext-proc `intelligent_route` on both clusters.

**Finding**: The ext-proc logs showed `intelligent_route` rejecting every external model request. The routing overlay at `/etc/praxis/routing/routing-overlay.json` was inspected and found to be missing `path` and `targetModel` fields despite the ExternalModel CRD having them correctly set.

### Phase 2: Confirmed spoke reachability

Direct curl to spoke with the full rewritten path:
```bash
curl -sk "https://maas.${SPOKE_DOMAIN}/ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"model":"granite-3.1-8b-instruct-fp8","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```
**Result**: HTTP 200. The spoke accepts hub JWTs and serves the model at the full path.

### Phase 3: EnvoyFilter workaround attempt

Built an EnvoyFilter workaround (`external-model-rewrite-workaround`) with three components:

1. **Path rewrite** — `regex_rewrite` / `prefix_rewrite` MERGEs on external model HTTPRoute rules
2. **Body model rewrite** — Lua HTTP filter rewrites `"model":"granite-remote"` → `"model":"granite-3.1-8b-instruct-fp8"` in request body
3. **ext-proc disable** — `typed_per_filter_config` to disable `envoy.filters.http.ext_proc.external-model` per-route, bypassing the broken `intelligent_route` entirely

The EnvoyFilter was applied to both clusters in `openshift-ingress` namespace.

#### What worked

- **Path rewrite**: Spoke access logs confirmed correct path (`/ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions`)
- **Body rewrite**: Spoke received 98 bytes (rewritten) vs hub's 85 bytes (original client body)
- **ext-proc disable**: Config dump confirmed `disabled: True` on all 4 external model route rules. Ext-proc logs stopped showing activity after the EnvoyFilter was applied.

#### What did NOT work

Even with ext-proc disabled, the spoke still returned **403** with Authorino error: `"no such key: identity"`.

**Critical finding from spoke Authorino logs**:
```
=== INCOMING REQUEST ===
  path: /ai-grid-internal-models/granite-3-1-8b-fp8/v1/chat/completions
  host: maas.apps.osacmaas.kni.syseng.devcluster.openshift.com
  headers present: NONE
  NO AUTHORIZATION HEADER
```

The Authorino incoming request showed **zero headers**. The Authorization header was not reaching the spoke's Authorino at all, even though:
- The ext-proc was disabled (not consuming the header)
- The route's `request_headers_to_remove` only removes `x-ai-routing-*` headers, NOT Authorization
- Direct curl to spoke with the same JWT works (HTTP 200)

### Phase 4: Header stripping analysis (incomplete)

The forwarding mechanism (hub Envoy → spoke via Istio outbound to `maas.apps.osacmaas...`) strips headers. Possible causes identified but not yet investigated:

1. **Istio outbound TLS origination** may strip auth headers by default
2. **Hub Kuadrant ext_authz response** may modify/consume the Authorization header (Authorino's `response` section can mutate headers)
3. **DestinationRule or PeerAuthentication** between clusters may affect header propagation
4. **Pre-processor ext-proc** (`ext_proc.external-model-pre`) may still be consuming headers even though the post-auth ext-proc was disabled
5. **Hub Authorino response headers** may replace originals (the hub's auth succeeds and may inject `x-maas-*` identity headers, while potentially stripping the original Authorization)

This remains the **open blocker** — path and body rewrites work, but credential forwarding does not.

---

## Auth Architecture (for reference)

### Kuadrant AuthPolicy (`maas-gateway-auth`, both clusters)

Three authentication methods (priority order):
1. **api-keys** (priority 0): matches `Bearer sk-oai-*` pattern
2. **oidc-identities** (priority 1): JWT from hub Keycloak (`issuerUrl: https://keycloak-maas-db.apps.hub.kni.syseng.devcluster.openshift.com/realms/saas`)
3. **openshift-identities** (priority 2): Kubernetes token review

### Spoke authorization rules

- **deny-client-identity-headers**: Denies requests carrying any `x-maas-*` identity headers (prevents client injection of identity)

### Keycloak

- Route: `keycloak-maas-db.apps.hub.kni.syseng.devcluster.openshift.com`
- Realm: `saas`
- Client: `tenant-demo` (ROPC enabled)
- Test user: `novatech-free` / `password123`

### JWT acquisition
```bash
KC_URL="https://keycloak-maas-db.apps.hub.kni.syseng.devcluster.openshift.com"
JWT=$(curl -sk "${KC_URL}/realms/saas/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=tenant-demo \
  -d username=novatech-free -d password=password123 \
  -d scope=openid | jq -r .access_token)
```

---

## Workaround EnvoyFilter (reverted)

An EnvoyFilter was tested that addressed path rewrite, body model rewrite, and ext-proc bypass. It was reverted because the credential forwarding problem makes it insufficient on its own. The EnvoyFilter approach is preserved below for reference when the header-stripping issue is resolved.

<details>
<summary>EnvoyFilter YAML (for reference only — not applied)</summary>

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: external-model-rewrite-workaround
  namespace: openshift-ingress
  labels:
    osac.io/workaround: agc-150
spec:
  priority: 25
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    # Route MERGEs: regex_rewrite for .0 rules, prefix_rewrite for .1 rules
    # Each route also disables ext_proc.external-model per-route
    - applyTo: HTTP_ROUTE
      match:
        context: GATEWAY
        routeConfiguration:
          vhost:
            route:
              name: external-models.external-model-granite-remote-292c28d58b49.0
      patch:
        operation: MERGE
        value:
          route:
            regex_rewrite:
              pattern:
                regex: "^/external-models/granite-remote(/?)(.*)"
              substitution: "/ai-grid-internal-models/granite-3-1-8b-fp8/\\2"
          typed_per_filter_config:
            envoy.filters.http.ext_proc.external-model:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExtProcPerRoute
              disabled: true
    # (additional route MERGEs for .1, facebook-remote .0, .1 follow same pattern)

    # Lua body rewrite — rewrites "model":"<client-name>" to "model":"<upstream-name>"
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.ext_proc.external-model
      patch:
        operation: INSERT_AFTER
        value:
          name: envoy.filters.http.lua.external-model-body-rewrite
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            default_source_code:
              inline_string: |
                local TARGETS = {
                  ["granite-remote"]  = "granite-3.1-8b-instruct-fp8",
                  ["facebook-remote"] = "facebook-opt-125m",
                }
                function envoy_on_request(rh)
                  local model = rh:headers():get("x-gateway-model-name")
                  if not model then return end
                  local target = TARGETS[model]
                  if not target then return end
                  local buf = rh:body()
                  if not buf or buf:length() == 0 then return end
                  local raw = buf:getBytes(0, buf:length())
                  local search = '"model":"' .. model .. '"'
                  local i, j = raw:find(search, 1, true)
                  if not i then
                    search = '"model": "' .. model .. '"'
                    i, j = raw:find(search, 1, true)
                  end
                  if i then
                    local out = raw:sub(1, i-1) .. '"model":"' .. target .. '"' .. raw:sub(j+1)
                    buf:setBytes(out)
                    rh:headers():replace("content-length", tostring(#out))
                  end
                end
```
</details>

---

## What's Confirmed Working

| Check | Result |
|-------|--------|
| Local inference hub (facebook-opt-125m) | 200 |
| Local inference spoke (granite-3-1-8b-fp8) | 200 |
| Direct spoke access with hub JWT at full path | 200 |
| ExternalModel / ExternalProvider CRDs correct | Yes |
| ExternalProvider secrets distributed (ESO) | Yes |
| Routing overlay candidate selection | Works (correct candidate selected) |
| EnvoyFilter path rewrite | Works (spoke receives correct path) |
| EnvoyFilter body model rewrite | Works (spoke receives rewritten model name) |
| EnvoyFilter ext-proc disable | Works (ext-proc stops processing) |
| All 22 ACM policies compliant | Yes |

## What's Broken

| Issue | Root Cause | Tracker |
|-------|-----------|---------|
| Routing overlay missing `path` and `targetModel` | ai-gateway-controller v1.26.10 bug | ai-gateway-controller#150 |
| ext-proc `intelligent_route` rejects all external model requests | Missing overlay fields | ai-gateway-controller#150 |
| `credential_inject` never runs | `intelligent_route` fails first | ai-gateway-controller#150 |
| Authorization header stripped in cross-cluster forwarding | Unknown — Istio/Envoy outbound or Authorino response mutation | Needs investigation |

---

## Next Steps (when unblocked)

1. **Wait for ai-gateway-controller fix** (z-stream update to RHOAI 3.6.x) that populates `path` and `targetModel` in the routing overlay
2. **Investigate header stripping** — determine why the Authorization header does not reach the spoke's Authorino when forwarded through the hub gateway (even with ext-proc disabled)
3. **Re-test with fixed controller** — once the overlay is correct, the ext-proc should handle path rewrite, body rewrite, and credential injection natively
4. **If EnvoyFilter workaround is needed** — the path/body rewrite approach works; the remaining gap is credential forwarding, which may need an additional `requestHeadersToAdd` or a fix to the Istio outbound configuration
5. **Policy deployment** — once a working workaround or fix is confirmed, deploy via ACM policy (`hub/platform/20-external-model-rewrite-policy.yaml`)
