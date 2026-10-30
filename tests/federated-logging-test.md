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
# Subscription health
oc get subscription loki-operator -n openshift-logging --context=$HUB_CTX \
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

# S3 Secret has all required keys
oc get secret logging-loki-s3 -n openshift-logging --context=$HUB_CTX \
  -o jsonpath='{range .data}{@}{"\n"}{end}' | wc -l
```

**Pass**: OBC phase is `Bound`. Secret has 5 keys (`access_key_id`, `access_key_secret`, `bucketnames`, `endpoint`, `region`).

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

Query the hub LokiStack for any usage logs.

```bash
QF_POD=$(oc get pod \
  -l app.kubernetes.io/component=query-frontend,app.kubernetes.io/instance=usage-logs \
  -n openshift-logging --context=$HUB_CTX -o jsonpath='{.items[0].metadata.name}')

oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"}' \
  --data-urlencode 'limit=5' | python3 -m json.tool
```

**Pass**: Response contains `"resultType": "streams"` with at least one entry.

### Test 14: Per-Model Usage

Verify both models appear in the logs.

```bash
# facebook-opt-125m (hub model)
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"} | model="facebook-opt-125m"' \
  --data-urlencode 'limit=3' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
print(f'facebook-opt-125m: {len(streams)} stream(s)')
"

# granite (spoke model)
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"} | model=~"granite.*"' \
  --data-urlencode 'limit=3' | python3 -c "
import sys, json
r = json.load(sys.stdin)
streams = r.get('data',{}).get('result',[])
print(f'granite: {len(streams)} stream(s)')
"
```

**Pass**: Both queries return at least 1 stream.

### Test 15: Per-Tenant Usage

Verify subscription and organization fields are populated.

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"} | subscription!=""' \
  --data-urlencode 'limit=3' | python3 -c "
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
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"} | tokens_total!=""' \
  --data-urlencode 'limit=3' | python3 -c "
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
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"} | response_type!=""' \
  --data-urlencode 'limit=5' | python3 -c "
import sys, json
r = json.load(sys.stdin)
types = set()
for s in r.get('data',{}).get('result',[]):
    t = s.get('stream',{}).get('response_type','')
    if t: types.add(t)
print(f'response_types seen: {sorted(types)}')
"
```

**Pass**: Values are from `{hit, stream, miss}`.

### Test 18: Multi-cluster Aggregation

Verify logs from both hub and spoke inference arrive at the hub LokiStack.

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="models-as-a-service"}' \
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

### Test 19: Dashboard Panel Queries

These are the LogQL queries that power key RHOAI usage dashboard panels. Run them via the query-frontend to verify dashboard readiness.

#### Total requests by model

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (model) (count_over_time({service_name="models-as-a-service"}[1h]))' \
  | python3 -m json.tool
```

**Pass**: Returns a vector result with per-model request counts.

#### Token usage by subscription

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (subscription) (sum_over_time({service_name="models-as-a-service"} | unwrap tokens_total [1h]))' \
  | python3 -m json.tool
```

**Pass**: Returns a vector result with per-subscription token totals.

#### Response type breakdown

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (response_type) (count_over_time({service_name="models-as-a-service"}[1h]))' \
  | python3 -m json.tool
```

**Pass**: Returns a vector with counts grouped by `hit`, `stream`, or `miss`.

#### Prompt vs completion token split by model

```bash
oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (model) (sum_over_time({service_name="models-as-a-service"} | unwrap tokens_prompt [1h]))' \
  | python3 -m json.tool

oc exec "$QF_POD" -n openshift-logging --context=$HUB_CTX -- \
  curl -s 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (model) (sum_over_time({service_name="models-as-a-service"} | unwrap tokens_completion [1h]))' \
  | python3 -m json.tool
```

**Pass**: Both return vector results with non-zero values.

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
