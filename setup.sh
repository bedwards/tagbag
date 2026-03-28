#!/usr/bin/env bash
set -euo pipefail

echo "=== TagBag Setup ==="
echo ""

# 1. Init submodules
echo "[1/5] Initializing submodules..."
git submodule update --init --recursive

# 2. Add upstream remotes (idempotent)
echo "[2/4] Adding upstream remotes..."
(cd submodules/plane     && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/makeplane/plane.git; })
(cd submodules/gitea     && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/go-gitea/gitea.git; })
(cd submodules/woodpecker && { git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/woodpecker-ci/woodpecker.git; })

# 3. Env files
echo "[3/5] Checking env files..."
for env_file in .env plane.env; do
    if [ ! -f "$env_file" ]; then
        cp "${env_file}.example" "$env_file"
        echo "  Created $env_file from ${env_file}.example — edit secrets before starting."
    else
        echo "  $env_file already exists."
    fi
done

# 4. Build and start
echo "[4/5] Building from source and starting services..."
echo ""
echo "  This will take a while on first run (building Go, Python, Node.js from source)."
echo ""
docker compose build

# Start infrastructure first and wait for healthy status
echo "  Starting infrastructure (postgres, redis, mq, minio)..."
docker compose up -d postgres plane-redis plane-mq plane-minio
echo "  Waiting for infrastructure to be healthy..."
docker compose exec postgres sh -c 'until pg_isready -U plane; do sleep 1; done'

# Run plane-migrator and wait for it to complete before starting services
echo "  Running Plane database migrations..."
docker compose up -d plane-migrator
echo "  Waiting for migrations to complete..."
docker compose wait plane-migrator || {
  echo ""
  echo "  ERROR: Plane database migrations failed."
  echo "  Check logs: docker compose logs plane-migrator"
  exit 1
}
echo "  Migrations completed successfully."

echo ""
echo "  Starting all services..."
docker compose up -d

# 5. Plane first-time setup (instance, admin, workspace, project, API token)
echo ""
echo "[5/5] Running Plane first-time setup..."
echo "  Waiting for Plane API to be ready..."
PLANE_READY=false
for _ in $(seq 1 60); do
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/instances/ | grep -q "200"; then
    PLANE_READY=true
    break
  fi
  sleep 2
done
if [ "$PLANE_READY" = "false" ]; then
  echo "  ERROR: Plane API did not become ready within 120 seconds."
  echo "  Check logs: docker compose logs plane-api"
  exit 1
fi
scripts/setup-plane.sh

echo ""
echo "=== Services ==="
echo "  Gitea (PRs/Code Review):  http://localhost:3000"
echo "  Plane (Issues/Projects):  http://localhost:8080"
echo "  Woodpecker (CI/CD):       http://localhost:9080"
echo "  PostgreSQL:                localhost:${POSTGRES_HOST_PORT:-5434}"
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
