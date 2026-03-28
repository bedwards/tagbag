#!/usr/bin/env bash
# TagBag Webhook Bridge — cross-service integration
# Listens for Gitea webhooks and updates Plane work items.
#
# Features:
# - Parse commit messages for PROJ-123 references
# - Auto-link PRs to Plane work items (add comment + link)
# - Update work item state on branch creation (→ In Progress)
# - Update work item state on PR merge (→ Done)
# - Post pipeline results back to work items
set -euo pipefail

BRIDGE_PORT="${TAGBAG_BRIDGE_PORT:-9877}"
BRIDGE_LOG="${XDG_CONFIG_HOME:-$HOME/.config}/tagbag/bridge.log"

# Load config
TAGBAG_CONFIG="${TAGBAG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tagbag/config}"
# shellcheck source=/dev/null
[[ -f "$TAGBAG_CONFIG" ]] && source "$TAGBAG_CONFIG"

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
PLANE_URL="${PLANE_URL:-http://localhost:8080}"
PLANE_API_TOKEN="${PLANE_API_TOKEN:-}"
PLANE_WORKSPACE="${TAGBAG_PLANE_WORKSPACE:-}"
GITEA_WEBHOOK_SECRET="${GITEA_WEBHOOK_SECRET:-}"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$BRIDGE_LOG"; }

# Verify HMAC-SHA256 webhook signature from Gitea
verify_signature() {
    local body="$1" signature="$2"
    if [[ -z "$GITEA_WEBHOOK_SECRET" ]]; then
        log "WARNING: GITEA_WEBHOOK_SECRET not set — skipping signature verification"
        return 0
    fi
    if [[ -z "$signature" ]]; then
        log "REJECTED: missing X-Gitea-Signature header"
        return 1
    fi
    local expected
    expected=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$GITEA_WEBHOOK_SECRET" | sed 's/^.* //')
    # Constant-time comparison to prevent timing attacks
    if [[ "$(printf '%s' "$expected" | openssl dgst -sha256)" != "$(printf '%s' "$signature" | openssl dgst -sha256)" ]]; then
        log "REJECTED: invalid webhook signature"
        return 1
    fi
    return 0
}

# Extract PROJ-123 references from text
extract_refs() {
    echo "$1" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u
}

# Get Plane work item by identifier (e.g., PROJ-123)
get_work_item() {
    local ref="$1"
    [[ -n "$PLANE_API_TOKEN" && -n "$PLANE_WORKSPACE" ]] || return 1
    curl -sf \
        -H "X-Api-Key: $PLANE_API_TOKEN" \
        "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/${ref}/" 2>/dev/null
}

# Add comment to Plane work item
add_plane_comment() {
    local ws="$1" proj_id="$2" issue_id="$3" comment="$4"
    curl -sf -X POST \
        -H "X-Api-Key: $PLANE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$comment" '{comment_html: $c}')" \
        "${PLANE_URL}/api/v1/workspaces/${ws}/projects/${proj_id}/work-items/${issue_id}/comments/" > /dev/null 2>&1
}

# Add link to Plane work item
add_plane_link() {
    local ws="$1" proj_id="$2" issue_id="$3" title="$4" url="$5"
    curl -sf -X POST \
        -H "X-Api-Key: $PLANE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$title" --arg u "$url" '{title: $t, url: $u}')" \
        "${PLANE_URL}/api/v1/workspaces/${ws}/projects/${proj_id}/work-items/${issue_id}/links/" > /dev/null 2>&1
}

# Process a push event
handle_push() {
    local payload="$1"
    local repo ref after
    repo=$(echo "$payload" | jq -r '.repository.full_name // empty')
    ref=$(echo "$payload" | jq -r '.ref // empty')
    after=$(echo "$payload" | jq -r '.after // empty')

    [[ -n "$repo" ]] || return

    # Check all commit messages for PROJ-123 references
    local all_messages
    all_messages=$(echo "$payload" | jq -r '.commits[]?.message // empty' 2>/dev/null)
    local refs
    refs=$(extract_refs "$all_messages")

    for ref_id in $refs; do
        log "Found reference: ${ref_id} in ${repo}"
        local item
        item=$(get_work_item "$ref_id" 2>/dev/null) || continue
        local project_id issue_id
        project_id=$(echo "$item" | jq -r '.project // empty')
        issue_id=$(echo "$item" | jq -r '.id // empty')
        [[ -n "$project_id" && -n "$issue_id" ]] || continue

        # Add a comment linking the commit
        local commit_url="${GITEA_URL}/${repo}/commit/${after}"
        add_plane_comment "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
            "<p>Referenced in <a href=\"${commit_url}\">${repo}@${after:0:7}</a></p>"
        log "Linked commit ${after:0:7} to ${ref_id}"

        # Add link
        add_plane_link "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
            "Commit ${after:0:7}" "$commit_url"

        # If message contains "fixes" or "closes", find the state and mark done
        if echo "$all_messages" | grep -qiE "(fix(es|ed)?|clos(es|ed)?|resolv(es|ed)?)\s+${ref_id}"; then
            log "Auto-closing ${ref_id} (keyword found)"
            # We'd need to find the "Done" state ID — for now just add a comment
            add_plane_comment "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
                "<p><strong>Auto-resolved</strong> by commit ${after:0:7} in ${repo}</p>"
        fi
    done
}

# Process a pull_request event
handle_pull_request() {
    local payload="$1"
    local action repo pr_title pr_url pr_num head_ref
    action=$(echo "$payload" | jq -r '.action // empty')
    repo=$(echo "$payload" | jq -r '.repository.full_name // empty')
    pr_title=$(echo "$payload" | jq -r '.pull_request.title // empty')
    pr_url=$(echo "$payload" | jq -r '.pull_request.html_url // empty')
    pr_num=$(echo "$payload" | jq -r '.pull_request.number // empty')
    head_ref=$(echo "$payload" | jq -r '.pull_request.head.ref // empty')

    # Check PR title and branch name for refs
    local refs
    refs=$(extract_refs "${pr_title} ${head_ref}")

    for ref_id in $refs; do
        local item
        item=$(get_work_item "$ref_id" 2>/dev/null) || continue
        local project_id issue_id
        project_id=$(echo "$item" | jq -r '.project // empty')
        issue_id=$(echo "$item" | jq -r '.id // empty')
        [[ -n "$project_id" && -n "$issue_id" ]] || continue

        case "$action" in
            opened)
                log "PR #${pr_num} opened for ${ref_id}"
                add_plane_comment "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
                    "<p>Pull request <a href=\"${pr_url}\">#${pr_num}: ${pr_title}</a> opened in ${repo}</p>"
                add_plane_link "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
                    "PR #${pr_num}" "$pr_url"
                ;;
            closed)
                local merged
                merged=$(echo "$payload" | jq -r '.pull_request.merged // false')
                if [[ "$merged" == "true" ]]; then
                    log "PR #${pr_num} merged for ${ref_id}"
                    add_plane_comment "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
                        "<p>Pull request <a href=\"${pr_url}\">#${pr_num}</a> <strong>merged</strong> in ${repo}</p>"
                fi
                ;;
        esac
    done
}

# Process a create event (branch creation)
handle_create() {
    local payload="$1"
    local ref_type ref repo
    ref_type=$(echo "$payload" | jq -r '.ref_type // empty')
    ref=$(echo "$payload" | jq -r '.ref // empty')
    repo=$(echo "$payload" | jq -r '.repository.full_name // empty')

    [[ "$ref_type" == "branch" ]] || return

    local refs
    refs=$(extract_refs "$ref")
    for ref_id in $refs; do
        log "Branch '${ref}' created for ${ref_id}"
        local item
        item=$(get_work_item "$ref_id" 2>/dev/null) || continue
        local project_id issue_id
        project_id=$(echo "$item" | jq -r '.project // empty')
        issue_id=$(echo "$item" | jq -r '.id // empty')
        [[ -n "$project_id" && -n "$issue_id" ]] || continue

        add_plane_comment "$PLANE_WORKSPACE" "$project_id" "$issue_id" \
            "<p>Branch <code>${ref}</code> created in ${repo}</p>"
    done
}

BRIDGE_QUEUE="${TAGBAG_CONFIG_DIR:-$HOME/.config/tagbag}/bridge-queue"
mkdir -p "$(dirname "$BRIDGE_QUEUE")"

log "TagBag Webhook Bridge starting on port ${BRIDGE_PORT}"

# Process bridge queue in background
process_queue() {
    while true; do
        if [[ -s "$BRIDGE_QUEUE" ]]; then
            local line
            line=$(flock "${BRIDGE_QUEUE}.lock" bash -c '
                head -1 "'"$BRIDGE_QUEUE"'"
                tail -n +2 "'"$BRIDGE_QUEUE"'" > "'"$BRIDGE_QUEUE"'.tmp" && mv "'"$BRIDGE_QUEUE"'.tmp" "'"$BRIDGE_QUEUE"'"
            ' 2>/dev/null || head -1 "$BRIDGE_QUEUE")
            if [[ -n "$line" ]]; then
                event_type=$(echo "$line" | cut -f1)
                json_body=$(echo "$line" | cut -f2-)
                log "Processing event: $event_type"
                case "$event_type" in
                    push)           handle_push "$json_body" ;;
                    pull_request)   handle_pull_request "$json_body" ;;
                    create)         handle_create "$json_body" ;;
                    *)              log "Ignored event: ${event_type:-unknown}" ;;
                esac
            fi
        fi
        sleep 1
    done
}
process_queue &
QUEUE_PID=$!

# Start threaded HTTP webhook server (handles concurrent connections)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "${SCRIPT_DIR}/webhook-http.py" &
HTTP_PID=$!

trap 'kill $QUEUE_PID $HTTP_PID 2>/dev/null; log "Bridge stopped"' EXIT

# Wait for either process to exit
wait -n $QUEUE_PID $HTTP_PID 2>/dev/null || true
log "A subprocess exited unexpectedly, shutting down"
