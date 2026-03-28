#!/usr/bin/env bash
# tests/e2e-webhook-bridge.sh — E2E test: webhook bridge links commits to Plane work items
# Prerequisites: all services running, Gitea admin + Plane API token configured, python3 installed
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
PLANE_URL="${PLANE_URL:-http://localhost:8080}"
PLANE_TOKEN="${PLANE_TOKEN:-}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-tagbag}"
BRIDGE_URL="${BRIDGE_URL:-http://localhost:9877}"
GITEA_WEBHOOK_SECRET="${GITEA_WEBHOOK_SECRET:-}"
TEST_REPO="e2e-webhook-test-$$"
TEST_ORG="tagbag"

PASS=0
FAIL=0
SKIP=0

# Track resources for cleanup
CREATED_REPO=""
CREATED_WORK_ITEM_ID=""
PROJ_ID=""

cleanup() {
  echo ""
  echo "[Cleanup] Removing test data..."
  if [ -n "$CREATED_REPO" ]; then
    curl -s -o /dev/null -X DELETE \
      -H "Authorization: token ${GITEA_TOKEN}" \
      "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${CREATED_REPO}" || true
    echo "  Deleted repo: ${TEST_ORG}/${CREATED_REPO}"
  fi
  if [ -n "$CREATED_WORK_ITEM_ID" ] && [ -n "$PROJ_ID" ]; then
    curl -s -o /dev/null -X DELETE \
      -H "X-Api-Key: ${PLANE_TOKEN}" \
      "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PROJ_ID}/work-items/${CREATED_WORK_ITEM_ID}/" || true
    echo "  Deleted work item: ${CREATED_WORK_ITEM_ID}"
  fi
}
trap cleanup EXIT

check() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  elif [ "$result" = "skip" ]; then
    echo "  SKIP: $name"
    SKIP=$((SKIP + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== E2E: Webhook Bridge Test ==="
echo ""

# ---------------------------------------------------------------
# Bootstrap: check required tools and services
# ---------------------------------------------------------------
echo "[Bootstrap] Checking prerequisites..."

if ! command -v python3 &>/dev/null; then
  echo "  ERROR: python3 is required but not installed."
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "  ERROR: curl is required but not installed."
  exit 1
fi

# Check Gitea
GITEA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${GITEA_URL}/api/v1/settings/api" 2>/dev/null || echo "000")
if [ "$GITEA_STATUS" != "200" ]; then
  echo "  ERROR: Gitea not accessible at ${GITEA_URL} (HTTP ${GITEA_STATUS})"
  echo "  Start services with: docker compose up -d"
  exit 1
fi
check "Gitea accessible" "pass"

# Check Plane
PLANE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${PLANE_URL}/api/instances/" 2>/dev/null || echo "000")
if [ "$PLANE_STATUS" != "200" ]; then
  echo "  ERROR: Plane not accessible at ${PLANE_URL} (HTTP ${PLANE_STATUS})"
  echo "  Start services with: docker compose up -d"
  exit 1
fi
check "Plane accessible" "pass"

# Check tokens
if [ -z "$GITEA_TOKEN" ]; then
  echo "  ERROR: GITEA_TOKEN not set. Export it before running."
  echo "  Create one at: ${GITEA_URL}/user/settings/applications"
  exit 1
fi
if [ -z "$PLANE_TOKEN" ]; then
  echo "  ERROR: PLANE_TOKEN not set. Export it before running."
  echo "  Create one at: ${PLANE_URL} > Workspace Settings > API Tokens"
  exit 1
fi
check "API tokens configured" "pass"

# ---------------------------------------------------------------
# Step 1: Create a test work item in Plane
# ---------------------------------------------------------------
echo ""
echo "[1/5] Creating test work item in Plane..."

# Get project ID
PROJ_ID=$(curl -s -H "X-Api-Key: ${PLANE_TOKEN}" \
  "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
projects = data if isinstance(data, list) else data.get('results', [])
for p in projects:
    print(p['id'])
    break
" 2>/dev/null || echo "")

if [ -z "$PROJ_ID" ]; then
  echo "  ERROR: Could not find project in workspace '${PLANE_WORKSPACE}'"
  exit 1
fi

# Get project identifier
PROJ_IDENT=$(curl -s -H "X-Api-Key: ${PLANE_TOKEN}" \
  "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
projects = data if isinstance(data, list) else data.get('results', [])
for p in projects:
    print(p['identifier'])
    break
" 2>/dev/null || echo "")

# Create a work item
WORK_ITEM=$(curl -s -X POST \
  -H "X-Api-Key: ${PLANE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "E2E webhook bridge test item", "description_html": "<p>Test item for webhook bridge E2E</p>"}' \
  "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PROJ_ID}/work-items/")

WORK_ITEM_ID=$(echo "$WORK_ITEM" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null || echo "")
WORK_ITEM_SEQ=$(echo "$WORK_ITEM" | python3 -c "import sys, json; print(json.load(sys.stdin).get('sequence_id', ''))" 2>/dev/null || echo "")

if [ -z "$WORK_ITEM_ID" ]; then
  echo "  ERROR: Could not create work item. Response: $WORK_ITEM"
  exit 1
fi

CREATED_WORK_ITEM_ID="$WORK_ITEM_ID"
WORK_ITEM_REF="${PROJ_IDENT}-${WORK_ITEM_SEQ}"
echo "  Created: ${WORK_ITEM_REF} (id: ${WORK_ITEM_ID})"
check "Work item created in Plane" "pass"

# ---------------------------------------------------------------
# Step 2: Create a test repo in Gitea
# ---------------------------------------------------------------
echo ""
echo "[2/5] Setting up test repo in Gitea..."

REPO_RESULT=$(curl -s -X POST \
  -H "Authorization: token ${GITEA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${TEST_REPO}\", \"auto_init\": true, \"default_branch\": \"main\"}" \
  "${GITEA_URL}/api/v1/orgs/${TEST_ORG}/repos")
REPO_NAME=$(echo "$REPO_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('full_name', ''))" 2>/dev/null || echo "")
if [ -n "$REPO_NAME" ]; then
  echo "  Created repo: ${REPO_NAME}"
  CREATED_REPO="${TEST_REPO}"
else
  echo "  ERROR: Could not create repo. Response: $REPO_RESULT"
  exit 1
fi
check "Test repo created" "pass"

# ---------------------------------------------------------------
# Step 3: Simulate a push webhook with work item reference
# ---------------------------------------------------------------
echo ""
echo "[3/5] Sending simulated push webhook to bridge..."

BRIDGE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BRIDGE_URL}/health" 2>/dev/null || echo "000")
if [ "$BRIDGE_STATUS" = "000" ]; then
  echo "  ERROR: Bridge not running at ${BRIDGE_URL}"
  echo "  Start it with: bridge/webhook-bridge.sh"
  check "Bridge accessible" "fail"
else
  check "Bridge accessible" "pass"

  # Send a push webhook payload
  WEBHOOK_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'ref': 'refs/heads/main',
    'commits': [{
        'id': 'abc123def456',
        'message': 'fixes ${WORK_ITEM_REF}: resolve the test issue',
        'url': '${GITEA_URL}/${TEST_ORG}/${TEST_REPO}/commit/abc123def456',
        'author': {'name': 'test', 'email': 'test@tagbag.local'},
        'timestamp': '2026-03-28T12:00:00Z'
    }],
    'repository': {
        'full_name': '${TEST_ORG}/${TEST_REPO}',
        'html_url': '${GITEA_URL}/${TEST_ORG}/${TEST_REPO}'
    },
    'pusher': {'login': 'admin'}
}))
")

  # Compute HMAC-SHA256 signature if secret is set
  SIG_ARGS=()
  if [ -n "$GITEA_WEBHOOK_SECRET" ]; then
    SIG=$(printf '%s' "$WEBHOOK_PAYLOAD" | openssl dgst -sha256 -hmac "$GITEA_WEBHOOK_SECRET" | sed 's/^.* //')
    SIG_ARGS=(-H "X-Gitea-Signature: ${SIG}")
  fi

  WEBHOOK_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Gitea-Event: push" \
    "${SIG_ARGS[@]}" \
    -d "$WEBHOOK_PAYLOAD" \
    "${BRIDGE_URL}/webhook")

  if [ "$WEBHOOK_RESULT" -ge 200 ] && [ "$WEBHOOK_RESULT" -lt 300 ]; then
    check "Push webhook delivered" "pass"
  else
    check "Push webhook delivered" "fail"
  fi

  # Wait a moment for the bridge to process
  sleep 2

  # Check if the Plane work item got a comment
  COMMENTS=$(curl -s \
    -H "X-Api-Key: ${PLANE_TOKEN}" \
    "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PROJ_ID}/work-items/${WORK_ITEM_ID}/comments/")
  COMMENT_COUNT=$(echo "$COMMENTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    comments = data if isinstance(data, list) else data.get('results', [])
    print(len(comments))
except (json.JSONDecodeError, AttributeError):
    print(0)
" 2>/dev/null || echo "0")

  if [ "$COMMENT_COUNT" -gt 0 ]; then
    check "Plane work item has comment" "pass"
  else
    check "Plane work item has comment" "fail"
  fi
fi

# ---------------------------------------------------------------
# Step 4: Verify Gitea repo has a webhook configured
# ---------------------------------------------------------------
echo ""
echo "[4/5] Checking Gitea webhook configuration..."

WEBHOOKS=$(curl -s \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}/hooks")
WEBHOOK_COUNT=$(echo "$WEBHOOKS" | python3 -c "
import sys, json
try:
    hooks = json.load(sys.stdin)
    print(len(hooks) if isinstance(hooks, list) else 0)
except (json.JSONDecodeError, AttributeError):
    print(0)
" 2>/dev/null || echo "0")

if [ "$WEBHOOK_COUNT" -gt 0 ]; then
  check "Gitea webhook configured" "pass"
else
  check "Gitea webhook configured" "skip"
  echo "  (No webhook configured — bridge receives webhooks when Gitea is configured to send them)"
fi

# ---------------------------------------------------------------
# Step 5: Verify work item can be queried
# ---------------------------------------------------------------
echo ""
echo "[5/5] Verifying work item state..."

ITEM_STATE=$(curl -s \
  -H "X-Api-Key: ${PLANE_TOKEN}" \
  "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PROJ_ID}/work-items/${WORK_ITEM_ID}/")
ITEM_NAME=$(echo "$ITEM_STATE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))" 2>/dev/null || echo "")

if [ -n "$ITEM_NAME" ]; then
  check "Work item queryable" "pass"
else
  check "Work item queryable" "fail"
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  PASS: ${PASS}  FAIL: ${FAIL}  SKIP: ${SKIP}"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
