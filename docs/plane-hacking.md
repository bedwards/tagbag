# Plane Hacking Guide

## Architecture

pnpm + Turborepo monorepo. Django/DRF backend, React Router v7 + MobX frontend.

### Apps

| App | Tech | Port |
|---|---|---|
| `apps/api` | Django/DRF + Celery | 8000 |
| `apps/web` | React Router v7 (Vite) | 3000 |
| `apps/admin` | React Router v7 (Vite) | 3001 |
| `apps/space` | React Router v7 (public views) | — |
| `apps/live` | Node.js/Hocuspocus (WebSocket) | — |
| `apps/proxy` | Caddy reverse proxy | 80 |

### Packages

| Package | Purpose |
|---|---|
| `@plane/types` | Shared TypeScript types |
| `@plane/ui` | Component library (Storybook) |
| `@plane/editor` | TipTap rich text editor |
| `@plane/services` | Axios API client base |
| `@plane/constants` | Shared enums/config |
| `@plane/hooks` | Shared React hooks |
| `@plane/i18n` | Internationalization |

## Backend (Django)

### Key Models (`apps/api/plane/db/models/`)

All inherit `BaseModel` → UUID PK, `created_at/updated_at`, `created_by/updated_by`, soft deletion.

- `Issue` (now "Work Item") — central entity: `state` FK, `priority` (urgent/high/medium/low/none), `assignees` M2M, `labels` M2M, `parent` self-FK, `sequence_id`
- `Project` — `identifier` (uppercase, e.g. "PROJ"), `ProjectMember`
- `State` — groups: backlog, unstarted, started, completed, cancelled, triage
- `Cycle` / `CycleIssue` — sprints
- `Module` / `ModuleIssue` — feature grouping
- `Label`, `Page`, `IssueComment`, `IssueActivity`

### URL Routing

```
/api/         → plane.app.urls (main app)
/api/v1/      → plane.api.urls (external developer API)
/api/public/  → plane.space.urls
/auth/        → plane.authentication.urls
```

Pattern: `/api/workspaces/<slug>/projects/<uuid>/work-items/<uuid>/`

### Views Pattern

All views inherit `BaseViewSet`. Permission via `@allow_permission([ROLE.ADMIN, ROLE.MEMBER])`.

Roles: ADMIN=20, MEMBER=15, GUEST=5. Checked at WORKSPACE or PROJECT level.

### Auth

Session-based (Django sessions, CSRF disabled for API). API tokens via `X-Api-Key` header. Rate limited (60/min regular, 300/min service).

### Background Tasks (Celery)

`apps/api/plane/bgtasks/`: issue activities, automation (auto-archive/close), email notifications, webhooks, exports, file processing.

Uses Redis as broker, RabbitMQ for queuing.

### Migrations

`apps/api/plane/db/migrations/` (currently ~120 migrations).

```bash
python manage.py makemigrations db --settings=plane.settings.local
python manage.py migrate --settings=plane.settings.local
```

## Frontend (React)

### Stack
- React Router v7 (Vite) — NOT Next.js
- MobX for state management
- Headless UI + Lucide icons
- Tailwind CSS
- OxLint + oxfmt

### CE/EE Split
- `apps/web/core/` — shared code
- `apps/web/ce/` — community edition overrides
- Path alias `@/plane-web/` resolves to active edition

### State Management (MobX)

Stores in `apps/web/core/store/`:
- `issue/root.store.ts` — aggregates project/cycle/module issue stores
- `issue/issue.store.ts` — core issue data
- `cycle.store.ts`, `module.store.ts`, `label.store.ts`, etc.

### API Client

Two-tier: `APIService` base (axios) → domain services (`IssueService`, `CycleService`, etc.) in `apps/web/core/services/`.

### Routing

`apps/web/app/routes/core.ts` — programmatic React Router v7 routes.

## Dev Workflow

### Setup
```bash
./setup.sh                    # copies .env files
docker compose -f docker-compose-local.yml up  # postgres, redis, rabbitmq, minio
```

### Frontend
```bash
pnpm install
pnpm dev                      # starts web:3000, admin:3001
```

### Backend (in Docker by default)
Or manually:
```bash
cd apps/api
pip install -r requirements/local.txt
python manage.py runserver 0.0.0.0:8000 --settings=plane.settings.local
```

### Commands
```bash
pnpm dev          # all dev servers
pnpm build        # build all
pnpm check        # format + lint + types
pnpm check:lint   # OxLint
pnpm check:types  # TypeScript
pnpm --filter=@plane/ui storybook  # component library
```

## How To: Add a Field to Issues

### Backend
1. Add field to `Issue` model in `apps/api/plane/db/models/issue.py`
2. `python manage.py makemigrations db`
3. Add to serializer in `apps/api/plane/app/serializers/issue.py`

### Frontend
1. Add to `TIssue` type in `packages/types/src/issues/`
2. Update MobX store if needed
3. Add UI in `apps/web/ce/components/issues/`

## How To: Add a New API Endpoint

1. Create view in `apps/api/plane/app/views/<domain>/` inheriting `BaseViewSet`
2. Export from `apps/api/plane/app/views/__init__.py`
3. Add URL in `apps/api/plane/app/urls/<domain>.py`
4. Wire into `apps/api/plane/app/urls/__init__.py`
5. Add service method in `apps/web/core/services/`
