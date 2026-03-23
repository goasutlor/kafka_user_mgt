#!/bin/bash
# Smoke test — call API from CLI (lab check that server is up and accepts requests)
# Usage: ./scripts/smoke-test.sh [BASE_URL]
# Example: ./scripts/smoke-test.sh https://10.235.160.31
#          ./scripts/smoke-test.sh http://localhost:3000

BASE_URL="${1:-http://localhost:3000}"
# Use -k for self-signed certs
CURL_OPTS="-s -m 10"
[[ "$BASE_URL" == https://* ]] && CURL_OPTS="$CURL_OPTS -k"

echo "Smoke test: $BASE_URL"
echo "---"

echo "1. GET /api/config"
res=$(curl $CURL_OPTS -w "\n%{http_code}" "$BASE_URL/api/config")
body=$(echo "$res" | head -n -1)
code=$(echo "$res" | tail -n 1)
echo "   HTTP $code"
echo "$body" | head -c 200
echo ""
if [[ "$code" != "200" ]]; then echo "   FAIL"; exit 1; fi
echo "   OK"
echo ""

echo "2. POST /api/add-user (empty body — expect 400)"
res=$(curl $CURL_OPTS -w "\n%{http_code}" -X POST "$BASE_URL/api/add-user" -H "Content-Type: application/json" -d '{}')
code=$(echo "$res" | tail -n 1)
echo "   HTTP $code"
if [[ "$code" != "400" ]]; then echo "   (expected 400)"; fi
echo "   OK if server responded"
echo ""

echo "Done. Server is up and accepting requests."
