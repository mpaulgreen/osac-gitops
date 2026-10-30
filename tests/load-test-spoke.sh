#!/bin/bash
# Load test: spoke local model (granite-3.1-8b-instruct-fp8)
# Uses enterprise subscription (100k tokens/min)
#
# Usage:
#   bash tests/load-test-spoke.sh
#   CONCURRENCY=10 TOTAL_REQUESTS=100 bash tests/load-test-spoke.sh
set -euo pipefail

CONCURRENCY=${CONCURRENCY:-3}
TOTAL_REQUESTS=${TOTAL_REQUESTS:-50}
MAX_TOKENS=${MAX_TOKENS:-30}
PROMPT=${PROMPT:-"Explain the theory of relativity in simple terms"}

HUB_DOMAIN="${HUB_DOMAIN:-apps.hub.kni.syseng.devcluster.openshift.com}"
SPOKE_DOMAIN="${SPOKE_DOMAIN:-apps.osacmaas.kni.syseng.devcluster.openshift.com}"
KC_HOST="${KC_HOST:-keycloak-maas-db.${HUB_DOMAIN}}"
MODEL="publishers/ai-grid-internal-models/models/granite-3.1-8b-instruct-fp8"

RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$RESULTS_DIR"' EXIT

echo "=== Spoke Load Test ==="
echo "Model:    granite-3.1-8b-instruct-fp8"
echo "Requests: $TOTAL_REQUESTS (concurrency: $CONCURRENCY)"
echo "Tokens:   max $MAX_TOKENS per request"
echo ""

# --- 1. Get JWT from hub Keycloak ---
echo "Getting JWT from hub Keycloak (novatech-enterprise)..."
TOKEN=$(curl -sk "https://${KC_HOST}/realms/saas/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=tenant-demo&username=novatech-enterprise&password=password123' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
  echo "FATAL: Failed to get JWT" >&2
  exit 1
fi
echo "JWT: ${TOKEN:0:20}..."

# --- 2. Mint API key on spoke ---
echo "Minting API key on spoke..."
API_KEY=$(curl -sk -X POST "https://maas.${SPOKE_DOMAIN}/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"loadtest-$(date +%s)\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('key',''))")

if [ -z "$API_KEY" ] || [ "$API_KEY" = "None" ]; then
  echo "FATAL: Failed to mint API key" >&2
  exit 1
fi
echo "API key: ${API_KEY:0:15}..."
echo ""

# --- 3. Single request function ---
send_request() {
  local i=$1
  local outfile="${RESULTS_DIR}/${i}.json"
  local http_code
  http_code=$(curl -sk --max-time 120 -o "$outfile" -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    "https://maas.${SPOKE_DOMAIN}/v1/completions" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"max_tokens\":${MAX_TOKENS}}")

  local tokens=0 latency=0
  if [ "$http_code" = "200" ]; then
    tokens=$(python3 -c "import json; d=json.load(open('$outfile')); print(d.get('usage',{}).get('total_tokens',0))" 2>/dev/null || echo 0)
  fi

  echo "${i},${http_code},${tokens}" > "${RESULTS_DIR}/${i}.csv"
  echo "  [${i}/${TOTAL_REQUESTS}] HTTP ${http_code}  tokens=${tokens}"
}
export -f send_request
export RESULTS_DIR API_KEY SPOKE_DOMAIN MODEL PROMPT MAX_TOKENS TOTAL_REQUESTS

# --- 4. Run load test ---
START_TIME=$(date +%s)
echo "Sending $TOTAL_REQUESTS requests (concurrency=$CONCURRENCY)..."
echo ""
seq 1 "$TOTAL_REQUESTS" | xargs -P "$CONCURRENCY" -I{} bash -c 'send_request {}'
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# --- 5. Aggregate results ---
echo ""
echo "=== Results ==="

total=0; ok=0; fail=0; rate_limited=0; total_tokens=0
for f in "$RESULTS_DIR"/*.csv; do
  [ -f "$f" ] || continue
  IFS=',' read -r idx code tokens < "$f"
  total=$((total + 1))
  if [ "$code" = "200" ]; then
    ok=$((ok + 1))
    total_tokens=$((total_tokens + tokens))
  elif [ "$code" = "429" ]; then
    rate_limited=$((rate_limited + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "Total requests:  $total"
echo "Successful:      $ok"
echo "Rate limited:    $rate_limited"
echo "Failed:          $fail"
echo "Total tokens:    $total_tokens"
echo "Duration:        ${ELAPSED}s"
if [ "$ok" -gt 0 ]; then
  avg_tokens=$((total_tokens / ok))
  echo "Avg tokens/req:  $avg_tokens"
fi
if [ "$ELAPSED" -gt 0 ]; then
  rps=$(python3 -c "print(f'{$total/$ELAPSED:.1f}')")
  echo "Throughput:      ${rps} req/s"
fi
echo ""

if [ "$fail" -gt 0 ]; then
  echo "=== Failed Requests ==="
  for f in "$RESULTS_DIR"/*.csv; do
    IFS=',' read -r idx code tokens < "$f"
    if [ "$code" != "200" ] && [ "$code" != "429" ]; then
      echo "  Request $idx: HTTP $code"
      cat "${RESULTS_DIR}/${idx}.json" 2>/dev/null | head -1
    fi
  done
  echo ""
fi

echo "=== Load test complete ==="
