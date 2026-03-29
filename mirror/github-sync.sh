#!/usr/bin/env bash
# github-sync.sh — mirror a Gitea repo to GitHub (code, branches, tags only)
#
# Usage: github-sync.sh <owner/repo> [ref]
#
# Creates the GitHub repo (private) if it doesn't exist.
# Pushes all branches and tags. GitHub is read-only; all writes go to Gitea.
set -euo pipefail

REPO="${1:?Usage: github-sync.sh <owner/repo> [ref]}"
REF="${2:-}"
GITEA_URL="${GITEA_URL:-http://localhost:3000}"
MIRROR_DIR="${TAGBAG_MIRROR_DIR:-${TAGBAG_CLONE_DIR:-$HOME/vibe/tagbag-clones}/.mirrors}"

log() { echo "[mirror] [$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Map Gitea owner/repo to GitHub user/repo
# Only mirror repos where the Gitea owner matches the GitHub user
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"

if [[ -z "$GH_USER" ]]; then
    log "ERROR: gh CLI not authenticated"
    exit 1
fi

# Remap: any Gitea owner maps to the authenticated GitHub user
GH_REPO="${GH_USER}/${NAME}"

# ── Ensure GitHub repo exists (private, minimal features) ────────────────────
if ! gh repo view "$GH_REPO" &>/dev/null; then
    log "Creating private GitHub repo: ${GH_REPO}"
    gh repo create "$GH_REPO" \
        --private \
        --disable-wiki \
        --description "Mirror of ${GITEA_URL}/${REPO} (read-only)" \
        2>&1 || {
        log "ERROR: Failed to create GitHub repo ${GH_REPO}"
        exit 1
    }
    log "Created ${GH_REPO} on GitHub"
fi

# ── Clone/update bare mirror from Gitea ──────────────────────────────────────
MIRROR_PATH="${MIRROR_DIR}/${REPO}.git"
mkdir -p "$(dirname "$MIRROR_PATH")"

if [[ -d "$MIRROR_PATH" ]]; then
    log "Fetching updates from Gitea..."
    cd "$MIRROR_PATH"
    git fetch --prune origin 2>&1
else
    log "Creating bare mirror clone from Gitea..."
    git clone --bare "${GITEA_URL}/${REPO}.git" "$MIRROR_PATH" 2>&1
    cd "$MIRROR_PATH"
fi

# ── Push to GitHub (all refs: branches + tags) ───────────────────────────────
# Set GitHub as the push target
GITHUB_URL="$(gh repo view "$GH_REPO" --json sshUrl -q .sshUrl)"
git remote set-url --push origin "$GITHUB_URL" 2>/dev/null || \
    git remote set-url origin "$GITHUB_URL" --push 2>/dev/null || true

# If push remote isn't set, add it
if ! git remote get-url --push origin &>/dev/null; then
    git remote add github "$GITHUB_URL"
    PUSH_REMOTE="github"
else
    PUSH_REMOTE="origin"
fi

log "Pushing to GitHub (${GITHUB_URL})..."
git push --all --force "$PUSH_REMOTE" 2>&1
git push --tags --force "$PUSH_REMOTE" 2>&1

log "Sync complete: ${REPO} → github.com/${GH_REPO}"
