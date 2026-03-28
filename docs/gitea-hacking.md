# Gitea Hacking Guide

## Architecture

Go monolith using chi router, XORM ORM, Go HTML templates + webpack frontend.

```
cmd/              CLI entry (urfave/cli)
models/           XORM models (DB layer)
  models/issues/  Issue, PR, label, milestone, review, comment
  models/repo/    Repository
  models/user/    User
  models/actions/ Gitea Actions (CI)
  models/migrations/ Sequential DB migrations (v1_6 through v1_26)
modules/          Shared utilities (60+ packages, no business logic)
  modules/structs/  API request/response structs (shared with SDK)
  modules/git/      Low-level git operations
  modules/setting/  Config (app.ini)
  modules/webhook/  Webhook types/events
routers/          HTTP routing
  routers/web/      Web UI (HTML templates)
  routers/api/v1/   REST API (Swagger-annotated)
  routers/private/  Internal API (git hooks, localhost only)
services/         Business logic
  services/auth/    Auth middleware (OAuth2, Basic, Session, SSPI)
  services/webhook/ Webhook delivery (Slack, Discord, Telegram, etc.)
  services/notify/  Notifier pattern (all events)
  services/pull/    PR merge logic
  services/actions/ Gitea Actions orchestration
templates/        Go HTML templates
web_src/          Frontend (TypeScript, Vue components, CSS)
```

## Layer Discipline

`routers/` -> `services/` -> `models/`. Never call models directly from routers for writes.

## Key Patterns

### Models (XORM)

```go
type Issue struct {
    ID     int64  `xorm:"pk autoincr"`
    RepoID int64  `xorm:"INDEX UNIQUE(repo_index)"`
    Title  string `xorm:"name"`
    // Fields with xorm:"-" are loaded separately
}
```

Query: `db.GetEngine(ctx).Where("repo_id=?", id).Find(&issues)`
Transaction: `db.WithTx(ctx, func(ctx context.Context) error { ... })`

### API Handlers

In `routers/api/v1/`. Use `context.APIContext`. Swagger comment annotations above each handler. Request/response types in `modules/structs/`.

### Auth

Middleware chain tries: OAuth2 -> Basic -> ReverseProxy -> Session -> SSPI.
Token scopes enforced via `tokenRequiresScopes()`.

### Webhooks (Notifier Pattern)

1. `services/notify/notifier.go` — interface with method per event
2. `services/webhook/notifier.go` — converts events to payloads
3. Delivery backends: slack, discord, telegram, matrix, msteams, dingtalk, feishu

### Database Migrations

`models/migrations/` — sequential numbered functions. Each takes `*xorm.Engine`:
```go
func AddMyColumn(x *xorm.Engine) error {
    type MyTable struct {
        NewField string `xorm:"NOT NULL DEFAULT ''"`
    }
    return x.Sync(new(MyTable))
}
```
Register in `models/migrations/migrations.go`.

## Dev Workflow

### Prerequisites
Go (see go.mod), Node.js >= 22 + pnpm, Make, Git

### Build
```bash
pnpm install
make build           # frontend + backend -> ./gitea binary
make frontend        # webpack only
make backend         # go build only
```

### Dev Mode (Hot Reload)
```bash
make watch           # both frontend + backend
make watch-frontend  # webpack --watch
make watch-backend   # uses "air" (.air.toml config)
```

### Testing
```bash
make test                    # unit tests
make test-sqlite             # integration tests (also test-pgsql, test-mysql)
make test-frontend           # vitest
make test-e2e                # playwright
```

### Linting
```bash
make fmt                     # format Go + templates
make lint                    # golangci-lint + eslint + stylelint
make generate-swagger        # regen OpenAPI spec
```

## How To: Add a New API Endpoint

1. Define structs in `modules/structs/your_feature.go`
2. Add swagger references in `routers/api/v1/swagger/`
3. Write handler in `routers/api/v1/repo/your_feature.go`
4. Register route in `routers/api/v1/api.go`
5. Run `make generate-swagger`
6. Add tests in `tests/integration/`

## How To: Add a New Webhook Event

1. Add event constant in `modules/webhook/type.go`
2. Add method to Notifier interface in `services/notify/notifier.go`
3. Add null impl in `services/notify/null.go`
4. Implement in `services/webhook/notifier.go`
5. Fire event: `notify_service.YourEvent(ctx, ...)`

## How To: Add a New UI Page

1. Create template in `templates/your_area/page.tmpl`
2. Create handler in `routers/web/your_area/page.go`
3. Register route in `routers/web/web.go`
4. Add translations to `options/locale/locale_en-US.json`
