# TagBag

Self-hosted GitHub replacement. Built from source. All the keys to the castle.

**Current version: v0.12.0**

## What

Three forked open-source projects, one Docker Compose stack, one unified CLI, one dashboard.

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
| 5432 | PostgreSQL |
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
./cli/tagbag login                 # set up tokens for all three services
./cli/tagbag whoami                # show identity across services

# Infrastructure
./cli/tagbag status                # show all service status + endpoints
./cli/tagbag up                    # docker compose up -d
./cli/tagbag down                  # docker compose down
./cli/tagbag build                 # rebuild all from source
./cli/tagbag logs                  # tail all logs

# Git operations
./cli/tagbag clone <owner/repo>    # clone a Gitea repo
./cli/tagbag web                   # open Gitea repo in browser
./cli/tagbag push <owner/repo>     # push repo to Gitea (supports --github, --mirror)

# Service CLIs
./cli/tagbag plane work-items ...  # issues, sprints, modules
./cli/tagbag gitea prs ...         # repos, pull requests, code review
./cli/tagbag ci pipelines ...      # CI/CD pipelines, secrets, logs

# AI Code Review
./cli/tagbag reviewer start|stop|status|logs|register|protect

# GitHub-Gitea Bridge
./cli/tagbag bridge start|stop|status|logs|register
```

### Reviewer

The **reviewer** is an AI-powered code review service. It watches Gitea pull requests and provides automated review comments. Use `tagbag reviewer register` to set up the webhook and `tagbag reviewer protect` to enforce reviews on branches.

### Bridge

The **bridge** syncs repositories between GitHub and Gitea. Use `tagbag bridge register` to set up the webhook for automatic mirroring.

Run `./cli/tagbag --help` for the full command tree. Every subcommand has `--help`.

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

## License

Each submodule retains its upstream license (Gitea: MIT, Plane: AGPL-3.0, Woodpecker: Apache-2.0). TagBag's own code (CLI, config, docs) is MIT.
