# Local Model Inference Testing

Manual tests for local model inference on each site with subscription
validation and rate-limit verification.

## Quick Reference

| | Site-a (hub) | Site-b (spoke) |
|---|---|---|
| **MaaS endpoint** | `https://maas.${HUB_DOMAIN}` | `https://maas.${SPOKE_DOMAIN}` |
| **Local model** | `facebook-opt-125m` | `granite-3.1-8b-instruct-fp8` |
| **Model path** | `publishers/ai-grid-internal-models/models/facebook-opt-125m` | `publishers/ai-grid-internal-models/models/granite-3.1-8b-instruct-fp8` |
| **Free sub** | `novatech-free-subscription` (100 tokens/1m) | `novatech-free-subscription` (100 tokens/1m) |
| **Enterprise sub** | `novatech-enterprise-subscription` (100k tokens/1m) | `novatech-enterprise-subscription` (100k tokens/1m) |

### Users (all in hub Keycloak, realm `saas`, client `tenant-demo`)

| User | Password | Group | Subscription tier |
|------|----------|-------|-------------------|
| `novatech-enterprise` | `password123` | `novatech-enterprise-users` | Enterprise (100,000 tokens/1m) |
| `novatech-free` | `password123` | `novatech-free-users` | Free (100 tokens/1m) |
| `novatech-premium` | `password123` | `novatech-premium-users` | Premium (50,000 tokens/1m) |
| `novatech-admin` | `password123` | `novatech-platform-admins` | **None** — do not use for inference |

## Prerequisites

```bash
export HUB_DOMAIN="apps.hub.kni.syseng.devcluster.openshift.com"
export SPOKE_DOMAIN="apps.osacmaas.kni.syseng.devcluster.openshift.com"
export KC_HOST="keycloak-maas-db.${HUB_DOMAIN}"
```

> Keycloak runs on the hub only. All JWT tokens come from hub Keycloak
> regardless of which site you are testing.

---

## Site-a (Hub) — facebook-opt-125m

### Test 1: Get JWT Token

```bash
ENTERPRISE_TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=tenant-demo&username=novatech-enterprise&password=password123' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Enterprise JWT: ${ENTERPRISE_TOKEN:0:30}..."
```

**Pass**: A JWT string is returned (starts with `eyJ`).

### Test 2: Mint API Key

```bash
HUB_KEY=$(curl -sk -X POST "https://maas.${HUB_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $ENTERPRISE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"test-hub-$(date +%s)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")
echo "Hub API key: ${HUB_KEY:0:15}..."
```

**Pass**: An API key string is returned.

### Test 3: Enterprise Inference (expect 200)

```bash
HTTP=$(curl -sk --max-time 30 -o /tmp/hub_resp.json -w "%{http_code}" \
  -H "Authorization: Bearer $HUB_KEY" \
  -H "Content-Type: application/json" \
  "https://maas.${HUB_DOMAIN}/v1/completions" \
  -d '{"model":"publishers/ai-grid-internal-models/models/facebook-opt-125m",
       "prompt":"The capital of France is","max_tokens":10}')
echo "HTTP: $HTTP"
python3 -m json.tool /tmp/hub_resp.json
```

**Pass**: HTTP 200 with completion text and `usage.total_tokens > 0`.

### Test 4: Free-tier Rate Limiting (expect 429)

The free subscription allows 100 tokens per minute. Send requests with
`max_tokens:50` (~55 total tokens each) in rapid succession — the third
request should exceed the budget.

```bash
FREE_TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=tenant-demo&username=novatech-free&password=password123' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

FREE_KEY=$(curl -sk -X POST "https://maas.${HUB_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $FREE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"test-free-hub-$(date +%s)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

for i in 1 2 3; do
  echo "--- Request $i ---"
  HTTP=$(curl -sk --max-time 30 -o /tmp/hub_free_$i.json -w "%{http_code}" \
    -H "Authorization: Bearer $FREE_KEY" \
    -H "Content-Type: application/json" \
    "https://maas.${HUB_DOMAIN}/v1/completions" \
    -d '{"model":"publishers/ai-grid-internal-models/models/facebook-opt-125m",
         "prompt":"Write a long story about a brave knight who traveled across many lands","max_tokens":50}')
  echo "HTTP: $HTTP"
  cat /tmp/hub_free_$i.json; echo ""
done
```

**Pass**: First 1–2 requests return 200, then at least one returns HTTP 429
(rate limit exceeded).

---

## Site-b (Spoke) — granite-3.1-8b-instruct-fp8

### Test 5: Get JWT Token

```bash
ENTERPRISE_TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=tenant-demo&username=novatech-enterprise&password=password123' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Enterprise JWT: ${ENTERPRISE_TOKEN:0:30}..."
```

**Pass**: A JWT string is returned (starts with `eyJ`).

### Test 6: Mint API Key

```bash
SPOKE_KEY=$(curl -sk -X POST "https://maas.${SPOKE_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $ENTERPRISE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"test-spoke-$(date +%s)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")
echo "Spoke API key: ${SPOKE_KEY:0:15}..."
```

**Pass**: An API key string is returned.

### Test 7: Enterprise Inference (expect 200)

Granite runs on GPU and may take longer to respond than facebook-opt-125m.

```bash
HTTP=$(curl -sk --max-time 120 -o /tmp/spoke_resp.json -w "%{http_code}" \
  -H "Authorization: Bearer $SPOKE_KEY" \
  -H "Content-Type: application/json" \
  "https://maas.${SPOKE_DOMAIN}/v1/completions" \
  -d '{"model":"publishers/ai-grid-internal-models/models/granite-3.1-8b-instruct-fp8",
       "prompt":"The capital of France is","max_tokens":10}')
echo "HTTP: $HTTP"
python3 -m json.tool /tmp/spoke_resp.json
```

**Pass**: HTTP 200 with completion text and `usage.total_tokens > 0`.

### Test 8: Free-tier Rate Limiting (expect 429)

```bash
FREE_TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=tenant-demo&username=novatech-free&password=password123' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

FREE_KEY=$(curl -sk -X POST "https://maas.${SPOKE_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $FREE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"test-free-spoke-$(date +%s)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

for i in 1 2 3; do
  echo "--- Request $i ---"
  HTTP=$(curl -sk --max-time 120 -o /tmp/spoke_free_$i.json -w "%{http_code}" \
    -H "Authorization: Bearer $FREE_KEY" \
    -H "Content-Type: application/json" \
    "https://maas.${SPOKE_DOMAIN}/v1/completions" \
    -d '{"model":"publishers/ai-grid-internal-models/models/granite-3.1-8b-instruct-fp8",
         "prompt":"Write a long story about a brave knight who traveled across many lands","max_tokens":50}')
  echo "HTTP: $HTTP"
  cat /tmp/spoke_free_$i.json; echo ""
done
```

**Pass**: First 1–2 requests return 200, then at least one returns HTTP 429
(rate limit exceeded).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `"error":"Realm does not exist"` | Wrong realm name | Use `saas` (not `osac` or `maas`) |
| `"no matching subscription found for user"` (403) | User's group doesn't match any subscription | Use `novatech-free` or `novatech-enterprise`, not `novatech-admin` |
| Empty response / timeout on spoke | Granite GPU inference is slow | Increase `--max-time` to 120s+ |
| 401 on `/v1/api-keys` | JWT expired or wrong client_id | Re-fetch JWT; use `client_id=tenant-demo` |
| 200 on all 3 free-tier requests (no 429) | Rate limit window may have reset | Wait 1 minute, then retry all 3 requests within a few seconds |
| `granite-cross-cluster-sub` appears instead of local sub | Cross-cluster sub is for external models | Ignore it; local subs match by user group, not by name |
| API key mint returns `"no matching subscription"` | User has no subscription on that site | Check that the user's group matches a MaaSSubscription `owner.groups` on that site |

## Common Pitfalls

1. **Keycloak is hub-only.** Always get JWT from `${KC_HOST}` even when
   testing the spoke. There is no Keycloak on the spoke.

2. **`novatech-admin` cannot do inference.** It is in group
   `novatech-platform-admins` which has no matching MaaSSubscription on
   either site. Use `novatech-free` or `novatech-enterprise`.

3. **Cross-cluster subs are not for local models.** `facebook-cross-cluster-sub`
   (site-a) and `granite-cross-cluster-sub` (site-b) exist for cross-site
   external model access. They match `system:authenticated` and have
   effectively unlimited rate limits (999M tokens/1m). Local model testing
   must use the tiered subscriptions.

4. **Rate limits are per-token, not per-request.** The free tier allows
   100 tokens per minute. A request with `max_tokens:10` uses ~15 tokens
   total (prompt + completion). To trigger 429, use `max_tokens:50` and
   send 3+ requests in rapid succession.
