#!/usr/bin/env bash
# TagBag Code Reviewer — lightweight webhook receiver
# Listens for Gitea push webhooks and queues reviews.
#
# Runs inside a tmux session managed by `tagbag reviewer start`.
# Uses netcat to listen on a port, no external dependencies.
set -euo pipefail

REVIEW_PORT="${TAGBAG_REVIEW_PORT:-9876}"
REVIEW_QUEUE="${TAGBAG_CONFIG_DIR:-$HOME/.config/tagbag}/review-queue"
REVIEW_LOG="${TAGBAG_CONFIG_DIR:-$HOME/.config/tagbag}/reviewer.log"
GITEA_WEBHOOK_SECRET="${GITEA_WEBHOOK_SECRET:-}"

mkdir -p "$(dirname "$REVIEW_QUEUE")"
: > "$REVIEW_QUEUE"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$REVIEW_LOG"; }

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

REVIEW_QUEUE_MAX="${TAGBAG_REVIEW_QUEUE_MAX:-50}"
REVIEW_QUEUE_WARN="${TAGBAG_REVIEW_QUEUE_WARN:-10}"
REVIEW_QUEUE_LOCK="${REVIEW_QUEUE}.lock"

log "TagBag Code Reviewer starting on port ${REVIEW_PORT}"
log "Queue: ${REVIEW_QUEUE}"
log "Log: ${REVIEW_LOG}"

# Process review queue in background
process_queue() {
    while true; do
        if [[ -s "$REVIEW_QUEUE" ]]; then
            local line
            # Use flock for atomic queue pop
            line=$(flock "${REVIEW_QUEUE}.lock" bash -c '
                head -1 "'"$REVIEW_QUEUE"'"
                tail -n +2 "'"$REVIEW_QUEUE"'" > "'"$REVIEW_QUEUE"'.tmp" && mv "'"$REVIEW_QUEUE"'.tmp" "'"$REVIEW_QUEUE"'"
            ' 2>/dev/null || head -1 "$REVIEW_QUEUE")
            if [[ -n "$line" ]]; then
                log "Processing: $line"
                # shellcheck disable=SC2086
                bash "$(dirname "$0")/do-review.sh" $line 2>&1 | tee -a "$REVIEW_LOG" || true
            fi
        fi
        sleep 2
    done
}
process_queue &
QUEUE_PID=$!

# Start threaded HTTP webhook server (handles concurrent connections)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "${SCRIPT_DIR}/webhook-http.py" &
HTTP_PID=$!

trap 'kill $QUEUE_PID $HTTP_PID 2>/dev/null; log "Reviewer stopped"' EXIT

# Wait for either process to exit
wait -n $QUEUE_PID $HTTP_PID 2>/dev/null || true
log "A subprocess exited unexpectedly, shutting down"
