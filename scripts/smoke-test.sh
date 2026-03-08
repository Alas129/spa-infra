#!/bin/bash
set -euo pipefail

TARGET_IP="$1"
BASE_URL="http://${TARGET_IP}"
MAX_RETRIES=30
RETRY_INTERVAL=10

echo "============================================"
echo "  Smoke Tests against ${BASE_URL}"
echo "============================================"

# Wait for the app to be ready
echo ""
echo "[WAIT] Waiting for app to become ready..."
for i in $(seq 1 "$MAX_RETRIES"); do
  if curl -sf "${BASE_URL}/api/health" > /dev/null 2>&1; then
    echo "[READY] App is responding."
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "[FAIL] App did not become ready after $((MAX_RETRIES * RETRY_INTERVAL))s"
    exit 1
  fi
  echo "  Attempt $i/$MAX_RETRIES — retrying in ${RETRY_INTERVAL}s..."
  sleep "$RETRY_INTERVAL"
done

PASS=0
FAIL=0

# Test 1: Frontend returns 200
echo ""
echo "[TEST 1] Frontend serves index page"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Test 2: API health endpoint returns 200
echo ""
echo "[TEST 2] API health endpoint"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/health")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Test 3: API health reports DB connected
echo ""
echo "[TEST 3] Database connectivity via health endpoint"
RESPONSE=$(curl -sf "${BASE_URL}/api/health" || echo '{}')
if echo "$RESPONSE" | grep -q '"db".*"connected"'; then
  echo "  PASS — DB is connected"
  PASS=$((PASS + 1))
else
  echo "  FAIL — DB not connected. Response: $RESPONSE"
  FAIL=$((FAIL + 1))
fi

# Test 4: API items endpoint returns 200
echo ""
echo "[TEST 4] API items endpoint"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/items")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Summary
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo "Smoke tests FAILED."
  exit 1
fi

echo "All smoke tests PASSED."
exit 0
