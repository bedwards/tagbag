# Woodpecker CI Hacking Guide

## Architecture

Go v3 module with Vue 3 frontend. Three binaries: server, agent, CLI. gRPC between server and agent.

```
cmd/
  server/         Server entry
  agent/          Agent entry
  cli/            CLI entry

server/
  api/            Gin HTTP handlers (one file per resource)
  router/         Route definitions (router.go, api.go)
  model/          XORM models
  store/          Store interface + datastore/ implementation
  forge/          Git forge integrations (github, gitlab, gitea, forgejo, bitbucket, addon)
  pipeline/       Server-side pipeline orchestration
  queue/          Work queue for distributing to agents
  pubsub/         SSE event streaming
  rpc/            Server-side gRPC impl

agent/            Agent runtime (runner.go)

pipeline/
  backend/        Execution backends: docker, kubernetes, local, dummy
  frontend/       YAML parsing + compilation
  runtime/        Step executor

rpc/proto/        Protobuf definitions (woodpecker.proto)
cli/              CLI command implementations
web/              Vue 3 SPA (Pinia, Tailwind, Vite)
woodpecker-go/    Go client library
```

## Key Patterns

### HTTP API (Gin)

Routes in `server/router/api.go`. Handlers in `server/api/` with Swagger annotations.

Middleware: `session.SetUser()` -> `token.Refresh` -> route-level auth (`session.MustUser()`, `session.MustAdmin()`).

### Database (XORM)

Models in `server/model/` with XORM struct tags. Store interface in `server/store/store.go` (~90 methods). Implementation in `server/store/datastore/`.

Migrations: `server/store/datastore/migration/` — numbered functions.

Supports: SQLite, PostgreSQL, MySQL.

### gRPC (Server <-> Agent)

Defined in `rpc/proto/woodpecker.proto`. Two services:

- `Woodpecker`: `Next()` (long-poll), `Init()`, `Wait()`, `Done()`, `Update()`, `Log()`, `Extend()`
- `WoodpeckerAuth`: agent token auth

The `Peer` interface (`rpc/peer.go`) is the Go contract.

### Forge Integration

Interface in `server/forge/forge.go` (~15 methods). Implementations:
- `server/forge/github/`
- `server/forge/gitlab/`
- `server/forge/gitea/`
- `server/forge/forgejo/`
- `server/forge/bitbucket/`
- `server/forge/addon/` (hashicorp/go-plugin for external forge binaries)

Factory: `server/forge/setup/setup.go`

### Pipeline Engine

1. YAML parsed in `pipeline/frontend/yaml/`
2. Compiled to backend config in `pipeline/frontend/yaml/compiler/`
3. Executed by runtime in `pipeline/runtime/`
4. Backends: `pipeline/backend/docker/`, `kubernetes/`, `local/`, `dummy/`

Backend interface: `SetupWorkflow`, `StartStep`, `TailStep`, `WaitStep`, `DestroyStep`

### Agent Runner Flow

1. `client.Next(filter)` — long-poll for workflow
2. `client.Init()` — signal start
3. `pipeline_runtime.New(config, backend).Run(ctx)` — execute
4. `client.Done()` — report result

Heartbeat via `client.Extend()` every TaskTimeout/3.

## Frontend (Vue 3)

```
web/src/
  views/          Page components
  components/     Reusable components
  compositions/   Vue composables
  store/          Pinia stores
  lib/            API client
  router.ts       All routes
```

Stack: Vue 3, Vue Router, Pinia, Tailwind CSS 4, Vite 8, TypeScript, vue-i18n.

## Dev Workflow

### Build
```bash
make install-tools        # golangci-lint, mockery, protoc-gen-go
make build                # all three binaries
make build-server         # server only (includes UI)
make build-agent
make build-cli
make build-ui             # Vue frontend only
```

### Dev Mode
```bash
# Frontend hot reload
cd web && pnpm install && pnpm start

# Backend: run Gitea for test forge
docker compose -f docker-compose.gitpod.yaml up -d
go run go.woodpecker-ci.org/woodpecker/v3/cmd/server
go run go.woodpecker-ci.org/woodpecker/v3/cmd/agent
```

### Testing
```bash
make test                 # all tests
make test-server          # server (excl. store)
make test-server-datastore # DB/migration tests
make test-ui              # lint + vitest
```

### Linting
```bash
make lint                 # golangci-lint
make format               # gofumpt
make generate-openapi     # regen Swagger spec
```

## Extension Points

| What | Where | Interface |
|---|---|---|
| New API endpoint | `server/api/` + `server/router/api.go` | Gin handler |
| New forge | `server/forge/yourforge/` | `forge.Forge` (15 methods) |
| New pipeline backend | `pipeline/backend/yours/` | `types.Backend` (10 methods) |
| New DB entity | `server/model/` + `server/store/` + migration | `Store` interface |
| New CLI command | `cli/` | urfave/cli command |
| Pipeline plugin | External Docker image | Container reading `PLUGIN_*` env vars |
| Forge addon | External binary | `forge.Forge` via hashicorp/go-plugin |

### Creating a Pipeline Plugin

1. Write logic in any language
2. Read `PLUGIN_*` env vars for settings
3. Package as Docker image with ENTRYPOINT
4. Use in YAML: `image: your-plugin` with `settings:`
