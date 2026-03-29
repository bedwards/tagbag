#!/usr/bin/env bash
# issue-sync.sh — bidirectional issue sync between Gitea and GitHub
#
# Usage: issue-sync.sh <owner/repo>
#
# Syncs issues both ways using HTML comment markers to track pairs.
# Creates issues where missing, updates title/state where changed.
set -euo pipefail

REPO="${1:?Usage: issue-sync.sh <owner/repo>}"
GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_TOKEN="${GITEA_TOKEN:-}"

log() { echo "[issue-sync] [$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

[[ -n "$GITEA_TOKEN" ]] || { log "ERROR: GITEA_TOKEN not set"; exit 1; }

NAME="${REPO##*/}"
GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"
[[ -n "$GH_USER" ]] || { log "ERROR: gh CLI not authenticated"; exit 1; }
GH_REPO="${GH_USER}/${NAME}"

if ! gh repo view "$GH_REPO" &>/dev/null; then
    log "GitHub repo ${GH_REPO} not found — run github-sync.sh first"
    exit 1
fi

# Enable issues on GitHub if disabled
HAS_ISSUES="$(gh repo view "$GH_REPO" --json hasIssuesEnabled -q .hasIssuesEnabled 2>/dev/null || echo "false")"
if [[ "$HAS_ISSUES" != "true" ]]; then
    log "Enabling issues on ${GH_REPO}..."
    gh repo edit "$GH_REPO" --enable-issues 2>&1
fi

log "Syncing issues: ${REPO} ↔ github.com/${GH_REPO}"

# Delegate to Python for robust JSON handling
exec python3 "$(dirname "$0")/issue-sync-core.py" \
    --gitea-url "$GITEA_URL" \
    --gitea-token "$GITEA_TOKEN" \
    --gitea-repo "$REPO" \
    --github-repo "$GH_REPO"
