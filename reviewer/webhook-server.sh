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
    tmpfifo=$(mktemp -u)
    mkfifo "$tmpfifo"
    tmpresp=$(mktemp -u)
    mkfifo "$tmpresp"

    # Listen for one connection
    (cat "$tmpresp" | nc -l "$REVIEW_PORT" > "$tmpfifo" 2>/dev/null) &
    NC_PID=$!

    # Read the raw request
    payload=$(timeout 300 cat "$tmpfifo" 2>/dev/null || true)
    rm -f "$tmpfifo"

    # Parse the payload — extract repo full_name and commit SHA
    if [[ -n "$payload" ]]; then
        # Try to extract JSON body (after the blank line in HTTP request)
        json_body=$(echo "$payload" | sed -n '/^\r*$/,$ p' | tail -n +2)
        signature=$(echo "$payload" | grep -i "^X-Gitea-Signature:" | awk '{print $2}' | tr -d '\r\n')

        if [[ -n "$json_body" ]]; then
            if verify_signature "$json_body" "$signature"; then
                echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" > "$tmpresp"
                repo=$(echo "$json_body" | jq -r '.repository.full_name // empty' 2>/dev/null)
                sha=$(echo "$json_body" | jq -r '.after // empty' 2>/dev/null)
                ref=$(echo "$json_body" | jq -r '.ref // empty' 2>/dev/null)
                if [[ -n "$repo" && -n "$sha" ]]; then
                    log "Webhook received: ${repo} ${sha} ${ref}"
                    echo "${repo} ${sha} ${ref}" >> "$REVIEW_QUEUE"
                fi
            else
                echo -e "HTTP/1.1 401 Unauthorized\r\nContent-Length: 12\r\n\r\nUnauthorized" > "$tmpresp"
            fi
        else
            echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" > "$tmpresp"
        fi
    else
        echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" > "$tmpresp"
    fi

    rm -f "$tmpresp"
    wait $NC_PID 2>/dev/null || true
done
