#!/usr/bin/env bash
# scripts/doctor.sh — Health check for all TagBag services
# Usage: ./scripts/doctor.sh [--quiet]
# Exit code: 0 = all healthy, 1 = one or more issues
set -euo pipefail

QUIET="${1:-}"
GITEA_URL="${GITEA_URL:-http://localhost:3000}"
PLANE_URL="${PLANE_URL:-http://localhost:8080}"
WOODPECKER_URL="${WOODPECKER_URL:-http://localhost:9080}"
DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:8888}"
PG_USER="${POSTGRES_USER:-plane}"
PG_PASSWORD="${POSTGRES_PASSWORD:-plane}"

PASS=0
FAIL=0
WARN=0

log() {
  if [ "$QUIET" != "--quiet" ]; then
    echo "$1"
  fi
}

check() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    log "  OK   $name"
    PASS=$((PASS + 1))
  elif [ "$result" = "warn" ]; then
    log "  WARN $name"
    WARN=$((WARN + 1))
  else
    log "  FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

log "=== TagBag Health Check ==="
log ""

# ---------------------------------------------------------------
# Docker services
# ---------------------------------------------------------------
log "[Docker Services]"

EXPECTED_SERVICES="postgres gitea plane-api plane-web plane-worker plane-beat plane-live plane-admin plane-space plane-proxy plane-redis plane-mq plane-minio woodpecker-server woodpecker-agent tagbag-web"

for svc in $EXPECTED_SERVICES; do
  STATUS=$(docker compose ps --format json "$svc" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('State', 'unknown'))
except (json.JSONDecodeError, AttributeError):
    print('not_found')
" 2>/dev/null || echo "not_found")

  if [ "$STATUS" = "running" ]; then
    check "$svc" "pass"
  elif [ "$STATUS" = "exited" ]; then
    # Some services (like migrator) exit after completing
    if [[ "$svc" == *"migrator"* ]]; then
      check "$svc (exited, expected)" "pass"
    else
      check "$svc (exited)" "fail"
    fi
  else
    check "$svc ($STATUS)" "fail"
  fi
done

# ---------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------
log ""
log "[HTTP Endpoints]"

for pair in "Gitea:${GITEA_URL}" "Plane:${PLANE_URL}" "Woodpecker:${WOODPECKER_URL}" "Dashboard:${DASHBOARD_URL}"; do
  NAME="${pair%%:*}"
  URL="${pair#*:}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" 2>/dev/null || echo "000")
  if [ "$CODE" -ge 200 ] && [ "$CODE" -lt 400 ]; then
    check "$NAME ($URL) -> HTTP $CODE" "pass"
  else
    check "$NAME ($URL) -> HTTP $CODE" "fail"
  fi
done

# ---------------------------------------------------------------
# Database connections
# ---------------------------------------------------------------
log ""
log "[Database Connections]"

DATABASES="plane gitea woodpecker tagbag"
for db in $DATABASES; do
  RESULT=$(docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    psql -U "${PG_USER}" -d "$db" -c "SELECT 1;" 2>/dev/null | grep -c "1 row" || echo "0")
  if [ "$RESULT" -gt 0 ]; then
    check "PostgreSQL: $db" "pass"
  else
    check "PostgreSQL: $db" "fail"
  fi
done

# ---------------------------------------------------------------
# Port conflicts
# ---------------------------------------------------------------
log ""
log "[Port Conflicts]"

# Source .env if it exists for port variables
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env 2>/dev/null
  set +a
fi

PORTS=(
    "${POSTGRES_HOST_PORT:-5434}:PostgreSQL"
    "${GITEA_HTTP_PORT:-3000}:Gitea HTTP"
    "${GITEA_SSH_PORT:-2222}:Gitea SSH"
    "${LISTEN_HTTP_PORT:-8080}:Plane"
    "9080:Woodpecker"
    "8888:Dashboard"
)
for entry in "${PORTS[@]}"; do
    PORT="${entry%%:*}"
    NAME="${entry#*:}"
    PID=$(lsof -ti ":${PORT}" 2>/dev/null | head -1 || true)
    if [ -n "$PID" ]; then
        PROC=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
        if echo "$PROC" | grep -qi "docker\|com.docker"; then
            check "Port ${PORT} (${NAME}): Docker" "pass"
        else
            check "Port ${PORT} (${NAME}): in use by '${PROC}'" "warn"
        fi
    else
        check "Port ${PORT} (${NAME}): free" "pass"
    fi
done

# ---------------------------------------------------------------
# Disk space
# ---------------------------------------------------------------
log ""
log "[Disk Space]"

DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_USAGE" -lt 80 ]; then
  check "Root filesystem: ${DISK_USAGE}% used" "pass"
elif [ "$DISK_USAGE" -lt 90 ]; then
  check "Root filesystem: ${DISK_USAGE}% used" "warn"
else
  check "Root filesystem: ${DISK_USAGE}% used" "fail"
fi

# Docker disk
DOCKER_DISK=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "unknown")
log "  INFO Docker disk usage: $DOCKER_DISK"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
log ""
log "=== Summary ==="
log "  OK: ${PASS}  WARN: ${WARN}  FAIL: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
  log ""
  log "  Some checks failed. Run 'docker compose logs <service>' to debug."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  exit 0
fi
