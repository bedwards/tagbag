#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PGPASSWORD=plane psql -h localhost -U plane -d tagbag -f "$SCRIPT_DIR/migrations/001_initial.sql"
