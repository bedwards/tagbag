# TagBag

Self-hosted GitHub replacement. Built from source. All the keys to the castle.

**Current version: v0.26.0**

## What

Three forked open-source projects, one Docker Compose stack, one unified CLI, one dashboard. Every repo automatically mirrors to GitHub (private, read-only) with bidirectional issue sync.

| Service | Replaces | Port | Source |
|---|---|---|---|
| [TagBag Dashboard](http://localhost:8888) | Unified web UI | [localhost:8888](http://localhost:8888) | `web/index.html` |
| [Gitea](https://gitea.io) | Code, PRs, Code Review | [localhost:3000](http://localhost:3000) | `submodules/gitea/` |
| [Plane](https://plane.so) | Issues, Sprints, Projects | [localhost:8080](http://localhost:8080) | `submodules/plane/` |
| [Woodpecker CI](https://woodpecker-ci.org) | Actions, CI/CD | [localhost:9080](http://localhost:9080) | `submodules/woodpecker/` |

### Full Port Map

| Port | Service |
|---|---|
| 3000 | Gitea (HTTP) |
| 8080 | Plane |
| 9080 | Woodpecker CI |
| 8888 | TagBag Dashboard |
| 5434 | PostgreSQL |
| 2222 | Gitea SSH |

All backed by PostgreSQL. Gitea is the OAuth2 identity provider for single sign-on.

## Quick Start

```bash
git clone --recurse-submodules git@github.com:bedwards/tagbag.git
cd tagbag
./setup.sh
```

First build takes a while (Go, Python, Node.js compiling from source). After that:

```bash
./cli/tagbag up                    # start
./cli/tagbag status                # check
./cli/tagbag down                  # stop
```

Open the dashboard at [localhost:8888](http://localhost:8888) for a unified view of code, issues, PRs, and CI.

## CLI

```bash
# Identity
tb login                           # interactive password prompt, creates API token
tb whoami                          # show identity across services

# Infrastructure
tb status                          # show all service status + endpoints
tb up                              # docker compose up -d
tb down                            # docker compose down
tb build                           # rebuild all from source
tb logs                            # tail all logs

# Git operations
tb repo create                     # create repo (defaults to cwd name), add SSH remote, push
tb clone <owner/repo>              # clone via SSH (--https to opt in)
tb web                             # open Gitea repo in browser

# Service CLIs
tb plane work-items ...            # issues, sprints, modules
tb gitea prs ...                   # repos, pull requests, code review
tb ci pipelines ...                # CI/CD pipelines, secrets, logs

# AI Code Review (Claude + Gemini)
tb reviewer start|stop|status|logs|register|protect

# GitHub-Gitea Bridge
tb bridge start|stop|status|logs|register
```

### AI Code Review

The **reviewer** runs Claude and Gemini in parallel on every push. Both post review issues to Gitea and set commit statuses. Use `tb reviewer register` to set up the webhook and `tb reviewer protect` to enforce reviews on branches.

### GitHub Mirror

Every push automatically mirrors code (branches + tags) to a private GitHub repo via `gh` CLI. Issues sync bidirectionally between Gitea and GitHub using embedded markers to track pairs. All writes go to TagBag; GitHub is a read-only mirror. No second remote needed.

### Bridge

The **bridge** links Gitea events to Plane work items. It parses commit messages and pull requests for references like `PROJ-123` and adds comments to the corresponding work items. Use `tb bridge register` to set up the webhook for a repository.

### Dashboard

The dashboard at [localhost:8888](http://localhost:8888) is a self-contained SPA. Clicking a repo opens an inline file browser with directory tree, file viewer with line numbers, README rendering, branch selector, and breadcrumb navigation. No external links to backend services.

Run `tb --help` for the full command tree. Every subcommand has `--help`.

## SSO

Gitea acts as the OAuth2 identity provider. Log into Gitea once, and Plane + Woodpecker authenticate automatically via OAuth redirect. See [docs/unified-auth.md](docs/unified-auth.md).

## Development

Each submodule is a fork with an `upstream` remote:

```bash
cd submodules/gitea
git fetch upstream
git merge upstream/v1.26.0
git push origin main
cd ../..
git add submodules/gitea
git commit -m "bump gitea to v1.26.0"
```

### Versioning

```bash
./scripts/bump-version.sh         # bumps minor, tags, ready to push
```

### Pre-commit

```bash
./scripts/install-hooks.sh        # install once
```

Checks: shellcheck, docker-compose validation, VERSION format, CLI smoke test.

### CI

GitHub Actions runs on every push and PR. See `.github/workflows/ci.yml`.

## Docs

| Doc | What |
|---|---|
| [tagbag-cli.md](docs/tagbag-cli.md) | Unified CLI reference |
| [unified-auth.md](docs/unified-auth.md) | SSO architecture |
| [gitea-cli-api.md](docs/gitea-cli-api.md) | tea CLI + REST API |
| [plane-api.md](docs/plane-api.md) | Plane REST API |
| [woodpecker-cli-api.md](docs/woodpecker-cli-api.md) | Woodpecker CLI + API |
| [gitea-hacking.md](docs/gitea-hacking.md) | Gitea codebase guide |
| [plane-hacking.md](docs/plane-hacking.md) | Plane codebase guide |
| [woodpecker-hacking.md](docs/woodpecker-hacking.md) | Woodpecker codebase guide |
| [integration-architecture.md](docs/integration-architecture.md) | Cross-service webhooks |
| [what-tagbag-is-and-why-it-exists.md](docs/what-tagbag-is-and-why-it-exists.md) | First-principles explainer |

## Key Files

| Path | What |
|---|---|
| `cli/tagbag` | Unified CLI (aliased as `tb`) |
| `web/index.html` | Dashboard SPA |
| `web/nginx.conf` | Reverse proxy config |
| `mirror/github-sync.sh` | Code mirror (branches + tags) to GitHub |
| `mirror/issue-sync.sh` | Bidirectional issue sync (Gitea ↔ GitHub) |
| `reviewer/webhook-server.sh` | Webhook receiver + review queue |
| `reviewer/do-review.sh` | Claude code review |
| `reviewer/do-review-gemini.sh` | Gemini code review |

## License

Each submodule retains its upstream license (Gitea: MIT, Plane: AGPL-3.0, Woodpecker: Apache-2.0). TagBag's own code (CLI, config, docs) is MIT.
