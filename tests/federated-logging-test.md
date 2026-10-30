# Federated Logging — Manual Test Runbook

**Pipeline**: Centralized Loki usage-log aggregation  
**Branch**: `feature/rhoai-3.6`  
**Date**: 2026-10-30  

---

## Prerequisites

```bash
export HUB_CTX="default/api-hub-kni-syseng-devcluster-openshift-com:6443/kube:admin"
export SPOKE_CTX="default/api-osacmaas-kni-syseng-devcluster-openshift-com:6443/kube:admin"
export HUB_DOMAIN="apps.hub.kni.syseng.devcluster.openshift.com"
export SPOKE_DOMAIN="apps.osacmaas.kni.syseng.devcluster.openshift.com"
export KC_HOST="keycloak-maas-db.${HUB_DOMAIN}"
```

Required tools: `oc`, `curl`, `jq`, `python3`

---

## Part A — Infrastructure Readiness

### Test 1: ACM Policy Compliance

```bash
oc get policy -n osac-platform --context=$HUB_CTX \
  -l 'osac.io/platform=true' \
  -o custom-columns='NAME:.metadata.name,COMPLIANT:.status.compliant' \
  | grep -E 'osac-logging|osac-loki-operator|osac-observability|osac-hub-secret-mirror'
```

**Pass**: All four policies show `Compliant`.

### Test 2: Loki Operator

```bash
# Subscription health (use OLM API group, not ACM)
oc get subscription.operators.coreos.com loki-operator -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='{.status.state}{"\n"}'

# CSV phase
oc get csv -n openshift-logging --context=$HUB_CTX \
  -l operators.coreos.com/loki-operator.openshift-logging \
  -o jsonpath='{.items[0].status.phase}{"\n"}'

# Operator pod
oc get pods -n openshift-logging --context=$HUB_CTX \
  -l name=loki-operator-controller-manager --no-headers
```

**Pass**: State is `AtLatestKnown`, CSV phase is `Succeeded`, operator pod is `Running`.

### Test 3: OBC & S3 Storage

```bash
# OBC bound
oc get objectbucketclaim loki-usage-logs -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='{.status.phase}{"\n"}'

# S3 Secret key names
oc get secret logging-loki-s3 -n openshift-logging --context=$HUB_CTX \
  -o json | python3 -c "import sys,json; print(sorted(json.load(sys.stdin)['data'].keys()))"
```

**Pass**: OBC phase is `Bound`. Secret has 5 keys: `['access_key_id', 'access_key_secret', 'bucketnames', 'endpoint', 'region']`.

### Test 4: LokiStack Health

```bash
# CR readiness
oc get lokistack usage-logs -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

# All component pods
oc get pods -n openshift-logging --context=$HUB_CTX \
  -l app.kubernetes.io/instance=usage-logs --no-headers
```

**Pass**: Ready condition is `True`. Pods for compactor, distributor, gateway, ingester, querier, and query-frontend are all `Running`.

### Test 5: LokiStack Gateway Route

```bash
# Route exists and is admitted
oc get route usage-logs-gateway -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='host={.spec.host} tls={.spec.tls.termination}{"\n"}'

# Route is reachable (expect 401 without auth, not 404/503)
ROUTE_HOST=$(oc get route usage-logs-gateway -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "%{http_code}\n" "https://${ROUTE_HOST}/api/logs/v1/application/otlp/v1/logs"
```

**Pass**: Route has `tls=reencrypt`. Curl returns `401` (auth required, but endpoint exists).

### Test 6: Writer RBAC

```bash
# ServiceAccount
oc get sa usage-log-writer -n openshift-logging --context=$HUB_CTX -o name

# Token Secret
oc get secret usage-log-writer-token -n openshift-logging --context=$HUB_CTX -o name

# ClusterRole verbs
oc get clusterrole logging-collector-logs-writer --context=$HUB_CTX \
  -o jsonpath='{.rules[0].verbs[*]}{"\n"}'

# ClusterRoleBinding
oc get clusterrolebinding usage-log-writer --context=$HUB_CTX \
  -o jsonpath='role={.roleRef.name} sa={.subjects[0].namespace}/{.subjects[0].name}{"\n"}'
```

**Pass**: SA exists. Token Secret exists. ClusterRole has verbs `create get`. CRB binds `logging-collector-logs-writer` to `openshift-logging/usage-log-writer`.

### Test 7: Hub-config Distribution

```bash
# Hub
oc get secret usage-log-hub-config -n redhat-ods-applications --context=$HUB_CTX \
  -o jsonpath='{.data}' | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for k in sorted(d):
    v = base64.b64decode(d[k]).decode()
    print(f'{k} = {v[:60]}...' if len(v)>60 else f'{k} = {v}')
"

# Spoke
oc get secret usage-log-hub-config -n redhat-ods-applications --context=$SPOKE_CTX \
  -o jsonpath='{.data}' | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for k in sorted(d):
    v = base64.b64decode(d[k]).decode()
    print(f'{k} = {v[:60]}...' if len(v)>60 else f'{k} = {v}')
"
```

**Pass**: Both clusters have `gateway_url` (starts with `https://`) and `token` (non-empty JWT).

### Test 8: OTel Collector

```bash
# Hub
oc get pods -l app.kubernetes.io/name=usage-logs-collector \
  -n redhat-ods-applications --context=$HUB_CTX --no-headers

# Spoke
oc get pods -l app.kubernetes.io/name=usage-logs-collector \
  -n redhat-ods-applications --context=$SPOKE_CTX --no-headers
```

**Pass**: One pod `Running` on each cluster.

### Test 9: ExternalName Service Bridge

```bash
# Hub
oc get service data-science-usage-logs-collector -n redhat-ods-monitoring --context=$HUB_CTX \
  -o jsonpath='type={.spec.type} target={.spec.externalName}{"\n"}'

# Spoke
oc get service data-science-usage-logs-collector -n redhat-ods-monitoring --context=$SPOKE_CTX \
  -o jsonpath='type={.spec.type} target={.spec.externalName}{"\n"}'
```

**Pass**: Both show `type=ExternalName target=usage-logs-collector.redhat-ods-applications.svc.cluster.local`.

### Test 10: EnvoyFilter

```bash
# Hub
oc get envoyfilter maas-model-access-logs -n openshift-ingress --context=$HUB_CTX -o name

# Spoke
oc get envoyfilter maas-model-access-logs -n openshift-ingress --context=$SPOKE_CTX -o name
```

**Pass**: EnvoyFilter exists on both clusters. (This is managed by the MaaS controller, not git-managed.)

---

## Part B — Dashboard Data Validation (RHOAI Usage Dashboard)

### Test 11: Generate Traffic

```bash
# 1. Get JWT from hub Keycloak
TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=tenant-demo \
  -d username=novatech-admin -d password=password123 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "JWT: ${TOKEN:0:30}..."

# 2. Mint API key on hub
HUB_KEY=$(curl -sk -X POST "https://maas.${HUB_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"logtest-hub-$(date +%s)\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
echo "Hub API key: ${HUB_KEY:0:15}..."

# 3. Hub inference (facebook-opt-125m)
echo "--- Hub inference ---"
curl -sk -H "Authorization: Bearer $HUB_KEY" -H "Content-Type: application/json" \
  "https://maas.${HUB_DOMAIN}/v1/completions" \
  -d '{"model":"publishers/ai-grid-internal-models/models/facebook-opt-125m",
       "prompt":"The capital of France is","max_tokens":10}' \
  | python3 -m json.tool

# 4. Mint API key on spoke
SPOKE_KEY=$(curl -sk -X POST "https://maas.${SPOKE_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"logtest-spoke-$(date +%s)\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
echo "Spoke API key: ${SPOKE_KEY:0:15}..."

# 5. Spoke inference (granite-3-1-8b-fp8)
echo "--- Spoke inference ---"
curl -sk -H "Authorization: Bearer $SPOKE_KEY" -H "Content-Type: application/json" \
  "https://maas.${SPOKE_DOMAIN}/v1/completions" \
  -d '{"model":"publishers/ai-grid-internal-models/models/granite-3.1-8b-instruct-fp8",
       "prompt":"The capital of France is","max_tokens":10}' \
  | python3 -m json.tool
```

**Pass**: Both inference calls return HTTP 200 with completion text.

### Test 12: Collector Health

Wait 15 seconds for the OTel batch flush, then check for export errors.

```bash
sleep 15

# Hub collector errors
echo "--- Hub collector ---"
oc logs -l app.kubernetes.io/name=usage-logs-collector \
  -n redhat-ods-applications --context=$HUB_CTX --tail=20 2>&1 \
  | grep -E 'error.*Exporting|dropped_items|404|403' || echo "(no export errors)"

# Spoke collector errors
echo "--- Spoke collector ---"
oc logs -l app.kubernetes.io/name=usage-logs-collector \
  -n redhat-ods-applications --context=$SPOKE_CTX --tail=20 2>&1 \
  | grep -E 'error.*Exporting|dropped_items|404|403' || echo "(no export errors)"
```

**Pass**: No export errors on either cluster.

### Test 13: Basic Log Presence

Query the hub LokiStack via `oc exec` into a querier pod (mTLS).
The gateway uses OIDC session cookies for reads — bearer tokens are not
accepted for read queries in `openshift-logging` mode. Querying from
inside the cluster with the querier pod's own TLS certs bypasses this.

> **Important**: OTLP attributes (`service_name`, `model`, `subscription`,
> etc.) are stored as **structured metadata**, not indexed stream labels.
> Only `log_type` and `openshift_log_source` are indexed. Use
> `{log_type="application"} | service_name = "..."` syntax, not
> `{service_name="..."}`.
>
> Use `query_range` with an explicit 24 h time window — the default
> instant-query window is too narrow.

```bash
QUERIER=$(oc get pods -n openshift-logging --context=$HUB_CTX \
  -l app.kubernetes.io/component=querier,app.kubernetes.io/instance=usage-logs \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
QF="https://usage-logs-query-frontend-http.openshift-logging.svc.cluster.local:3100"
NOW=$(date +%s); START=$((NOW - 86400))

oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -m json.tool
```

**Pass**: Response contains `"resultType": "streams"` with at least one entry.

### Test 14: Per-Model Usage

Verify both models appear in the logs. Uses the same querier pod exec
approach as Test 13.

```bash
# facebook-opt-125m (hub model)
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | model = "facebook-opt-125m"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
entries = sum(len(s.get('values',[])) for s in streams)
print(f'facebook-opt-125m: {len(streams)} stream(s), {entries} entries')
"

# granite (spoke model)
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | model =~ ".*granite.*"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
entries = sum(len(s.get('values',[])) for s in streams)
print(f'granite: {len(streams)} stream(s), {entries} entries')
"
```

**Pass**: Both queries return at least 1 stream.

### Test 15: Per-Tenant Usage

Verify subscription and organization fields are populated.

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | subscription != "" | subscription != "-"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
for s in r.get('data',{}).get('result',[]):
    labels = s.get('stream',{})
    print(f'subscription={labels.get(\"subscription\",\"??\")}  org={labels.get(\"organization_id\",\"??\")}')
"
```

**Pass**: At least one entry shows a non-empty `subscription`.

### Test 16: Token Consumption

Verify token count fields are present and non-zero.

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | tokens_total != "0"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
for s in r.get('data',{}).get('result',[]):
    labels = s.get('stream',{})
    print(f'total={labels.get(\"tokens_total\",\"??\")}  prompt={labels.get(\"tokens_prompt\",\"??\")}  completion={labels.get(\"tokens_completion\",\"??\")}')
"
```

**Pass**: At least one entry shows non-zero `tokens_total`.

### Test 17: Response Classification

Verify `response_type` is populated with valid values.

```bash
# Check for "hit" responses
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | response_type = "hit"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
entries = sum(len(s.get('values',[])) for s in streams)
print(f'hit: {len(streams)} stream(s), {entries} entries')
"

# Check for "error" responses
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service" | response_type = "error"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
entries = sum(len(s.get('values',[])) for s in streams)
print(f'error: {len(streams)} stream(s), {entries} entries')
"
```

**Pass**: Values are from `{hit, error, stream, miss}`.

### Test 18: Multi-cluster Aggregation

Verify logs from both hub and spoke inference arrive at the hub LokiStack.

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query_range" \
    --data-urlencode 'query={log_type="application"} | service_name = "models-as-a-service"' \
    --data-urlencode "start=${START}000000000" \
    --data-urlencode "end=${NOW}000000000" \
    --data-urlencode 'limit=20' | python3 -c "
import sys, json
r = json.load(sys.stdin)
hosts = set()
models = set()
for s in r.get('data',{}).get('result',[]):
    labels = s.get('stream',{})
    h = labels.get('upstream_host','')
    m = labels.get('model','')
    if h: hosts.add(h)
    if m: models.add(m)
print(f'upstream_hosts: {sorted(hosts)}')
print(f'models: {sorted(models)}')
"
```

**Pass**: At least two distinct `upstream_host` values appear (hub and spoke backends), and both `facebook-opt-125m` and `granite*` models are present.

> **Note**: Spoke logs only appear if spoke inference returns 200 (a valid
> subscription is required). If the spoke user has no active subscription,
> only hub data will be present — this is expected and does not indicate a
> pipeline failure.

### Test 19: Dashboard Panel Queries

These are the LogQL queries that power key RHOAI usage dashboard panels.
Run them as metric queries via the query-frontend. These use instant
`query` (not `query_range`) since `count_over_time` aggregates internally.

#### Total requests by model

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query" \
    --data-urlencode 'query=sum by (model) (count_over_time({log_type="application"} | service_name = "models-as-a-service" [24h]))' \
    --data-urlencode "time=${NOW}" | python3 -m json.tool
```

**Pass**: Returns a vector result with per-model request counts.

#### Token usage by subscription

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query" \
    --data-urlencode 'query=sum by (subscription) (count_over_time({log_type="application"} | service_name = "models-as-a-service" | subscription != "-" [24h]))' \
    --data-urlencode "time=${NOW}" | python3 -m json.tool
```

**Pass**: Returns a vector result with per-subscription counts.

#### Response type breakdown

```bash
oc exec "$QUERIER" -c loki-querier -n openshift-logging --context=$HUB_CTX -- \
  curl -s \
    --cacert /var/run/ca/service-ca.crt \
    --cert /var/run/tls/http/server/tls.crt \
    --key /var/run/tls/http/server/tls.key \
    -H 'X-Scope-OrgID: application' \
    -G "${QF}/loki/api/v1/query" \
    --data-urlencode 'query=sum by (response_type) (count_over_time({log_type="application"} | service_name = "models-as-a-service" [24h]))' \
    --data-urlencode "time=${NOW}" | python3 -m json.tool
```

**Pass**: Returns a vector with counts grouped by `hit`, `error`, `stream`, or `miss`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No logs in LokiStack | Check OTel collector logs for export errors (Test 12) |
| Collector returns 404 | Verify `gateway_url` in `usage-log-hub-config` ends with `/otlp/v1/logs` |
| Collector returns 403 | Verify ClusterRole has `create` + `get` verbs (Test 6) |
| LokiStack returns 400 | Verify OTel resource processor sets `log_type` and `openshift.log.source` |
| Missing `subscription`/`model` fields | Verify EnvoyFilter `maas-model-access-logs` is present (Test 10) |
| Spoke logs not arriving at hub | Verify `usage-log-hub-config` Secret exists on spoke (Test 7) |
| `unwrap` queries return empty | Structured metadata fields may be strings — check Loki OTLP config |
| Bearer token "failed to find token" | Gateway uses OIDC session cookies for reads, not bearer tokens. Use mTLS via querier pod exec instead |
| `{service_name="..."}` returns 0 results | `service_name` is structured metadata, not an indexed label. Use `{log_type="application"} \| service_name = "..."` |
| Queries succeed but return empty results | Default instant query window is too narrow. Use `query_range` with explicit 24 h `start`/`end` timestamps |
| `tls: certificate required` via API proxy | Port 3100 requires mutual TLS. Exec into querier pod which has the certs |
| Spoke inference returns 401/403 | Spoke user needs an active MaaS subscription (Grid enrollment) |

---

## Test Results — 2026-10-30

Tested against hub `api-hub.kni-syseng.devcluster.openshift.com` and
spoke `api-osacmaas.kni-syseng.devcluster.openshift.com`, RHOAI 3.6.

### Part A — Infrastructure Readiness

| # | Test | Result | Notes |
|---|------|--------|-------|
| 1 | ACM Policy Compliance | **PASS** | All 4 logging policies Compliant |
| 2 | Loki Operator | **PASS** | Subscription, CSV, operator pod all healthy |
| 3 | OBC & S3 | **PASS** | OBC Bound, all 5 keys present in secret |
| 4 | LokiStack | **WARN** | `ingester-2` Pending (resource constraint); other pods Ready |
| 5 | Gateway Route | **PASS** | Route admitted, curl returns 401 (auth required) |
| 6 | Writer RBAC | **PASS** | SA, token, ClusterRole, CRB all present |
| 7 | Hub-config Distribution | **PASS** | Secret exists on both hub and spoke |
| 8 | OTel Collector | **PASS** | Collector pod running in `redhat-ods-applications` |
| 9 | ExternalName Bridge | **PASS** | Service type ExternalName, correct target |
| 10 | EnvoyFilter | **PASS** | `maas-model-access-logs` present in `openshift-ingress` |

### Part B — Dashboard Data Validation

| # | Test | Result | Notes |
|---|------|--------|-------|
| 11 | Traffic Generation | **PARTIAL** | Hub: 200 OK (facebook-opt-125m). Spoke: 401/403 (no active subscription for novatech-admin) |
| 12 | Collector Health | **PASS** | 0 export errors. Metrics: 2 received, 2 sent, 0 failed |
| 13 | Basic Log Presence | **PASS** | 3 streams, 5 entries |
| 14 | Per-Model Usage | **PASS** | facebook-opt-125m: 1 entry. granite: 4 entries (401/403 errors) |
| 15 | Per-Tenant Usage | **PASS** | subscription=facebook-cross-cluster-sub |
| 16 | Token Consumption | **PASS** | tokens_total=16, prompt=6, completion=10 |
| 17 | Response Classification | **PASS** | hit: 1 entry, error: 4 entries |
| 18 | Multi-cluster Aggregation | **PARTIAL** | Hub data only. Spoke MaaS returns 403 — no subscription for novatech-admin |
| 19 | Dashboard Panel Queries | **PASS** | All 3 panel queries return data |

### Summary

- **15 PASS**, **1 WARN**, **2 PARTIAL**, **0 FAIL**
- Pipeline is end-to-end functional: EnvoyFilter ALS → OTel Collector → LokiStack gateway → Loki storage
- WARN (Test 4): `ingester-2` Pending is a resource constraint, not a pipeline defect
- PARTIAL (Tests 11, 18): Spoke inference returns 401/403 because `novatech-admin` lacks an active MaaS subscription on spoke. This is a Grid enrollment gap, not a logging pipeline issue. Once spoke subscriptions are provisioned, spoke logs will flow through the same pipeline
