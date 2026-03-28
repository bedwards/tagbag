#!/usr/bin/env bash
# E2E test: create a Gitea repo, push a Woodpecker pipeline, verify it succeeds.
# Gitea at localhost:3000, Woodpecker at localhost:9080.
set -euo pipefail

GITEA_URL="http://localhost:3000"
WOODPECKER_URL="http://localhost:9080"
GITEA_USER="tagbag"
GITEA_PASS="${E2E_GITEA_PASS:?E2E_GITEA_PASS environment variable not set}"
REPO_NAME="ci-test"
FULL_REPO="${GITEA_USER}/${REPO_NAME}"
TMPDIR_PREFIX="tagbag-e2e"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329
cleanup() {
  local exit_code=$?
  echo "--- Cleanup ---"
  # Remove temp clone dir
  if [[ -n "${CLONE_DIR:-}" && -d "${CLONE_DIR:-}" ]]; then
    rm -rf "$CLONE_DIR"
    echo "Removed $CLONE_DIR"
  fi

  # Delete Gitea resources if token was created
  if [[ -n "${GITEA_TOKEN:-}" ]]; then
    # Delete the Gitea repo (ignore errors)
    curl -sf -X DELETE \
      -H "Authorization: token ${GITEA_TOKEN}" \
      "${GITEA_URL}/api/v1/repos/${FULL_REPO}" >/dev/null 2>&1 || true
    echo "Deleted Gitea repo ${FULL_REPO} (if it existed)"

    # Delete the Gitea token. This uses basic auth.
    curl -sf -X DELETE -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens/e2e-pipeline-test" >/dev/null 2>&1 || true
    echo "Deleted Gitea token e2e-pipeline-test (if it existed)"
  fi

  exit "$exit_code"
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Obtain Gitea API token
# ---------------------------------------------------------------------------

echo "==> Creating Gitea API token..."
# Delete stale token with the same name (ignore errors)
curl -sf -X DELETE -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens/e2e-pipeline-test" >/dev/null 2>&1 || true

TOKEN_RESP=$(curl -sf -X POST -u "${GITEA_USER}:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"name":"e2e-pipeline-test","scopes":["read:user", "read:repository", "write:repository"]}' \
  "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens")
GITEA_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha1'])")
echo "  Gitea token obtained."

# ---------------------------------------------------------------------------
# 2. Delete repo if it already exists (idempotent re-runs)
# ---------------------------------------------------------------------------

curl -sf -X DELETE \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/repos/${FULL_REPO}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Create Gitea repo
# ---------------------------------------------------------------------------

echo "==> Creating Gitea repo ${FULL_REPO}..."
curl -sf -X POST \
  -H "Authorization: token ${GITEA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"auto_init\":true,\"default_branch\":\"main\"}" \
  "${GITEA_URL}/api/v1/user/repos" >/dev/null
echo "  Repo created."

# ---------------------------------------------------------------------------
# 4. Clone, add pipeline file, push
# ---------------------------------------------------------------------------

CLONE_DIR=$(mktemp -d "/tmp/${TMPDIR_PREFIX}.XXXXXX")
echo "==> Cloning to ${CLONE_DIR}..."
git clone -q "http://localhost:3000/${FULL_REPO}.git" "$CLONE_DIR"
git -C "$CLONE_DIR" config http.extraHeader "Authorization: token ${GITEA_TOKEN}"

cat > "${CLONE_DIR}/.woodpecker.yaml" <<'YAML'
steps:
  hello:
    image: alpine
    commands:
      - echo "hello from tagbag e2e test"
YAML

git -C "$CLONE_DIR" add .woodpecker.yaml
git -C "$CLONE_DIR" commit -q -m "add e2e pipeline"
git -C "$CLONE_DIR" push -q origin main
echo "  Pushed .woodpecker.yaml to ${FULL_REPO}."

# ---------------------------------------------------------------------------
# 5. Obtain Woodpecker API token
# ---------------------------------------------------------------------------

echo "==> Obtaining Woodpecker API token..."
WP_TOKEN_RESP=$(curl -sf -X POST \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${WOODPECKER_URL}/api/user/token")
WP_TOKEN=$(echo "$WP_TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

# If the /api/user/token approach didn't work, try logging in via Gitea OAuth flow.
# Woodpecker uses Gitea OAuth, so we can also try using the Gitea token directly
# through the Woodpecker API with a workaround: sync repos first.
if [[ -z "$WP_TOKEN" ]]; then
  echo "  Could not get dedicated WP token; trying Gitea token as Bearer..."
  WP_TOKEN="$GITEA_TOKEN"
fi

# Verify we can reach Woodpecker
WP_USER=$(curl -sf -H "Authorization: Bearer ${WP_TOKEN}" "${WOODPECKER_URL}/api/user" 2>/dev/null || true)
if [[ -z "$WP_USER" ]]; then
  die "Cannot authenticate to Woodpecker API. Ensure Woodpecker is running and the tagbag user has logged in at least once via the Woodpecker UI."
fi
echo "  Woodpecker auth OK."

# ---------------------------------------------------------------------------
# 6. Sync Woodpecker repos and activate
# ---------------------------------------------------------------------------

echo "==> Syncing Woodpecker repos..."
curl -sf -X POST \
  -H "Authorization: Bearer ${WP_TOKEN}" \
  "${WOODPECKER_URL}/api/repos/repair" >/dev/null 2>&1 || true

# Look up the repo's forge_remote_id from Gitea
GITEA_REPO_ID=$(curl -sf \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/repos/${FULL_REPO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Gitea repo id: ${GITEA_REPO_ID}"

# Activate the repo in Woodpecker
echo "==> Activating repo in Woodpecker..."
ACTIVATE_RESP=$(curl -sf -X POST \
  -H "Authorization: Bearer ${WP_TOKEN}" \
  "${WOODPECKER_URL}/api/repos?forge_remote_id=${GITEA_REPO_ID}" 2>/dev/null || true)

if [[ -z "$ACTIVATE_RESP" ]]; then
  # Maybe already activated; try lookup
  ACTIVATE_RESP=$(curl -sf \
    -H "Authorization: Bearer ${WP_TOKEN}" \
    "${WOODPECKER_URL}/api/repos/lookup/${FULL_REPO}" 2>/dev/null || true)
fi

WP_REPO_ID=$(echo "$ACTIVATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
if [[ -z "$WP_REPO_ID" ]]; then
  die "Failed to activate repo in Woodpecker. Response: ${ACTIVATE_RESP}"
fi
echo "  Woodpecker repo id: ${WP_REPO_ID}"

# ---------------------------------------------------------------------------
# 7. Trigger a pipeline (push may have already triggered one, but ensure)
# ---------------------------------------------------------------------------

echo "==> Triggering pipeline..."
# Push another commit to trigger the webhook now that the repo is activated
cat > "${CLONE_DIR}/trigger.txt" <<< "trigger $(date +%s)"
git -C "$CLONE_DIR" add trigger.txt
git -C "$CLONE_DIR" commit -q -m "trigger pipeline"
git -C "$CLONE_DIR" push -q origin main
echo "  Pushed trigger commit."

# ---------------------------------------------------------------------------
# 8. Poll for pipeline completion
# ---------------------------------------------------------------------------

echo "==> Waiting for pipeline to complete..."
MAX_WAIT=120
POLL_INTERVAL=3
ELAPSED=0

while (( ELAPSED < MAX_WAIT )); do
  PIPELINES=$(curl -sf \
    -H "Authorization: Bearer ${WP_TOKEN}" \
    "${WOODPECKER_URL}/api/repos/${WP_REPO_ID}/pipelines" 2>/dev/null || echo "[]")

  # Get the latest pipeline status
  STATUS=$(echo "$PIPELINES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data:
    print(data[0].get('status', 'unknown'))
else:
    print('none')
" 2>/dev/null || echo "error")

  echo "  Pipeline status: ${STATUS} (${ELAPSED}s elapsed)"

  case "$STATUS" in
    success)
      echo ""
      echo "==> PASS: Pipeline completed successfully!"
      exit 0
      ;;
    failure|error|killed|declined)
      die "Pipeline ended with status: ${STATUS}"
      ;;
    none)
      ;; # no pipeline yet, keep waiting
    *)
      ;; # pending/running, keep waiting
  esac

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

die "Pipeline did not complete within ${MAX_WAIT}s (last status: ${STATUS})"
