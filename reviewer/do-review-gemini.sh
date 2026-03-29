#!/usr/bin/env bash
# Perform a code review using Gemini CLI for a single push event.
# Called by webhook-server.sh with: <repo-full-name> <commit-sha> <ref>
# Runs alongside do-review.sh (Claude) as a second reviewer.
set -euo pipefail

REPO="$1"
SHA="$2"
REF="${3:-}"

# Load config
TAGBAG_CONFIG="${TAGBAG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tagbag/config}"
# shellcheck source=/dev/null
[[ -f "$TAGBAG_CONFIG" ]] && source "$TAGBAG_CONFIG"

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
CLONE_DIR="${TAGBAG_CLONE_DIR:-$HOME/vibe/tagbag-clones}"

log() { echo "[gemini-review] [$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

[[ -n "$GITEA_TOKEN" ]] || { log "ERROR: GITEA_TOKEN not set"; exit 1; }

# Set pending commit status (separate context from Claude reviewer)
set_status() {
    local state="$1" desc="$2"
    curl -sf -X POST \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg s "$state" --arg d "$desc" --arg c "tagbag-gemini-reviewer" --arg u "${GITEA_URL}/${REPO}" \
            '{state: $s, description: $d, context: $c, target_url: $u}')" \
        "${GITEA_URL}/api/v1/repos/${REPO}/statuses/${SHA}" > /dev/null
}

log "Reviewing ${REPO}@${SHA:0:8}"
set_status "pending" "Gemini code review in progress..."

# Clone or update the repo
REPO_DIR="${CLONE_DIR}/${REPO}"
if [[ -d "${REPO_DIR}/.git" ]]; then
    cd "$REPO_DIR"
    git fetch origin 2>&1
    git checkout "$SHA" 2>&1 || git checkout -b "review-${SHA:0:8}" "$SHA" 2>&1
else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "${GITEA_URL}/${REPO}.git" "$REPO_DIR" 2>&1
    cd "$REPO_DIR"
    git checkout "$SHA" 2>&1 || true
fi

# Get the diff for context
DIFF=$(git diff HEAD~1..HEAD 2>/dev/null || git show --stat HEAD 2>/dev/null || echo "Initial commit")

REVIEW_PROMPT="You are a code reviewer. Review the following git diff thoroughly.

Repository: ${REPO}
Commit: ${SHA}
Ref: ${REF}

For each issue found, categorize as:
- BLOCKER: Must fix before merge (security, correctness, data loss)
- WARNING: Should fix but not blocking
- SUGGESTION: Nice to have improvement

Be concise. Focus on:
- Security vulnerabilities
- Logic errors
- Missing error handling at system boundaries
- Breaking API changes
- Performance regressions in hot paths

Do NOT comment on: style preferences, missing docs on unchanged code, or hypothetical issues.

Diff:
\`\`\`
${DIFF}
\`\`\`"

REVIEW_TIMEOUT="${TAGBAG_REVIEW_TIMEOUT:-300}"

REVIEW_OUTPUT=""
if command -v gemini &>/dev/null; then
    log "Running Gemini CLI review (timeout: ${REVIEW_TIMEOUT}s)..."
    local_exit=0
    REVIEW_OUTPUT=$(timeout "$REVIEW_TIMEOUT" gemini -p "$REVIEW_PROMPT" 2>&1) || local_exit=$?
    if [[ "$local_exit" -eq 124 ]]; then
        log "WARNING: Gemini review timed out after ${REVIEW_TIMEOUT}s"
        REVIEW_OUTPUT="Gemini review timed out after ${REVIEW_TIMEOUT}s. The diff may be too large for automated review."
    elif [[ "$local_exit" -ne 0 ]]; then
        log "ERROR: Gemini CLI failed (exit $local_exit): ${REVIEW_OUTPUT}"
        REVIEW_OUTPUT="Review failed — Gemini CLI error (exit $local_exit)"
    fi
else
    log "Gemini CLI not available, skipping"
    REVIEW_OUTPUT="Gemini review skipped — gemini CLI not found. Install from https://github.com/google-gemini/gemini-cli"
fi

# Check for blockers
HAS_BLOCKERS=false
if echo "$REVIEW_OUTPUT" | grep -qi "BLOCKER"; then
    HAS_BLOCKERS=true
fi

# Post review comment on the commit (prefixed to distinguish from Claude review)
COMMENT="## Gemini Code Review — ${SHA:0:8}

${REVIEW_OUTPUT}"

curl -sf -X POST \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "$COMMENT" '{body: $b}')" \
    "${GITEA_URL}/api/v1/repos/${REPO}/git/commits/${SHA}/comments" > /dev/null 2>&1 || \
    log "Warning: could not post commit comment"

# Set final commit status
if [[ "$HAS_BLOCKERS" == "true" ]]; then
    set_status "failure" "Gemini review found blockers"
    log "Review FAILED — blockers found"
else
    set_status "success" "Gemini review passed"
    log "Review PASSED"
fi

log "Gemini review complete for ${REPO}@${SHA:0:8}"
