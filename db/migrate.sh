#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PGPASSWORD=${PGPASSWORD:-plane} psql -h "${PGHOST:-localhost}" -U "${PGUSER:-plane}" -d "${PGDATABASE:-tagbag}" -f "$SCRIPT_DIR/migrations/001_initial.sql"
