#!/usr/bin/env bash
# Perform a code review for a single push event.
# Called by webhook-server.sh with: <repo-full-name> <commit-sha> <ref>
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
PLANE_URL="${PLANE_URL:-http://localhost:8080}"
PLANE_API_TOKEN="${PLANE_API_TOKEN:-}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-}"
CLONE_DIR="${TAGBAG_CLONE_DIR:-$HOME/vibe/tagbag-clones}"

log() { echo "[review] [$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

[[ -n "$GITEA_TOKEN" ]] || { log "ERROR: GITEA_TOKEN not set"; exit 1; }

# Set pending commit status
set_status() {
    local state="$1" desc="$2"
    curl -sf -X POST \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg s "$state" --arg d "$desc" --arg c "tagbag-reviewer" --arg u "${GITEA_URL}/${REPO}" \
            '{state: $s, description: $d, context: $c, target_url: $u}')" \
        "${GITEA_URL}/api/v1/repos/${REPO}/statuses/${SHA}" > /dev/null
}

# Find open PR for this branch
find_pr_for_ref() {
    local branch="${REF#refs/heads/}"
    if [[ -z "$branch" || "$branch" == "refs/heads/" ]]; then return; fi
    curl -sf -H "Authorization: token $GITEA_TOKEN" \
        "${GITEA_URL}/api/v1/repos/${REPO}/pulls?state=open&limit=50" 2>/dev/null | \
        jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .number' | head -1
}

# Create a Plane work item for deferred items
create_plane_issue() {
    local title="$1" body="$2"
    if [[ -z "$PLANE_API_TOKEN" || -z "$PLANE_WORKSPACE" ]]; then
        log "SKIP deferred issue (Plane not configured): $title"
        return
    fi
    local repo_name="${REPO##*/}"
    # Find Plane project matching repo name
    local proj_id
    proj_id=$(curl -sf "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" \
        -H "X-Api-Key: $PLANE_API_TOKEN" 2>/dev/null | \
        jq -r --arg name "$repo_name" '(.results // .)[] | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id' | head -1)
    if [[ -z "$proj_id" || "$proj_id" == "null" ]]; then
        log "SKIP deferred issue (no Plane project for $repo_name): $title"
        return
    fi
    local result
    result=$(curl -sf -X POST "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${proj_id}/work-items/" \
        -H "X-Api-Key: $PLANE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$title" --arg b "$body" '{name: $t, description_html: ("<p>" + $b + "</p>")}')" 2>/dev/null)
    local seq
    seq=$(echo "$result" | jq -r '.sequence_id // empty' 2>/dev/null)
    if [[ -n "$seq" ]]; then
        log "Created Plane issue: $title"
    else
        log "FAILED to create Plane issue: $title"
    fi
}

log "Reviewing ${REPO}@${SHA:0:8}"
set_status "pending" "Code review in progress..."

# Clone or update the repo
REPO_DIR="${CLONE_DIR}/${REPO}"
if [[ -d "${REPO_DIR}/.git" ]]; then
    log "Updating existing clone..."
    cd "$REPO_DIR"
    git fetch origin 2>&1
    git checkout "$SHA" 2>&1 || git checkout -b "review-${SHA:0:8}" "$SHA" 2>&1
else
    log "Cloning ${REPO}..."
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "${GITEA_URL}/${REPO}.git" "$REPO_DIR" 2>&1
    cd "$REPO_DIR"
    git checkout "$SHA" 2>&1 || true
fi

# Get the diff for context
DIFF=$(git diff HEAD~1..HEAD 2>/dev/null || git show --stat HEAD 2>/dev/null || echo "Initial commit")

# Run Claude Code headless for review
REVIEW_PROMPT="You are a code reviewer. Review the following git diff thoroughly.

Repository: ${REPO}
Commit: ${SHA}
Ref: ${REF}

For each issue found, categorize as:
- BLOCKER: Must fix before merge (security, correctness, data loss)
- WARNING: Should fix but not blocking
- SUGGESTION: Nice to have improvement

If you find issues that don't need immediate fixing, note them as 'DEFERRED: <description>' — these will become issues.

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
if command -v claude &>/dev/null; then
    log "Running Claude Code review (timeout: ${REVIEW_TIMEOUT}s)..."
    REVIEW_OUTPUT=$(timeout "$REVIEW_TIMEOUT" claude -p "$REVIEW_PROMPT" --model claude-opus-4-6 --max-turns 1 2>/dev/null) || {
        if [[ $? -eq 124 ]]; then
            log "WARNING: Claude Code review timed out after ${REVIEW_TIMEOUT}s"
            REVIEW_OUTPUT="Review timed out after ${REVIEW_TIMEOUT}s. The diff may be too large for automated review."
        else
            REVIEW_OUTPUT="Review failed — Claude Code not available"
        fi
    }
else
    log "Claude Code not available, using basic review"
    REVIEW_OUTPUT="Automated review skipped — Claude Code CLI not found. Install from https://claude.com/claude-code"
fi

# Check for blockers
HAS_BLOCKERS=false
if echo "$REVIEW_OUTPUT" | grep -qi "BLOCKER"; then
    HAS_BLOCKERS=true
fi

# Create Plane work items for deferred items
while IFS= read -r deferred_line; do
    if [[ -n "$deferred_line" ]]; then
        issue_title=$(echo "$deferred_line" | sed 's/^.*DEFERRED: //' | head -c 200)
        create_plane_issue "$issue_title" "Found during Claude review of ${SHA:0:8} on ${REF}."
    fi
done < <(echo "$REVIEW_OUTPUT" | grep -i "DEFERRED:" || true)

# Build the review comment
COMMENT="## Claude Code Review — ${SHA:0:8}

${REVIEW_OUTPUT}"

# Post review: as PR comment if there's an open PR, otherwise as commit comment
PR_NUMBER=$(find_pr_for_ref)
if [[ -n "$PR_NUMBER" ]]; then
    log "Posting review as comment on PR #${PR_NUMBER}"
    curl -sf -X POST \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg b "$COMMENT" '{body: $b}')" \
        "${GITEA_URL}/api/v1/repos/${REPO}/issues/${PR_NUMBER}/comments" > /dev/null 2>&1 || \
        log "Warning: could not post PR comment"
else
    log "No open PR for ${REF} — posting as commit comment"
    curl -sf -X POST \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg b "$COMMENT" '{body: $b}')" \
        "${GITEA_URL}/api/v1/repos/${REPO}/git/notes/${SHA}" > /dev/null 2>&1 || \
        log "Warning: could not post commit note"
fi

# Set final commit status
if [[ "$HAS_BLOCKERS" == "true" ]]; then
    set_status "failure" "Code review found blockers"
    log "Review FAILED — blockers found"
else
    set_status "success" "Code review passed"
    log "Review PASSED"
fi

# Prune clones older than 7 days
CLONE_MAX_AGE_DAYS="${TAGBAG_CLONE_MAX_AGE:-7}"
if [[ -d "$CLONE_DIR" ]]; then
    find "$CLONE_DIR" -mindepth 3 -maxdepth 3 -type d -name ".git" -mtime "+${CLONE_MAX_AGE_DAYS}" -execdir bash -c 'log "Pruning stale clone: $(pwd)"; rm -rf "$(pwd)"' \; 2>/dev/null || true
fi

log "Review complete for ${REPO}@${SHA:0:8}"
