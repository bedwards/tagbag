# TagBag Integration Architecture: Gitea + Plane + Woodpecker CI

How to replicate GitHub's unified experience across three independent services using webhooks, APIs, and a lightweight middleware bridge.

## Overview

GitHub's integration is monolithic -- issues, PRs, CI, and deployments live in one database. TagBag must achieve the same experience across three services that do not natively know about each other. The core strategy is a **webhook bridge service** (called `tagbag-bridge`) that receives events from all three systems and fans out API calls to keep them synchronized.

```
 Gitea                    Plane                   Woodpecker CI
  |                         |                         |
  |--- webhooks ----------->|                         |
  |                         |<--- webhooks --------- |
  |                         |                         |
  +----------- all webhooks flow through ------------>+
                    tagbag-bridge
              (lightweight HTTP service)
```

---

## 1. PR References in Issues (Auto-Close)

**GitHub behavior**: A commit message saying `fixes #123` links the PR to issue #123 and auto-closes it on merge.

### Mechanism: Gitea webhook -> tagbag-bridge -> Plane API

### How It Works

Gitea already parses `fixes #123` in commit messages to close **its own** issues. Since we use Plane for issues (not Gitea issues), we need to intercept these references and route them to Plane.

**Gitea webhook events to subscribe to:**
- `push` -- fires on every commit push, payload includes all commit messages
- `pull_request` -- fires on PR open/close/merge, payload includes PR description
- `pull_request_comment` -- fires on PR comments

**Commit message convention:**
```
feat: add user auth

Fixes PROJ-42
Closes PROJ-18
Refs PROJ-99
```

### Implementation

```python
# tagbag-bridge/handlers/gitea_push.py

import re
import requests

# Pattern: matches PROJ-123 style references
ISSUE_REF_PATTERN = re.compile(
    r'(?P<action>fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved|refs?)\s+'
    r'(?P<identifier>[A-Z]+-\d+)',
    re.IGNORECASE
)

def handle_push_event(payload):
    """Called when Gitea sends a push webhook."""
    commits = payload.get("commits", [])
    repo_url = payload["repository"]["html_url"]

    for commit in commits:
        message = commit["message"]
        sha = commit["id"][:8]
        author = commit["author"]["name"]

        for match in ISSUE_REF_PATTERN.finditer(message):
            action = match.group("action").lower()
            identifier = match.group("identifier")  # e.g. "PROJ-42"

            # 1. Add a comment to the Plane issue
            add_plane_comment(
                identifier=identifier,
                html=f'<p>Referenced in commit <a href="{repo_url}/commit/{commit["id"]}">'
                     f'<code>{sha}</code></a> by {author}: "{message.splitlines()[0]}"</p>',
                external_source="gitea",
                external_id=commit["id"],
            )

            # 2. Add a link to the Plane issue
            add_plane_link(
                identifier=identifier,
                title=f'Commit {sha}: {message.splitlines()[0]}',
                url=f'{repo_url}/commit/{commit["id"]}',
            )

            # 3. If action is close/fix/resolve, close the issue
            if action in ("fix", "fixes", "fixed", "close", "closes",
                          "closed", "resolve", "resolves", "resolved"):
                close_plane_issue(identifier)


def handle_pull_request_event(payload):
    """Called when a PR is opened, edited, or merged."""
    action = payload["action"]  # opened, closed, edited, etc.
    pr = payload["pull_request"]
    pr_url = pr["html_url"]
    pr_title = pr["title"]
    pr_number = pr["number"]
    merged = pr.get("merged", False)

    # Parse PR title + body for issue refs
    text = f'{pr["title"]} {pr.get("body", "")}'
    for match in ISSUE_REF_PATTERN.finditer(text):
        identifier = match.group("identifier")
        action_word = match.group("action").lower()

        if action == "opened":
            add_plane_comment(
                identifier=identifier,
                html=f'<p>Pull Request <a href="{pr_url}">#{pr_number} {pr_title}</a> '
                     f'opened referencing this issue.</p>',
                external_source="gitea",
                external_id=f"pr-{pr_number}",
            )
            add_plane_link(
                identifier=identifier,
                title=f'PR #{pr_number}: {pr_title}',
                url=pr_url,
            )

        elif action == "closed" and merged:
            if action_word in ("fix", "fixes", "fixed", "close", "closes",
                               "closed", "resolve", "resolves", "resolved"):
                close_plane_issue(identifier)
                add_plane_comment(
                    identifier=identifier,
                    html=f'<p>Closed by merge of <a href="{pr_url}">#{pr_number}</a>.</p>',
                    external_source="gitea",
                    external_id=f"pr-merge-{pr_number}",
                )
```

### Plane API Calls

```python
PLANE_API = "http://plane-proxy:80"  # internal Docker network
PLANE_API_KEY = os.environ["PLANE_API_KEY"]
WORKSPACE = os.environ["PLANE_WORKSPACE_SLUG"]
HEADERS = {"X-API-Key": PLANE_API_KEY, "Content-Type": "application/json"}

def get_plane_issue(identifier):
    """Fetch issue by identifier like PROJ-42.
    Uses: GET /api/v1/workspaces/{slug}/work-items/{identifier}/
    """
    resp = requests.get(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/work-items/{identifier}/",
        headers=HEADERS,
    )
    resp.raise_for_status()
    return resp.json()

def add_plane_comment(identifier, html, external_source="gitea", external_id=None):
    """Add a comment to a Plane work item.
    Uses: POST /api/v1/workspaces/{slug}/projects/{pid}/work-items/{iid}/comments/
    """
    issue = get_plane_issue(identifier)
    resp = requests.post(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{issue['project']}/"
        f"work-items/{issue['id']}/comments/",
        headers=HEADERS,
        json={
            "comment_html": html,
            "external_source": external_source,
            "external_id": external_id or "",
        },
    )
    resp.raise_for_status()

def add_plane_link(identifier, title, url):
    """Add an external link to a Plane work item.
    Uses: POST /api/v1/workspaces/{slug}/projects/{pid}/issues/{iid}/links/
    """
    issue = get_plane_issue(identifier)
    resp = requests.post(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{issue['project']}/"
        f"issues/{issue['id']}/links/",
        headers=HEADERS,
        json={"title": title, "url": url},
    )
    resp.raise_for_status()

def close_plane_issue(identifier):
    """Transition a Plane work item to the 'Done'/'Closed' state.
    Uses: PATCH /api/v1/workspaces/{slug}/projects/{pid}/work-items/{iid}/
    Requires knowing the project's 'Done' state UUID.
    """
    issue = get_plane_issue(identifier)
    done_state = get_done_state(issue["project"])
    resp = requests.patch(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{issue['project']}/"
        f"work-items/{issue['id']}/",
        headers=HEADERS,
        json={"state": done_state},
    )
    resp.raise_for_status()

def get_done_state(project_id):
    """Get the 'Done'/'Closed' state UUID for a project.
    Uses: GET /api/v1/workspaces/{slug}/projects/{pid}/states/
    Caches results per project.
    """
    resp = requests.get(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{project_id}/states/",
        headers=HEADERS,
    )
    resp.raise_for_status()
    states = resp.json()["results"]
    # Plane states have groups: backlog, unstarted, started, completed, cancelled
    for state in states:
        if state["group"] == "completed":
            return state["id"]
    raise ValueError(f"No completed state found for project {project_id}")
```

### Existing Tools That Help

- **Gitea Actions** (Jira-style approach): Use `.gitea/workflows/` YAML to run a script on push/PR events directly in Gitea's built-in CI. This avoids needing a separate bridge for this specific integration. See the [Gitea-Jira tutorial](https://about.gitea.com/resources/tutorials/gitea-integrate-with-jira-issue-tracking-flow) for the pattern.
- **n8n**: Self-hosted workflow automation with built-in Gitea node. Can receive Gitea webhooks and make HTTP requests to Plane API. No-code alternative to the bridge service.

---

## 2. CI Status on PRs

**GitHub behavior**: Green checkmark / red X on PRs from CI runs.

### Mechanism: Woodpecker -> Gitea (already built in)

### How It Works

This integration **already works out of the box**. Woodpecker CI's Gitea forge implementation uses the Gitea Commit Status API to report pipeline results.

**Gitea Commit Status API endpoint:**
```
POST /api/v1/repos/{owner}/{repo}/statuses/{sha}
```

**Payload:**
```json
{
  "state": "success",         // pending | success | error | failure | warning
  "target_url": "http://localhost:9080/repos/1/pipeline/5",
  "description": "Build succeeded",
  "context": "woodpecker/pr/pipeline/5/1"
}
```

**Woodpecker status mapping:**

| Woodpecker State | Gitea Status |
|------------------|-------------|
| Pending          | pending     |
| Running          | pending     |
| Success          | success     |
| Failure          | failure     |
| Killed           | error       |
| Error            | error       |
| Skipped          | warning     |
| Blocked          | pending     |

### Verification Steps

1. Create a repo in Gitea with a `.woodpecker.yml`
2. Enable the repo in Woodpecker (http://localhost:9080)
3. Open a PR in Gitea
4. Confirm the CI status appears as a check on the PR page
5. The commit status icon (green check / red X) appears next to the commit SHA

### No Additional Work Needed

Woodpecker automatically:
- Creates webhooks on Gitea repos when activated
- Receives push/PR events via those webhooks
- Reports commit statuses back via the Gitea API
- Displays pipeline links in the status context URL

---

## 3. Issue References in PR Descriptions

**GitHub behavior**: When a PR description mentions `#123`, it renders as a clickable link showing the issue title.

### Mechanism: Gitea webhook -> tagbag-bridge -> Gitea API (PR description enrichment)

### Option A: PR Description Template (Simple)

Add a PR template that prompts developers to include Plane links:

```markdown
<!-- .gitea/pull_request_template.md -->
## Related Issues
<!-- Link Plane issues: http://localhost:8080/WORKSPACE/projects/PROJECT/issues/PROJ-123 -->

## Changes
<!-- Describe your changes -->
```

### Option B: Automated Enrichment via Bridge (Rich)

When a PR is opened, the bridge parses the description for `PROJ-123` references, fetches the issue details from Plane, and appends a summary table to the PR description via the Gitea API.

```python
def enrich_pr_description(payload):
    """On PR open/edit, add Plane issue details to description."""
    pr = payload["pull_request"]
    body = pr.get("body", "") or ""
    repo = payload["repository"]

    # Find all PROJ-123 references
    refs = re.findall(r'[A-Z]+-\d+', body)
    if not refs:
        return

    # Build issue summary table
    table_lines = ["\n\n---\n### Linked Plane Issues\n",
                   "| Issue | Title | State | Priority | Assignees |",
                   "|-------|-------|-------|----------|-----------|"]

    for ref in set(refs):
        try:
            issue = get_plane_issue(ref)
            assignees = ", ".join(a.get("display_name", "?")
                                 for a in issue.get("assignees", []))
            plane_url = f"http://localhost:8080/{WORKSPACE}/projects/{issue['project']}/issues/{ref}"
            table_lines.append(
                f"| [{ref}]({plane_url}) | {issue['name']} | "
                f"{issue.get('state_detail', {}).get('name', '?')} | "
                f"{issue.get('priority', 'none')} | {assignees} |"
            )
        except Exception:
            table_lines.append(f"| {ref} | (not found) | - | - | - |")

    # Update PR description via Gitea API
    new_body = strip_old_table(body) + "\n".join(table_lines)
    requests.patch(
        f"http://gitea:3000/api/v1/repos/{repo['owner']['login']}/{repo['name']}"
        f"/pulls/{pr['number']}",
        headers={"Authorization": f"token {GITEA_API_TOKEN}"},
        json={"body": new_body},
    )
```

### Gitea API for Updating PR Description

```
PATCH /api/v1/repos/{owner}/{repo}/pulls/{index}
Authorization: token {GITEA_API_TOKEN}
Content-Type: application/json

{"body": "updated PR description with issue table"}
```

---

## 4. Branch-to-Issue Linking

**GitHub behavior**: Creating a branch from an issue page links them automatically.

### Mechanism: Gitea webhook (`create` event) -> tagbag-bridge -> Plane API

### Branch Naming Conventions

```
PROJ-123-add-auth          # Project identifier prefix
feature/PROJ-42-new-ui     # With category prefix
issue-123                  # Numeric-only (requires default project config)
```

### Implementation

```python
BRANCH_PATTERN = re.compile(
    r'(?:^|/)(?P<identifier>[A-Z]+-\d+)',  # matches PROJ-123 anywhere in branch name
    re.IGNORECASE
)

def handle_create_event(payload):
    """Gitea 'create' webhook -- fires when a branch or tag is created."""
    if payload["ref_type"] != "branch":
        return

    branch_name = payload["ref"]
    repo_url = payload["repository"]["html_url"]

    match = BRANCH_PATTERN.search(branch_name)
    if not match:
        return

    identifier = match.group("identifier").upper()

    # Transition issue to "In Progress"
    try:
        issue = get_plane_issue(identifier)
        in_progress_state = get_in_progress_state(issue["project"])
        if in_progress_state and issue["state"] != in_progress_state:
            requests.patch(
                f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{issue['project']}/"
                f"work-items/{issue['id']}/",
                headers=HEADERS,
                json={"state": in_progress_state},
            )

        # Add a comment noting the branch creation
        add_plane_comment(
            identifier=identifier,
            html=f'<p>Branch <code>{branch_name}</code> created in '
                 f'<a href="{repo_url}">{payload["repository"]["full_name"]}</a>.</p>',
            external_source="gitea",
            external_id=f"branch-{branch_name}",
        )
    except Exception as e:
        logging.warning(f"Failed to link branch {branch_name} to {identifier}: {e}")


def get_in_progress_state(project_id):
    """Get the 'In Progress' / 'started' state UUID."""
    resp = requests.get(
        f"{PLANE_API}/api/v1/workspaces/{WORKSPACE}/projects/{project_id}/states/",
        headers=HEADERS,
    )
    states = resp.json()["results"]
    for state in states:
        if state["group"] == "started":
            return state["id"]
    return None
```

### Gitea Webhook Event

Subscribe to the `create` event type. Payload includes:
```json
{
  "ref": "PROJ-42-new-feature",
  "ref_type": "branch",
  "repository": { ... },
  "sender": { ... }
}
```

---

## 5. Deploy Status in Plane

**GitHub behavior**: Deployments show up in the issue/PR timeline with environment links.

### Mechanism: Woodpecker pipeline step -> Plane API (via webhook plugin or curl)

### Option A: Woodpecker Pipeline Step (Recommended)

Add a notification step at the end of your `.woodpecker.yml`:

```yaml
steps:
  - name: deploy
    image: your-deploy-image
    commands:
      - ./deploy.sh

  - name: notify-plane
    image: curlimages/curl:latest
    when:
      - event: [push, tag]
        branch: main
      - status: [success, failure]
    environment:
      PLANE_API_KEY:
        from_secret: plane_api_key
    commands:
      - |
        STATUS="${CI_PIPELINE_STATUS}"
        if [ "$STATUS" = "success" ]; then
          EMOJI="deployed"
          STATE_ACTION="completed"
        else
          EMOJI="failed"
          STATE_ACTION="none"
        fi

        # Extract issue refs from commit message
        REFS=$(echo "${CI_COMMIT_MESSAGE}" | grep -oE '[A-Z]+-[0-9]+' | sort -u)

        for REF in $REFS; do
          # Add deployment comment to Plane issue
          curl -s -X POST \
            "http://plane-proxy:80/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/${REF}/" \
            -H "X-API-Key: ${PLANE_API_KEY}" \
            -H "Content-Type: application/json"

          # We need the project_id and issue_id, so fetch first
          ISSUE=$(curl -s \
            "http://plane-proxy:80/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/${REF}/" \
            -H "X-API-Key: ${PLANE_API_KEY}")

          PROJECT_ID=$(echo "$ISSUE" | jq -r '.project')
          ISSUE_ID=$(echo "$ISSUE" | jq -r '.id')

          curl -s -X POST \
            "http://plane-proxy:80/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PROJECT_ID}/work-items/${ISSUE_ID}/comments/" \
            -H "X-API-Key: ${PLANE_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{
              \"comment_html\": \"<p>Deployment ${STATE_ACTION}: pipeline <a href='${CI_PIPELINE_FORGE_URL}'>#${CI_PIPELINE_NUMBER}</a> on branch <code>${CI_COMMIT_BRANCH}</code> (${CI_COMMIT_SHA:0:8})</p>\",
              \"external_source\": \"woodpecker\",
              \"external_id\": \"deploy-${CI_PIPELINE_NUMBER}\"
            }"
        done
```

### Option B: Woodpecker Webhook Plugin

```yaml
steps:
  - name: notify-plane-deploy
    image: woodpeckerci/plugin-webhook
    when:
      - status: [success, failure]
    settings:
      urls:
        from_secret: tagbag_bridge_url
      content_type: application/json
      template: |
        {
          "event": "deployment",
          "status": "{{build.status}}",
          "repo": "{{repo.name}}",
          "branch": "{{build.branch}}",
          "commit": "{{build.commit}}",
          "message": "{{build.message}}",
          "pipeline_url": "{{build.link}}",
          "pipeline_number": {{build.number}}
        }
```

The bridge service then parses the commit message for issue refs and updates Plane.

### Option C: Plane Webhook (Reverse Direction)

Plane sends webhooks on issue state changes. Subscribe to Plane webhooks in the bridge to trigger Woodpecker deployments when issues move to specific states (e.g., "Ready to Deploy").

---

## 6. Unified Activity Feeds

**GitHub behavior**: A single activity timeline showing commits, PR reviews, CI runs, and issue updates.

### Mechanism: tagbag-bridge aggregation service + database

### Architecture

There is no single built-in unified feed across these three services. Two approaches:

### Option A: Plane as the Hub (Recommended)

Use Plane's work item activity + comments as the unified timeline. Every significant event from Gitea and Woodpecker gets written as a Plane comment with `external_source` set appropriately.

**Events to capture:**

| Source | Event | Plane Action |
|--------|-------|-------------|
| Gitea | Push with issue ref | Comment: "Commit abc1234 pushed by user" |
| Gitea | PR opened | Comment: "PR #5 opened" + Link |
| Gitea | PR merged | Comment: "PR #5 merged" + State change |
| Gitea | PR review | Comment: "PR #5 approved by reviewer" |
| Gitea | Branch created | Comment: "Branch feature/PROJ-42 created" |
| Woodpecker | Pipeline success | Comment: "CI pipeline #12 passed" |
| Woodpecker | Pipeline failure | Comment: "CI pipeline #12 failed" |
| Woodpecker | Deploy complete | Comment: "Deployed to production via pipeline #15" |

All comments use the `external_source` and `external_id` fields to:
- Identify the origin system
- Prevent duplicate comments on retries (idempotency)

### Option B: Dedicated Activity Service

Build a lightweight aggregation service that:
1. Subscribes to webhooks from all three services
2. Stores events in a normalized `events` table in PostgreSQL
3. Exposes a REST API: `GET /api/activity?issue=PROJ-42`
4. Provides a simple web UI or feeds into the tagbag CLI

```sql
CREATE TABLE activity_feed (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source     TEXT NOT NULL,  -- 'gitea', 'plane', 'woodpecker'
    event_type TEXT NOT NULL,  -- 'push', 'pr_opened', 'pipeline_success', etc.
    identifier TEXT,           -- 'PROJ-42' (nullable)
    repo       TEXT,           -- 'owner/repo' (nullable)
    actor      TEXT NOT NULL,
    title      TEXT NOT NULL,
    url        TEXT,
    payload    JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_activity_identifier ON activity_feed(identifier);
CREATE INDEX idx_activity_created ON activity_feed(created_at DESC);
```

---

## 7. Cross-Linking (URLs and References)

**GitHub behavior**: `#123` is clickable everywhere -- issues, PRs, comments, commit messages.

### Mechanism: Multiple approaches working together

### 7a. Gitea External Issue Tracker (Built-in)

Gitea has native support for external issue trackers. Configure it per-repo:

```ini
# In Gitea repo settings -> External Issue Tracker
# Or via API: PATCH /api/v1/repos/{owner}/{repo}
{
  "has_issues": false,
  "external_tracker": {
    "external_tracker_url": "http://localhost:8080/{workspace}/projects/{project}/issues/{identifier}-{index}",
    "external_tracker_format": "PROJ-{index}",
    "external_tracker_style": "alphanumeric"
  }
}
```

When `external_tracker_style` is `alphanumeric`, Gitea will recognize `PROJ-123` patterns in commit messages and PR descriptions and render them as links to the external tracker URL.

**Limitation**: Gitea's external tracker support uses `!` for PR disambiguation and `#` for issues. With an alphanumeric external tracker, `PROJ-123` in commit messages will auto-link to the Plane URL.

### 7b. Plane-to-Gitea Links

When creating Plane issues that relate to code, add links via the API:

```python
def add_repo_link_to_issue(identifier, repo_owner, repo_name, branch=None):
    """Add a Gitea repository link to a Plane issue."""
    url = f"http://localhost:3000/{repo_owner}/{repo_name}"
    if branch:
        url += f"/src/branch/{branch}"
    add_plane_link(identifier, title=f"Repository: {repo_owner}/{repo_name}", url=url)
```

### 7c. Woodpecker-to-Plane Links

Woodpecker pipeline URLs follow the pattern:
```
http://localhost:9080/repos/{repo_id}/pipeline/{pipeline_number}
```

These get embedded in Plane comments by the bridge (see sections 1 and 5).

### 7d. URL Pattern Summary

| From | To | URL Pattern |
|------|----|-------------|
| Gitea commit message | Plane issue | `http://localhost:8080/{workspace}/projects/{project}/issues/PROJ-123` |
| Plane comment | Gitea PR | `http://localhost:3000/{owner}/{repo}/pulls/{number}` |
| Plane comment | Gitea commit | `http://localhost:3000/{owner}/{repo}/commit/{sha}` |
| Plane comment | Woodpecker pipeline | `http://localhost:9080/repos/{id}/pipeline/{number}` |
| Woodpecker pipeline | Gitea PR | Built-in via commit status `target_url` |
| Gitea PR | Woodpecker pipeline | Built-in via commit status checks display |

---

## Bridge Service Architecture

### docker-compose addition

```yaml
  tagbag-bridge:
    build:
      context: ./bridge
      dockerfile: Dockerfile
    restart: always
    environment:
      - GITEA_URL=http://gitea:3000
      - GITEA_API_TOKEN=${BRIDGE_GITEA_TOKEN}
      - PLANE_URL=http://plane-proxy:80
      - PLANE_API_KEY=${BRIDGE_PLANE_API_KEY}
      - PLANE_WORKSPACE=${PLANE_WORKSPACE_SLUG}
      - WOODPECKER_URL=http://woodpecker-server:8000
      - WOODPECKER_API_TOKEN=${BRIDGE_WOODPECKER_TOKEN}
      - WEBHOOK_SECRET=${BRIDGE_WEBHOOK_SECRET}
      - LISTEN_PORT=7070
    ports:
      - "7070:7070"
    depends_on:
      - gitea
      - plane-proxy
      - woodpecker-server
    networks:
      - tagbag
```

### Service Structure

```
bridge/
  Dockerfile
  requirements.txt          # flask, requests, hmac
  app.py                    # Flask app, webhook endpoint routing
  config.py                 # Environment config
  handlers/
    gitea_push.py           # Push events -> Plane comments/close
    gitea_pr.py             # PR events -> Plane comments/links/enrichment
    gitea_create.py         # Branch creation -> Plane state transitions
    plane_issue.py          # Plane issue events -> Gitea (future)
    woodpecker_deploy.py    # Deployment events -> Plane comments
  services/
    plane_client.py         # Plane API wrapper (get issue, comment, link, close)
    gitea_client.py         # Gitea API wrapper (update PR, commit status)
    cache.py                # LRU cache for state UUIDs, issue lookups
```

### Webhook Endpoints

```python
# app.py
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/webhooks/gitea", methods=["POST"])
def gitea_webhook():
    verify_gitea_signature(request)
    event = request.headers.get("X-Gitea-Event")
    payload = request.json

    if event == "push":
        handle_push_event(payload)
    elif event == "pull_request":
        handle_pull_request_event(payload)
    elif event == "create":
        handle_create_event(payload)
    elif event == "pull_request_comment":
        handle_pr_comment_event(payload)

    return jsonify({"status": "ok"}), 200

@app.route("/webhooks/plane", methods=["POST"])
def plane_webhook():
    verify_plane_signature(request)
    event = request.headers.get("X-Plane-Event")
    payload = request.json
    # Handle Plane -> Gitea direction (future)
    return jsonify({"status": "ok"}), 200

@app.route("/webhooks/woodpecker", methods=["POST"])
def woodpecker_webhook():
    # Receives deployment notifications from Woodpecker pipeline steps
    payload = request.json
    handle_deployment_event(payload)
    return jsonify({"status": "ok"}), 200

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"}), 200
```

### Webhook Registration

Register webhooks via API on startup or via setup script:

```bash
# Register Gitea org-level webhook (covers all repos)
curl -X POST "http://localhost:3000/api/v1/orgs/${ORG}/hooks" \
  -H "Authorization: token ${GITEA_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "gitea",
    "active": true,
    "config": {
      "url": "http://tagbag-bridge:7070/webhooks/gitea",
      "content_type": "json",
      "secret": "'${BRIDGE_WEBHOOK_SECRET}'"
    },
    "events": ["push", "pull_request", "pull_request_comment", "create"],
    "authorization_header": ""
  }'

# Register Plane workspace webhook (via Plane UI or API)
# Navigate to: Plane -> Workspace Settings -> Webhooks -> Add Webhook
# URL: http://tagbag-bridge:7070/webhooks/plane
# Events: Issue (create, update, delete), Issue Comment (create)
```

---

## API Reference Summary

### Gitea API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/v1/repos/{owner}/{repo}/hooks` | Create repo webhook |
| POST | `/api/v1/orgs/{org}/hooks` | Create org-level webhook |
| POST | `/api/v1/repos/{owner}/{repo}/statuses/{sha}` | Create commit status (Woodpecker does this) |
| GET | `/api/v1/repos/{owner}/{repo}/statuses/{sha}` | List commit statuses |
| PATCH | `/api/v1/repos/{owner}/{repo}/pulls/{index}` | Update PR description |
| PATCH | `/api/v1/repos/{owner}/{repo}` | Configure external issue tracker |

### Plane API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/v1/workspaces/{slug}/work-items/{PROJ-123}/` | Get issue by identifier |
| PATCH | `/api/v1/workspaces/{slug}/projects/{pid}/work-items/{iid}/` | Update issue (state change) |
| POST | `/api/v1/workspaces/{slug}/projects/{pid}/work-items/{iid}/comments/` | Add comment |
| POST | `/api/v1/workspaces/{slug}/projects/{pid}/issues/{iid}/links/` | Add external link |
| GET | `/api/v1/workspaces/{slug}/projects/{pid}/states/` | List project states |

### Woodpecker API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/repos/{repo_id}/pipelines` | List pipelines |
| GET | `/api/repos/{repo_id}/pipelines/{number}` | Get pipeline status |

---

## Implementation Priority

| Priority | Integration | Effort | Value |
|----------|------------|--------|-------|
| 0 (done) | CI status on PRs | None | High -- already works via Woodpecker forge |
| 1 | PR refs in issues (auto-close) | Medium | High -- core workflow |
| 2 | Branch-to-issue linking | Low | Medium -- state transitions |
| 3 | Issue refs in PR descriptions | Low | Medium -- visibility |
| 4 | Deploy status in Plane | Low | Medium -- pipeline step only |
| 5 | Cross-linking URLs | Low | Medium -- Gitea external tracker config |
| 6 | Unified activity feeds | High | Lower -- Plane-as-hub approach is medium effort |

### Suggested Rollout

**Phase 1** (bridge MVP): Build the bridge service handling `push` and `pull_request` events. Parse `PROJ-123` from commit messages. Add comments and links to Plane. Close issues on merge. This covers integrations 1, 3, and 4.

**Phase 2** (branch + deploy): Add `create` event handling for branch linking. Add the Woodpecker pipeline notification step. This covers integrations 2 and 5.

**Phase 3** (polish): Configure Gitea external issue tracker for URL auto-linking. Build Plane-as-hub activity by ensuring all events write comments. This covers integrations 6 and 7.

---

## Alternative: Gitea Actions Instead of Bridge

If you prefer not to run a separate bridge service, Gitea Actions (built-in CI similar to GitHub Actions) can handle the Plane API calls directly. Create `.gitea/workflows/plane-sync.yml` in each repo:

```yaml
name: Sync to Plane
on:
  push:
    branches: ["*"]
  pull_request:
    types: [opened, closed]

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Parse and sync issue references
        env:
          PLANE_API_KEY: ${{ secrets.PLANE_API_KEY }}
          PLANE_WORKSPACE: ${{ secrets.PLANE_WORKSPACE }}
          PLANE_URL: http://plane-proxy:80
        run: |
          # Extract PROJ-123 references from commit messages
          REFS=$(echo "${{ github.event.head_commit.message }}" | grep -oE '[A-Z]+-[0-9]+' | sort -u)
          for REF in $REFS; do
            curl -s -X POST "${PLANE_URL}/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/${REF}/" \
              -H "X-API-Key: ${PLANE_API_KEY}" \
              -H "Content-Type: application/json"
            # ... (similar to bridge logic)
          done
```

**Trade-offs**: Per-repo config vs. centralized bridge. The bridge is better for consistency across all repos.

---

## Existing Tools and Plugins

| Tool | What It Does | Relevance |
|------|-------------|-----------|
| [Plane MCP Server](https://github.com/makeplane/plane-mcp-server) | Official MCP server for AI agents to interact with Plane | Could power Claude-based automation |
| [n8n](https://n8n.io/integrations/gitea/) | Self-hosted workflow automation with Gitea node | No-code alternative to the bridge |
| [Woodpecker Webhook Plugin](https://woodpecker-ci.org/plugins) | Send HTTP requests from pipeline steps | Deploy notifications to bridge/Plane |
| [Gitea-Jira Action](https://github.com/appleboy/jira-action) | Gitea Action for Jira sync | Pattern to adapt for Plane |
| Gitea External Issue Tracker | Built-in Gitea feature | Auto-link `PROJ-123` to Plane URLs |
| Plane Webhooks | Built-in Plane feature | Reverse direction: Plane -> Gitea/Woodpecker |

---

## Environment Variables to Add

```bash
# .env additions for bridge service
BRIDGE_GITEA_TOKEN=           # Gitea API token with repo scope
BRIDGE_PLANE_API_KEY=         # Plane personal access token
BRIDGE_WOODPECKER_TOKEN=      # Woodpecker API token
BRIDGE_WEBHOOK_SECRET=        # Shared secret for webhook HMAC verification
PLANE_WORKSPACE_SLUG=         # Your Plane workspace slug
```
