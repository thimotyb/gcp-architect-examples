#!/usr/bin/env bash
# End-to-end test of the Orders API behind ESPv2.
#
#   GATEWAY_URL=https://...run.app API_KEY=... BACKEND_URL=https://...run.app ./test.sh
#
# Both deploy variants print these three values (gcloud/deploy.sh, terraform output).
# The API key is read from the environment and never written to disk.
set -uo pipefail

: "${GATEWAY_URL:?set GATEWAY_URL}" "${API_KEY:?set API_KEY}" "${BACKEND_URL:?set BACKEND_URL}"

pass=0; fail=0
check() {  # check <description> <expected status> <actual status>
  if [[ "$2" == "$3" ]]; then echo "PASS  $1 ($3)"; pass=$((pass + 1))
  else echo "FAIL  $1: expected $2, got $3"; fail=$((fail + 1)); fi
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# A new API key can take a few minutes to become valid: wait for it.
for i in $(seq 1 30); do
  code=$(status "$GATEWAY_URL/orders?key=$API_KEY")
  [[ "$code" == 200 ]] && break
  echo "waiting for the API key to become active ($code)..."; sleep 10
done

check "GET / without key (security: [])"             200 "$(status "$GATEWAY_URL/")"
check "GET /orders without key is rejected by ESPv2" 401 "$(status "$GATEWAY_URL/orders")"
check "GET /orders with a wrong key"                 400 "$(status "$GATEWAY_URL/orders?key=not-a-key")"
check "GET /orders with key"                         200 "$(status "$GATEWAY_URL/orders?key=$API_KEY")"
check "GET /orders/1001 with key"                    200 "$(status "$GATEWAY_URL/orders/1001?key=$API_KEY")"
check "GET /orders/9999: backend 404 passes through" 404 "$(status "$GATEWAY_URL/orders/9999?key=$API_KEY")"
check "GET /docs: path not in the OpenAPI document"  404 "$(status "$GATEWAY_URL/docs?key=$API_KEY")"
check "Backend called directly without a token"      403 "$(status "$BACKEND_URL/orders")"

echo "--- body of GET /orders/1001"
curl -s "$GATEWAY_URL/orders/1001?key=$API_KEY"; echo

# Quota: 10 write calls per minute per consumer project. Keep writing until ESPv2 answers 429.
# Quota is checked in aggregate and enforced with some delay: expect 10 to 20 calls to pass.
order='{"customer":"Maria Verdi","lines":[{"sku":"PEN-1","quantity":4,"unit_price":2.5}]}'
codes=""
for i in $(seq 1 30); do
  code=$(status -X POST -H 'content-type: application/json' -d "$order" "$GATEWAY_URL/orders?key=$API_KEY")
  codes+="$code "
  [[ "$code" == 429 ]] && break
done
echo "POST /orders status codes: $codes"
check "POST /orders first call" 201 "${codes%% *}"
check "Quota exceeded within 30 writes" 429 "$code"

echo "--- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
