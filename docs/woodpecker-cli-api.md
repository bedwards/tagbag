# Woodpecker CI CLI & API Reference

## woodpecker-cli

### Installation

Ships with Woodpecker server build, or:
```bash
# From our submodule
cd submodules/woodpecker && make build-cli
# Binary at dist/woodpecker-cli
```

### Configuration

```bash
# Interactive setup (opens browser for token)
woodpecker-cli setup http://localhost:9080

# Or explicit
woodpecker-cli setup --server http://localhost:9080 --token YOUR_TOKEN --context local

# Multi-server contexts
woodpecker-cli context ls
woodpecker-cli context use local
```

**Env vars:** `WOODPECKER_SERVER`, `WOODPECKER_TOKEN`

### Command Tree

```
woodpecker-cli
  setup                             # First-time config
  update                            # Self-update
  info                              # Current user
  lint <file>                       # Validate pipeline YAML
  exec <file>                       # Run pipeline locally

  context (ctx)
    list|use|delete|rename

  repo
    add|ls|show|update|rm|chown|repair|sync
    secret   add|ls|show|update|rm
    registry add|ls|show|update|rm
    cron     add|ls|show|update|rm

  pipeline
    create <repo> --branch <b>      # Trigger pipeline
    ls|show|last|start|stop|kill
    approve|decline|purge
    ps <repo> <num>                  # Show steps
    queue                            # Global queue
    log show|purge
    deploy <repo> <num> <env>

  org
    secret   add|ls|show|update|rm
    registry add|ls|show|update|rm

  admin
    log-level
    org ls
    secret|registry add|ls|show|update|rm
    user add|ls|show|rm
```

### Key Examples

```bash
# Trigger a pipeline
woodpecker-cli pipeline create myorg/myrepo --branch main
woodpecker-cli pipeline create myorg/myrepo --branch main --var DEPLOY=true

# List and view
woodpecker-cli pipeline ls myorg/myrepo
woodpecker-cli pipeline show myorg/myrepo 42
woodpecker-cli pipeline last myorg/myrepo

# Logs
woodpecker-cli pipeline log show myorg/myrepo 42       # all steps
woodpecker-cli pipeline log show myorg/myrepo 42 build  # specific step

# Secrets
woodpecker-cli repo secret add myorg/myrepo --name TOKEN --value s3cr3t
woodpecker-cli repo secret add myorg/myrepo --name SSH_KEY --value @~/.ssh/id_rsa  # from file
woodpecker-cli repo secret ls myorg/myrepo

# Cron
woodpecker-cli repo cron add myorg/myrepo --name nightly --schedule "0 0 * * *" --branch main

# Deploy
woodpecker-cli pipeline deploy myorg/myrepo last production

# Repo management
woodpecker-cli repo sync
woodpecker-cli repo add 42  # forge_remote_id
woodpecker-cli repo repair myorg/myrepo
```

## REST API

**Base URL:** `http://localhost:9080/api`
**Auth:** `Authorization: Bearer YOUR_TOKEN`

### Key Endpoints

**User:**
```bash
GET    /api/user                       # Current user
GET    /api/user/repos                 # User's repos
POST   /api/user/token                 # Generate new PAT
```

**Repos:**
```bash
POST   /api/repos?forge_remote_id=ID   # Activate
GET    /api/repos/{repo_id}
PATCH  /api/repos/{repo_id}            # Update settings
DELETE /api/repos/{repo_id}            # Deactivate
GET    /api/repos/lookup/{full_name}   # Lookup by name
POST   /api/repos/{repo_id}/repair     # Fix webhooks
```

**Pipelines:**
```bash
POST   /api/repos/{id}/pipelines       # Trigger {branch, variables}
GET    /api/repos/{id}/pipelines       # List
GET    /api/repos/{id}/pipelines/{num} # Details
POST   /api/repos/{id}/pipelines/{num} # Restart
POST   /api/repos/{id}/pipelines/{num}/cancel
POST   /api/repos/{id}/pipelines/{num}/approve
POST   /api/repos/{id}/pipelines/{num}/decline
```

**Logs:**
```bash
GET    /api/repos/{id}/logs/{num}/{step_id}       # Step logs
GET    /api/stream/logs/{id}/{num}/{step_id}      # SSE stream
```

**Secrets (repo/org/global):**
```bash
GET    /api/repos/{id}/secrets
POST   /api/repos/{id}/secrets         # {name, value, events}
PATCH  /api/repos/{id}/secrets/{name}
DELETE /api/repos/{id}/secrets/{name}
# Same pattern for /api/orgs/{id}/secrets and /api/secrets (global)
```

**Cron:**
```bash
POST   /api/repos/{id}/cron            # {name, schedule, branch}
GET    /api/repos/{id}/cron
POST   /api/repos/{id}/cron/{cron_id}  # Trigger manually
```

**Agents:**
```bash
GET    /api/agents                     # List (admin)
POST   /api/agents                     # Create
```

**Queue:**
```bash
GET    /api/queue/info
POST   /api/queue/pause
POST   /api/queue/resume
```

## Pipeline YAML (.woodpecker.yaml)

### Basic

```yaml
steps:
  build:
    image: golang:1.26
    commands:
      - go build ./...
      - go test ./...
```

### Full syntax

```yaml
when:
  - event: [push, pull_request]
  - event: push
    branch: main

labels:
  platform: linux/amd64

steps:
  test:
    image: golang:1.26
    commands:
      - go test -v ./...
    when:
      - event: pull_request

  build:
    depends_on: [test]
    image: golang:1.26
    commands:
      - go build -o app ./cmd/

  publish:
    depends_on: [build]
    image: woodpeckerci/plugin-docker-buildx
    settings:
      repo: myorg/myapp
      tag: ${CI_COMMIT_TAG}
      password:
        from_secret: docker_password
    when:
      - event: tag

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: test
      POSTGRES_HOST_AUTH_METHOD: trust
```

### Matrix builds

```yaml
matrix:
  GO: [1.25, 1.26]
  DB: [postgres, sqlite]

steps:
  test:
    image: golang:${GO}
    commands:
      - go test -tags ${DB} ./...
```

### Multi-workflow

Place files in `.woodpecker/` directory — each runs as a parallel workflow:
```
.woodpecker/test.yaml
.woodpecker/build.yaml
.woodpecker/deploy.yaml
```
