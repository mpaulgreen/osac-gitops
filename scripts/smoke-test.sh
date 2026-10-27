#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# OSAC GitOps — Smoke Test
#
# Verifies end-to-end MaaS functionality: Keycloak token exchange, API key
# minting, model inference, and rate limiting.
#
# Usage:
#   ./scripts/smoke-test.sh --domain <apps-domain> \
#     [--model <model-id>] [--realm <realm>] [--client-id <id>]
#
# Required:
#   --domain <domain>     The cluster's apps domain (e.g. apps.hub.example.com)
#
# Optional:
#   --model <model>       Model ID to test (default: facebook-opt-125m)
#   --realm <realm>       Keycloak realm (default: saas)
#   --client-id <id>      OIDC client ID (default: tenant-demo)
#   --username <user>     Keycloak username (default: novatech-free)
#   --password <pass>     Keycloak password (or set KC_PASS env var)
###############################################################################

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

domain=""
model="facebook-opt-125m"
realm="saas"
client_id="tenant-demo"
username="novatech-free"
password="${KC_PASS:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain) domain=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --realm) realm=$2; shift 2 ;;
    --client-id) client_id=$2; shift 2 ;;
    --username) username=$2; shift 2 ;;
    --password) password=$2; shift 2 ;;
    -h|--help) sed -n '3,/^###/{ /^#/s/^# \?//p }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$domain" ] || die "--domain is required"
[ -n "$password" ] || die "set KC_PASS or pass --password"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

MAAS_URL="https://maas.${domain}"
KC_URL="https://keycloak.${domain}"
TOKEN_URL="${KC_URL}/realms/${realm}/protocol/openid-connect/token"

printf '=== OSAC Smoke Test ===\n'
printf 'MaaS URL:  %s\n' "$MAAS_URL"
printf 'KC URL:    %s\n' "$KC_URL"
printf 'Model:     %s\n' "$model"
printf 'User:      %s\n\n' "$username"

# Step 1: Get JWT from Keycloak
printf '1. Getting JWT from Keycloak... '
JWT=$(curl -sk "$TOKEN_URL" \
  -d "grant_type=password" \
  -d "client_id=${client_id}" \
  -d "username=${username}" \
  -d "password=${password}" \
  -d "scope=openid" | jq -er '.access_token') || die "failed to get JWT"
printf 'OK\n'

# Step 2: Mint API key
printf '2. Minting API key... '
API_KEY=$(curl -sk "${MAAS_URL}/api/v1/api_keys" \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{"name": "smoke-test-key", "model_ids": ["'"$model"'"]}' | jq -er '.api_key') || die "failed to mint API key"
printf 'OK\n'

# Step 3: Run inference
printf '3. Running inference... '
RESPONSE=$(curl -sk "${MAAS_URL}/v1/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$model"'",
    "prompt": "Hello, world!",
    "max_tokens": 10
  }') || die "inference request failed"

# Check for a valid response
echo "$RESPONSE" | jq -e '.choices[0]' >/dev/null 2>&1 || die "unexpected inference response: $RESPONSE"
printf 'OK\n'

# Step 4: Test rate limiting (optional, informational)
printf '4. Testing rate limit (10 rapid requests)... '
rate_limited=false
for i in $(seq 1 10); do
  status=$(curl -sk -o /dev/null -w '%{http_code}' "${MAAS_URL}/v1/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"$model"'",
      "prompt": "Rate limit test",
      "max_tokens": 1
    }')
  if [ "$status" = "429" ]; then
    rate_limited=true
    break
  fi
done
if [ "$rate_limited" = true ]; then
  printf 'OK (429 after %s requests)\n' "$i"
else
  printf 'WARN (no 429 seen — rate limits may be high)\n'
fi

# Step 5: Clean up the API key
printf '5. Deleting smoke-test API key... '
curl -sk -X DELETE "${MAAS_URL}/api/v1/api_keys" \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{"name": "smoke-test-key"}' >/dev/null 2>&1 || true
printf 'OK\n'

printf '\n=== All smoke tests passed ===\n'
