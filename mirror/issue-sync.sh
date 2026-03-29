#!/usr/bin/env bash
# issue-sync.sh — bidirectional issue sync between Plane and GitHub
#
# Usage: issue-sync.sh <owner/repo>
#
# Maps repo name to a Plane project (e.g. bedwards/memorious → MEM project).
# Syncs work items both ways using HTML comment markers.
set -euo pipefail

REPO="${1:?Usage: issue-sync.sh <owner/repo>}"
PLANE_URL="${PLANE_URL:-http://localhost:8080}"
PLANE_API_TOKEN="${PLANE_API_TOKEN:-}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-}"

log() { echo "[issue-sync] [$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Load config if tokens not in env
TAGBAG_CONFIG="${TAGBAG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tagbag/config}"
if [[ -f "$TAGBAG_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$TAGBAG_CONFIG"
fi
PLANE_API_TOKEN="${PLANE_API_TOKEN:-}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-}"

[[ -n "$PLANE_API_TOKEN" ]] || { log "SKIP: PLANE_API_TOKEN not set"; exit 0; }
[[ -n "$PLANE_WORKSPACE" ]] || { log "SKIP: PLANE_WORKSPACE not set"; exit 0; }

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

# Find the Plane project that matches this repo name
PROJECT_INFO="$(curl -sf "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" \
    -H "X-Api-Key: ${PLANE_API_TOKEN}" 2>/dev/null || echo "")"

if [[ -z "$PROJECT_INFO" ]]; then
    log "SKIP: Could not fetch Plane projects"
    exit 0
fi

# Match project by name (case-insensitive)
read -r PROJECT_ID PROJECT_IDENTIFIER TODO_STATE DONE_STATE < <(python3 -c "
import json, sys, urllib.request

data = json.loads('''$PROJECT_INFO''')
results = data.get('results', data) if isinstance(data, dict) else data
repo_name = '${NAME}'.lower()

for p in results:
    if p['name'].lower() == repo_name:
        pid = p['id']
        ident = p['identifier']
        # Fetch states for this project
        url = '${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/' + pid + '/states/'
        req = urllib.request.Request(url, headers={'X-Api-Key': '${PLANE_API_TOKEN}'})
        with urllib.request.urlopen(req) as r:
            states = json.loads(r.read())
            state_list = states.get('results', states) if isinstance(states, dict) else states
            todo = done = ''
            for s in state_list:
                if s['group'] == 'unstarted' and not todo:
                    todo = s['id']
                elif s['group'] == 'completed' and not done:
                    done = s['id']
            print(f'{pid} {ident} {todo} {done}')
            sys.exit(0)

# No matching project found
sys.exit(1)
" 2>/dev/null) || {
    log "SKIP: No Plane project matching '${NAME}' in workspace '${PLANE_WORKSPACE}'"
    exit 0
}

log "Syncing issues: Plane ${PROJECT_IDENTIFIER} ↔ github.com/${GH_REPO}"

exec python3 "$(dirname "$0")/issue-sync-core.py" \
    --plane-url "$PLANE_URL" \
    --plane-token "$PLANE_API_TOKEN" \
    --plane-workspace "$PLANE_WORKSPACE" \
    --plane-project-id "$PROJECT_ID" \
    --plane-project-identifier "$PROJECT_IDENTIFIER" \
    --github-repo "$GH_REPO" \
    --todo-state-id "$TODO_STATE" \
    --done-state-id "$DONE_STATE"
