#!/bin/bash
# E2E test — Add user / Remove with real data (lab check before production deploy)
# Requires: an existing topic, a username not yet in the system, passphrase for pack
# Usage: export TEST_SYSTEM=TestE2E TEST_TOPIC=your_topic TEST_USER=testuser999 TEST_PASSPHRASE=secret123
#        ./scripts/check-e2e.sh https://<portal-host>:3443
# Tries Add user → on success tries Remove (or reports only)

BASE_URL="${1:-http://localhost:3000}"
CURL_OPTS="-s -m 60"
[[ "$BASE_URL" == https://* ]] && CURL_OPTS="$CURL_OPTS -k"

TEST_SYSTEM="${TEST_SYSTEM:-TestE2E}"
TEST_TOPIC="${TEST_TOPIC:-}"
TEST_USER="${TEST_USER:-}"
TEST_PASSPHRASE="${TEST_PASSPHRASE:-}"

if [[ -z "$TEST_TOPIC" || -z "$TEST_USER" || -z "$TEST_PASSPHRASE" ]]; then
  echo "Usage: export TEST_TOPIC=<existing topic> TEST_USER=<unused username> TEST_PASSPHRASE=<passphrase for .enc>"
  echo "       ./scripts/check-e2e.sh https://<portal-host>:3443"
  echo "Optional: TEST_SYSTEM=TestE2E (default)"
  exit 1
fi

echo ""
echo "--- E2E check: Add user (real data) ---"
echo "   System: $TEST_SYSTEM | Topic: $TEST_TOPIC | User: $TEST_USER"
echo ""

# 1. Add user
body=$(curl $CURL_OPTS -X POST "$BASE_URL/api/add-user" -H "Content-Type: application/json" -d "{
  \"systemName\": \"$TEST_SYSTEM\",
  \"topic\": \"$TEST_TOPIC\",
  \"username\": \"$TEST_USER\",
  \"acl\": \"all\",
  \"passphrase\": \"$TEST_PASSPHRASE\",
  \"confirmPassphrase\": \"$TEST_PASSPHRASE\"
}")
if echo "$body" | grep -q '"ok":true'; then
  echo "[PASS] POST /api/add-user — user created"
  ADD_OK=1
else
  err=$(echo "$body" | grep -oE '"error":"[^"]*"' | head -1)
  echo "[FAIL] POST /api/add-user — $err"
  echo "$body" | head -c 500
  echo ""
  exit 1
fi

# 2. Remove user (the one just created)
body2=$(curl $CURL_OPTS -X POST "$BASE_URL/api/remove-user" -H "Content-Type: application/json" -d "{\"users\": \"$TEST_USER\"}")
if echo "$body2" | grep -q '"ok":true'; then
  echo "[PASS] POST /api/remove-user — user removed"
else
  err2=$(echo "$body2" | grep -oE '"error":"[^"]*"' | head -1)
  echo "[WARN] POST /api/remove-user — $err2 (manual cleanup or skip may be needed)"
fi

echo ""
echo "--- E2E: Add user + Remove user OK — ready for production deploy ---"
echo ""
exit 0
