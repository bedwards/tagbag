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

mkdir -p "$(dirname "$REVIEW_QUEUE")"
: > "$REVIEW_QUEUE"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$REVIEW_LOG"; }

log "TagBag Code Reviewer starting on port ${REVIEW_PORT}"
log "Queue: ${REVIEW_QUEUE}"
log "Log: ${REVIEW_LOG}"

# Process review queue in background
process_queue() {
    while true; do
        if [[ -s "$REVIEW_QUEUE" ]]; then
            local line
            line=$(head -1 "$REVIEW_QUEUE")
            sed -i '' '1d' "$REVIEW_QUEUE" 2>/dev/null || tail -n +2 "$REVIEW_QUEUE" > "${REVIEW_QUEUE}.tmp" && mv "${REVIEW_QUEUE}.tmp" "$REVIEW_QUEUE"
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
trap 'kill $QUEUE_PID 2>/dev/null; log "Reviewer stopped"' EXIT

# Listen for webhooks
while true; do
    # Use a simple HTTP response
    response="HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

    # Read the webhook payload via a temp fifo
    tmpfifo=$(mktemp -u)
    mkfifo "$tmpfifo"

    # Listen for one connection
    (echo -e "$response" | nc -l "$REVIEW_PORT" > "$tmpfifo" 2>/dev/null) &
    NC_PID=$!

    # Read the body
    payload=""
    if timeout 300 cat "$tmpfifo" 2>/dev/null; then
        payload=$(cat "$tmpfifo" 2>/dev/null || true)
    fi
    rm -f "$tmpfifo"
    wait $NC_PID 2>/dev/null || true

    # Parse the payload — extract repo full_name and commit SHA
    if [[ -n "$payload" ]]; then
        # Try to extract JSON body (after the blank line in HTTP request)
        json_body=$(echo "$payload" | sed -n '/^\r*$/,$ p' | tail -n +2)
        if [[ -n "$json_body" ]]; then
            repo=$(echo "$json_body" | jq -r '.repository.full_name // empty' 2>/dev/null)
            sha=$(echo "$json_body" | jq -r '.after // empty' 2>/dev/null)
            ref=$(echo "$json_body" | jq -r '.ref // empty' 2>/dev/null)
            if [[ -n "$repo" && -n "$sha" ]]; then
                log "Webhook received: ${repo} ${sha} ${ref}"
                echo "${repo} ${sha} ${ref}" >> "$REVIEW_QUEUE"
            fi
        fi
    fi
done
