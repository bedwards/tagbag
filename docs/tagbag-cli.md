# TagBag CLI Reference

Unified CLI for TagBag — wraps Gitea, Plane, and Woodpecker CI under one tool.

**Location:** `cli/tagbag`

## Quick Start

```bash
# Set tokens (one-time)
export GITEA_TOKEN="your-gitea-api-token"
export PLANE_API_TOKEN="your-plane-api-key"
export WOODPECKER_TOKEN="your-woodpecker-token"

# Check service status
./cli/tagbag status

# Create a repo, file an issue, trigger CI
./cli/tagbag gitea create-repo --name my-project
./cli/tagbag plane create-issue my-workspace $PROJECT_ID --name "Build the thing" --priority high
./cli/tagbag ci activate bedwards/my-project
./cli/tagbag ci trigger bedwards/my-project --branch main
```

## Global Options

| Option | Env Var | Default | Description |
|---|---|---|---|
| `--plane-url URL` | `PLANE_URL` | `http://localhost:8080` | Plane API base URL |
| `--plane-token TOKEN` | `PLANE_API_TOKEN` | — | Plane API key |
| `--gitea-url URL` | `GITEA_URL` | `http://localhost:3000` | Gitea base URL |
| `--gitea-token TOKEN` | `GITEA_TOKEN` | — | Gitea personal access token |
| `--woodpecker-url URL` | `WOODPECKER_URL` | `http://localhost:9080` | Woodpecker base URL |
| `--woodpecker-token TOKEN` | `WOODPECKER_TOKEN` | — | Woodpecker API token |
| `--json` | — | — | Force JSON output |
| `--quiet` / `-q` | — | — | Suppress info messages |
| `--help` / `-h` | — | — | Show help at any level |

## Infrastructure Commands

```bash
tagbag status                    # show all service status + endpoints
tagbag up                        # docker compose up -d
tagbag up gitea                  # start just gitea
tagbag down                      # docker compose down
tagbag build                     # rebuild all from source
tagbag build plane-api           # rebuild single service
tagbag logs                      # tail all logs
tagbag logs woodpecker-server    # tail specific service
```

## Plane Commands (Issues/Projects)

### Workspaces & Projects
```bash
tagbag plane me                                     # current user
tagbag plane workspaces
tagbag plane projects <workspace-slug>
tagbag plane members <workspace-slug>
```

### Work Items (Issues)
```bash
# List work items
tagbag plane work-items <workspace> <project-id>
tagbag plane work-items <workspace> <project-id> --expand assignees,labels --order -created_at

# Get single work item (by UUID or human-readable ID)
tagbag plane work-item <workspace> <project-id> <uuid>
tagbag plane work-item <workspace> PROJ-123          # shorthand lookup

# Search across projects
tagbag plane search <workspace> --query "login bug" --limit 10

# Create work item
tagbag plane create-work-item <workspace> <project-id> \
  --name "Fix login bug" \
  --description "<p>Users can't log in after password reset</p>" \
  --priority high \
  --state <state-uuid> \
  --assignee <user-uuid> \
  --label <label-uuid>

# Update work item
tagbag plane update-work-item <workspace> <project-id> <uuid> \
  --priority urgent \
  --state <new-state-uuid>

# Delete work item
tagbag plane delete-work-item <workspace> <project-id> <uuid>
```

### Work Item Metadata
```bash
tagbag plane states <workspace> <project-id>    # workflow states
tagbag plane labels <workspace> <project-id>     # project labels
tagbag plane cycles <workspace> <project-id>     # sprints/cycles
tagbag plane modules <workspace> <project-id>    # modules
```

### Comments & Activities
```bash
tagbag plane comments <workspace> <project-id> <work-item-id>
tagbag plane add-comment <workspace> <project-id> <work-item-id> \
  --body "Working on this now"
tagbag plane activities <workspace> <project-id> <work-item-id>
```

### Raw API Access
```bash
# Any Plane API endpoint
tagbag plane api GET /workspaces/
tagbag plane api POST /workspaces/my-ws/projects/ -d '{"name":"new-proj"}'
```

## Gitea Commands (Git/PRs/Code Review)

### Repositories
```bash
tagbag gitea repos                                    # list your repos
tagbag gitea repo bedwards/my-project                 # repo details
tagbag gitea create-repo --name my-project --private  # create repo
```

### Pull Requests
```bash
# List open PRs
tagbag gitea prs bedwards/my-project

# Get PR details
tagbag gitea pr bedwards/my-project 42

# Create PR
tagbag gitea create-pr bedwards/my-project \
  --title "Add login feature" \
  --body "Implements login per issue PROJ-123" \
  --head feature-branch \
  --base main

# Merge PR
tagbag gitea merge-pr bedwards/my-project 42 --method squash
```

### Issues & Orgs
```bash
tagbag gitea issues bedwards/my-project   # list issues (Gitea-native)
tagbag gitea orgs                         # list organizations
tagbag gitea users                        # list users (admin only)
tagbag gitea webhooks bedwards/my-project # list webhooks
```

### Pass-through & Raw API
```bash
# Delegate to tea CLI directly
tagbag gitea tea repos ls
tagbag gitea tea pr create --repo my-project --head feature --base main

# Raw API call
tagbag gitea api GET /repos/bedwards/my-project/branches
tagbag gitea api POST /orgs -d '{"username":"my-org","visibility":"public"}'
```

## CI Commands (Woodpecker Pipelines)

### Repository Management
```bash
tagbag ci repos                          # list activated repos
tagbag ci repo bedwards/my-project       # repo details
tagbag ci activate bedwards/my-project   # activate repo for CI
```

### Pipelines
```bash
# List pipelines
tagbag ci pipelines bedwards/my-project

# Get pipeline details
tagbag ci pipeline bedwards/my-project 5

# Trigger pipeline manually
tagbag ci trigger bedwards/my-project --branch main

# Stop running pipeline
tagbag ci stop bedwards/my-project 5

# View step logs
tagbag ci logs bedwards/my-project 5 1
```

### Secrets
```bash
tagbag ci secrets bedwards/my-project
tagbag ci add-secret bedwards/my-project --name DEPLOY_KEY --value "secret-value"
tagbag ci rm-secret bedwards/my-project DEPLOY_KEY
```

### Pass-through & Raw API
```bash
# Delegate to woodpecker-cli directly
tagbag ci wp repo ls

# Raw API call
tagbag ci api GET /version
tagbag ci api GET /user/repos
```

## Token Setup

### Gitea Token
1. Go to http://localhost:3000/user/settings/applications
2. Under "Manage Access Tokens", create a token with `repo`, `admin:org`, `admin:repo_hook` scopes
3. `export GITEA_TOKEN=<token>`

### Plane API Key
1. Go to http://localhost:8080 → workspace settings → API Tokens
2. Create a token
3. `export PLANE_API_TOKEN=<token>`

### Woodpecker Token
1. Go to http://localhost:9080 (log in via Gitea OAuth)
2. Click user icon → Personal Access Token
3. `export WOODPECKER_TOKEN=<token>`

### Persist tokens
```bash
# Add to ~/.bashrc or ~/.zshrc
export GITEA_TOKEN="..."
export PLANE_API_TOKEN="..."
export WOODPECKER_TOKEN="..."
```

## Architecture

The CLI is a bash script that:
- Uses `curl` + `jq` for all API calls (no binary dependencies beyond standard tools)
- Wraps `tea` (Gitea CLI) and `woodpecker-cli` for pass-through when needed
- Resolves `docker-compose.yml` relative to its own location for infra commands
- Supports `--` separator for passing raw args to wrapped CLIs
