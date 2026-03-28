# TagBag

Self-hosted GitHub replacement built from forked open-source components, all PostgreSQL-backed and Docker Compose orchestrated.

## Architecture

| Service | Role | Port | Source |
|---|---|---|---|
| **Gitea** | Git hosting, PRs, code review | `localhost:3000` (HTTP), `localhost:2222` (SSH) | `submodules/gitea/` (Go) |
| **Plane** | Issues, sprints, project management | `localhost:8080` | `submodules/plane/` (Django + React) |
| **Woodpecker CI** | CI/CD pipelines | `localhost:9080` | `submodules/woodpecker/` (Go) |
| **PostgreSQL** | Shared database (3 DBs: plane, gitea, woodpecker) | `localhost:5432` | Docker image |

## Quick Start

```bash
./setup.sh                    # build from source + start
docker compose up -d          # start (after initial build)
docker compose down           # stop
docker compose build <svc>    # rebuild a single service
docker compose logs -f <svc>  # tail logs
```

## CLI Tools

- `tea` — Gitea CLI (repos, PRs, issues, orgs)
- `woodpecker-cli` — Woodpecker CLI (pipelines, repos, secrets)
- `./cli/tagbag` — TagBag unified CLI wrapping all three + Plane API

## Submodule Workflow

```bash
cd submodules/<name>
git fetch upstream
git merge upstream/v1.2.3   # merge upstream release
git push origin main         # push to your fork
cd ../..
git add submodules/<name>
git commit -m "bump <name> to v1.2.3"
```

## Key Files

- `docker-compose.yml` — all 16 services
- `.env` / `.env.example` — shared config (secrets, ports, DB creds)
- `plane.env` — Plane API-specific env
- `docker/init-db.sh` — PostgreSQL init (creates gitea + woodpecker DBs)
- `docker/woodpecker-server.Dockerfile` — builds Woodpecker server from source
- `docs/` — comprehensive documentation
- `cli/` — TagBag unified CLI

## Development

Each submodule can be hacked independently. See `docs/` for per-project hacking guides:
- `docs/gitea-hacking.md` — Go backend, templates, API routes
- `docs/plane-hacking.md` — Django backend, React frontend, turbo monorepo
- `docs/woodpecker-hacking.md` — Go server/agent, Vue frontend, pipeline engine
- `docs/gitea-cli-api.md` — tea CLI + REST API reference
- `docs/woodpecker-cli-api.md` — woodpecker-cli + REST API reference
- `docs/plane-api.md` — Plane REST API reference
- `docs/tagbag-cli.md` — Unified CLI reference
- `docs/integration-architecture.md` — Cross-service integration (webhooks, auto-close, cross-links)
- `docs/unified-auth.md` — SSO via Gitea OAuth2 (single login for all three services)

## Important Notes

- Plane API uses `/work-items/` not `/issues/` (deprecated, EOL March 31, 2026)
- Gitea is the OAuth2 identity provider for Woodpecker (and potentially Plane)
- The tagbag CLI uses `X-Api-Key` header for Plane, `Authorization: token` for Gitea, `Authorization: Bearer` for Woodpecker
