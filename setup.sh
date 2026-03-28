#!/usr/bin/env bash
set -euo pipefail

echo "=== TagBag Setup ==="
echo ""

# 1. Init submodules
echo "[1/4] Initializing submodules..."
git submodule update --init --recursive

# 2. Add upstream remotes (idempotent)
echo "[2/4] Adding upstream remotes..."
(cd submodules/plane     && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/makeplane/plane.git; })
(cd submodules/gitea     && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/go-gitea/gitea.git; })
(cd submodules/woodpecker && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/woodpecker-ci/woodpecker.git; })

# 3. Env file
echo "[3/4] Checking .env..."
if [ ! -f .env ]; then
    cp .env.example .env
    echo "  Created .env from .env.example — edit secrets before starting."
else
    echo "  .env already exists."
fi

# 4. Build and start
echo "[4/4] Building from source and starting services..."
echo ""
echo "  This will take a while on first run (building Go, Python, Node.js from source)."
echo ""
docker compose build
docker compose up -d postgres plane-redis plane-mq plane-minio
echo "  Waiting for PostgreSQL to be ready..."
docker compose exec postgres sh -c 'until pg_isready -U plane; do sleep 1; done'

echo ""
echo "  Starting all services..."
docker compose up -d

echo ""
echo "=== Services ==="
echo "  Gitea (PRs/Code Review):  http://localhost:3000"
echo "  Plane (Issues/Projects):  http://localhost:8080"
echo "  Woodpecker (CI/CD):       http://localhost:9080"
echo "  PostgreSQL:                localhost:5432"
echo ""
echo "=== Next Steps (SSO Setup) ==="
echo ""
echo "  1. Create your admin account at http://localhost:3000 (first user becomes admin)"
echo ""
echo "  2. In Gitea, go to Settings > Applications and create TWO OAuth2 Apps:"
echo ""
echo "     App 1 — Woodpecker:"
echo "       Name: Woodpecker"
echo "       Redirect URI: http://localhost:9080/authorize"
echo "       Confidential: Yes"
echo "     → Put Client ID/Secret in .env as WOODPECKER_GITEA_CLIENT/SECRET"
echo ""
echo "     App 2 — Plane:"
echo "       Name: Plane"
echo "       Redirect URI: http://localhost:8080/auth/gitea/callback/"
echo "       Confidential: Yes"
echo "     → Put Client ID/Secret in plane.env as GITEA_CLIENT_ID/SECRET"
echo ""
echo "  3. Restart services:"
echo "       docker compose restart woodpecker-server plane-api"
echo ""
echo "  4. Log into Plane at http://localhost:8080 using 'Login with Gitea'"
echo "     (Or configure at http://localhost:8080/god-mode/authentication/gitea/)"
echo ""
echo "  5. Log into Woodpecker at http://localhost:9080 (auto-redirects to Gitea)"
echo ""
echo "  6. Set up CLI tokens:"
echo "       ./cli/tagbag login"
echo ""
echo "  See docs/unified-auth.md for full details."
echo ""
