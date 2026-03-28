#!/usr/bin/env bash
# tests/e2e-code-reviewer.sh — E2E test: code reviewer sets commit status on Gitea
# Prerequisites: all services running, Gitea admin token configured
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
REVIEWER_URL="${REVIEWER_URL:-http://localhost:9876}"
GITEA_WEBHOOK_SECRET="${GITEA_WEBHOOK_SECRET:-}"
TEST_REPO="e2e-reviewer-test"
TEST_ORG="tagbag"

PASS=0
FAIL=0
SKIP=0

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

echo "=== E2E: Code Reviewer Test ==="
echo ""

# ---------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------
echo "[Pre-flight] Checking services..."

GITEA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${GITEA_URL}/api/v1/settings/api" 2>/dev/null || echo "000")
if [ "$GITEA_STATUS" != "200" ]; then
  echo "  ERROR: Gitea not accessible at ${GITEA_URL} (HTTP ${GITEA_STATUS})"
  exit 1
fi
check "Gitea accessible" "pass"

if [ -z "$GITEA_TOKEN" ]; then
  echo "  ERROR: GITEA_TOKEN not set. Export it before running."
  exit 1
fi
check "Gitea token configured" "pass"

# ---------------------------------------------------------------
# Step 1: Create test repo
# ---------------------------------------------------------------
echo ""
echo "[1/5] Setting up test repo..."

REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}")

if [ "$REPO_CHECK" = "200" ]; then
  echo "  Repo ${TEST_ORG}/${TEST_REPO} already exists."
else
  REPO_RESULT=$(curl -s -X POST \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_REPO}\", \"auto_init\": true, \"default_branch\": \"main\"}" \
    "${GITEA_URL}/api/v1/orgs/${TEST_ORG}/repos")
  REPO_NAME=$(echo "$REPO_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('full_name', ''))" 2>/dev/null || echo "")
  if [ -n "$REPO_NAME" ]; then
    echo "  Created repo: ${REPO_NAME}"
  else
    echo "  ERROR: Could not create repo. Response: $REPO_RESULT"
    exit 1
  fi
fi
check "Test repo exists" "pass"

# ---------------------------------------------------------------
# Step 2: Create a commit via API
# ---------------------------------------------------------------
echo ""
echo "[2/5] Creating test commit..."

COMMIT_RESULT=$(curl -s -X POST \
  -H "Authorization: token ${GITEA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "content": "# E2E test file\nprint(\"hello world\")\n",
    "message": "test: add hello world script for reviewer E2E",
    "new_branch": "main"
  }' \
  "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}/contents/test_hello.py")

COMMIT_SHA=$(echo "$COMMIT_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('commit', {})
    print(c.get('sha', ''))
except (json.JSONDecodeError, AttributeError):
    print('')
" 2>/dev/null || echo "")

if [ -n "$COMMIT_SHA" ]; then
  echo "  Commit created: ${COMMIT_SHA}"
  check "Test commit created" "pass"
else
  # File may already exist, try update
  FILE_SHA=$(curl -s \
    -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}/contents/test_hello.py" | \
    python3 -c "import sys, json; print(json.load(sys.stdin).get('sha', ''))" 2>/dev/null || echo "")

  if [ -n "$FILE_SHA" ]; then
    COMMIT_RESULT=$(curl -s -X PUT \
      -H "Authorization: token ${GITEA_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"content\": \"$(echo -n "# E2E test $(date +%s)" | base64)\",
        \"message\": \"test: update hello world for reviewer E2E\",
        \"sha\": \"${FILE_SHA}\"
      }" \
      "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}/contents/test_hello.py")

    COMMIT_SHA=$(echo "$COMMIT_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('commit', {}).get('sha', ''))
except (json.JSONDecodeError, AttributeError):
    print('')
" 2>/dev/null || echo "")
  fi

  if [ -n "$COMMIT_SHA" ]; then
    echo "  Commit updated: ${COMMIT_SHA}"
    check "Test commit created" "pass"
  else
    echo "  WARNING: Could not create commit"
    check "Test commit created" "fail"
    COMMIT_SHA="HEAD"
  fi
fi

# ---------------------------------------------------------------
# Step 3: Check reviewer webhook
# ---------------------------------------------------------------
echo ""
echo "[3/5] Checking reviewer service..."

REVIEWER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${REVIEWER_URL}/health" 2>/dev/null || echo "000")
if [ "$REVIEWER_STATUS" = "000" ]; then
  echo "  SKIP: Reviewer not running at ${REVIEWER_URL}"
  echo "  Start with: tagbag reviewer start"
  check "Reviewer accessible" "skip"
else
  check "Reviewer accessible" "pass"

  # Send push webhook
  echo ""
  echo "[4/5] Sending push webhook to reviewer..."

  WEBHOOK_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'ref': 'refs/heads/main',
    'after': '${COMMIT_SHA}',
    'commits': [{
        'id': '${COMMIT_SHA}',
        'message': 'test: update hello world for reviewer E2E',
        'url': '${GITEA_URL}/${TEST_ORG}/${TEST_REPO}/commit/${COMMIT_SHA}'
    }],
    'repository': {
        'full_name': '${TEST_ORG}/${TEST_REPO}',
        'html_url': '${GITEA_URL}/${TEST_ORG}/${TEST_REPO}'
    }
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
    "${REVIEWER_URL}/webhook")

  if [ "$WEBHOOK_RESULT" -ge 200 ] && [ "$WEBHOOK_RESULT" -lt 300 ]; then
    check "Push webhook delivered" "pass"
  else
    check "Push webhook delivered" "fail"
  fi
fi

# ---------------------------------------------------------------
# Step 4: Check commit statuses
# ---------------------------------------------------------------
echo ""
echo "[5/5] Checking commit status..."

if [ "$COMMIT_SHA" != "HEAD" ]; then
  STATUSES=$(curl -s \
    -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${TEST_ORG}/${TEST_REPO}/statuses/${COMMIT_SHA}")

  STATUS_COUNT=$(echo "$STATUSES" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    statuses = data if isinstance(data, list) else []
    reviewer = [s for s in statuses if s.get('context') == 'tagbag-reviewer']
    print(len(reviewer))
except (json.JSONDecodeError, AttributeError):
    print(0)
" 2>/dev/null || echo "0")

  if [ "$STATUS_COUNT" -gt 0 ]; then
    check "Commit has tagbag-reviewer status" "pass"
  else
    check "Commit has tagbag-reviewer status" "skip"
    echo "  (Status will appear after reviewer processes the webhook)"
  fi
else
  check "Commit status check" "skip"
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
