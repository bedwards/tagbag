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

## Git Operations

### clone

Clone a Gitea repository by owner/repo shorthand.

```bash
tagbag clone <owner/repo> [path] [--ssh]
```

| Argument / Option | Description |
|---|---|
| `<owner/repo>` | Repository to clone (e.g. `bedwards/my-project`) |
| `[path]` | Optional local directory to clone into (defaults to repo name) |
| `--ssh` | Clone via SSH (`ssh://git@localhost:2222`) instead of HTTP |

Examples:

```bash
tagbag clone bedwards/my-project                    # clone via HTTP to ./my-project
tagbag clone bedwards/my-project ~/src/myproj       # clone to custom path
tagbag clone bedwards/my-project --ssh              # clone via SSH (port 2222)
```

### web

Open the current repository's Gitea page in the default browser. Must be run from within a Gitea-hosted git repo.

```bash
tagbag web
```

### push

Push a local repository to Gitea, with options for GitHub mirroring.

```bash
tagbag push <owner/repo> [options]
```

| Option | Description |
|---|---|
| `--github` | Also push to GitHub |
| `--create` | Create the remote repository if it doesn't exist |
| `--private` | Make the created repository private |
| `--mirror` | Set up as a mirror (read-only copy) |
| `--branch <name>` | Push only this branch (default: all branches) |
| `--no-tags` | Don't push tags |

Examples:

```bash
tagbag push bedwards/my-project --create --private   # create private repo and push
tagbag push bedwards/my-project --github              # push to both Gitea and GitHub
tagbag push bedwards/my-project --mirror              # set up as mirror
tagbag push bedwards/my-project --branch main --no-tags  # push only main, skip tags
```

## Reviewer Commands (AI Code Review)

The reviewer is an AI-powered code review service that watches Gitea pull requests and posts automated review comments.

```bash
tagbag reviewer start                # start the reviewer service
tagbag reviewer stop                 # stop the reviewer service
tagbag reviewer status               # check if the reviewer is running
tagbag reviewer logs                 # tail reviewer logs
tagbag reviewer register             # register the Gitea webhook for PR events
tagbag reviewer protect              # enable branch protection requiring reviewer approval
```

| Subcommand | Description |
|---|---|
| `start` | Start the reviewer container |
| `stop` | Stop the reviewer container |
| `status` | Show whether the reviewer is running and healthy |
| `logs` | Tail the reviewer service logs |
| `register` | Create a Gitea webhook on the current repo so the reviewer receives PR events |
| `protect` | Enable branch protection rules that require the reviewer's approval before merge |

## Bridge Commands (GitHub-Gitea Sync)

The bridge syncs repositories between GitHub and Gitea, enabling automatic mirroring and bi-directional webhook forwarding.

```bash
tagbag bridge start                  # start the bridge service
tagbag bridge stop                   # stop the bridge service
tagbag bridge status                 # check if the bridge is running
tagbag bridge logs                   # tail bridge logs
tagbag bridge register               # register webhooks for sync
```

| Subcommand | Description |
|---|---|
| `start` | Start the bridge container |
| `stop` | Stop the bridge container |
| `status` | Show whether the bridge is running and healthy |
| `logs` | Tail the bridge service logs |
| `register` | Set up webhooks on both GitHub and Gitea for automatic repository syncing |

## Architecture

The CLI is a bash script that:
- Uses `curl` + `jq` for all API calls (no binary dependencies beyond standard tools)
- Wraps `tea` (Gitea CLI) and `woodpecker-cli` for pass-through when needed
- Resolves `docker-compose.yml` relative to its own location for infra commands
- Supports `--` separator for passing raw args to wrapped CLIs
