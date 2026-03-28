#!/usr/bin/env bash
# scripts/backup.sh — Back up all TagBag data (4 databases + Gitea repos + MinIO)
# Usage: ./scripts/backup.sh [--verify [backup_dir]] [--test-restore [backup_dir]] [backup_dir]
set -euo pipefail

# Read DB credentials from env or defaults
PG_USER="${POSTGRES_USER:-plane}"
PG_PASSWORD="${POSTGRES_PASSWORD:-plane}"
KEEP_DAYS="${TAGBAG_BACKUP_RETAIN_DAYS:-30}"

# ---------------------------------------------------------------
# --verify: check SHA-256 checksums for the latest backup
# ---------------------------------------------------------------
do_verify() {
  local backup_dir="${1:-./backups}"
  local latest
  latest=$(find "${backup_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)

  if [ -z "${latest}" ]; then
    echo "ERROR: No backups found in ${backup_dir}"
    exit 1
  fi

  local checksum_file="${latest}/SHA256SUMS"
  if [ ! -f "${checksum_file}" ]; then
    echo "ERROR: No SHA256SUMS file in ${latest}"
    exit 1
  fi

  echo "=== Verifying checksums for $(basename "${latest}") ==="
  if (cd "${latest}" && shasum -a 256 -c SHA256SUMS); then
    echo ""
    echo "  All checksums OK."
  else
    echo ""
    echo "  CHECKSUM VERIFICATION FAILED"
    exit 1
  fi
}

# ---------------------------------------------------------------
# --test-restore: restore latest backup into a temp DB and verify
# ---------------------------------------------------------------
do_test_restore() {
  local backup_dir="${1:-./backups}"
  local latest
  latest=$(find "${backup_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)

  if [ -z "${latest}" ]; then
    echo "ERROR: No backups found in ${backup_dir}"
    exit 1
  fi

  echo "=== Test Restore from $(basename "${latest}") ==="

  # Find the first available .dump file to test with
  local dump_file=""
  local dump_db=""
  for db in plane gitea woodpecker tagbag; do
    if [ -f "${latest}/${db}.dump" ]; then
      dump_file="${latest}/${db}.dump"
      dump_db="${db}"
      break
    fi
  done

  if [ -z "${dump_file}" ]; then
    echo "ERROR: No .dump files found in ${latest}"
    exit 1
  fi

  local test_db="tagbag_restore_test_$$"
  echo "  Using dump: ${dump_db}.dump"
  echo "  Temp database: ${test_db}"

  # Create temporary database
  echo "  Creating temp database..."
  docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    psql -U "${PG_USER}" -c "CREATE DATABASE ${test_db};" >/dev/null 2>&1

  local restore_ok=true

  # Restore into temp database
  echo "  Restoring ${dump_db}.dump..."
  if docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    pg_restore -U "${PG_USER}" -d "${test_db}" --no-owner --no-privileges \
    < "${dump_file}" 2>/dev/null; then
    echo "  Restore: OK"
  else
    # pg_restore returns non-zero on warnings too; check if tables exist
    echo "  Restore: completed with warnings (checking data...)"
  fi

  # Verify data integrity: count tables
  echo "  Verifying data integrity..."
  local table_count
  table_count=$(docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    psql -U "${PG_USER}" -d "${test_db}" -t -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null \
    | tr -d '[:space:]')

  if [ -n "${table_count}" ] && [ "${table_count}" -gt 0 ] 2>/dev/null; then
    echo "  Tables found: ${table_count}"
    echo "  Data integrity: OK"
  else
    echo "  WARNING: No tables found after restore — backup may be empty or corrupt."
    restore_ok=false
  fi

  # Clean up: drop temporary database
  echo "  Dropping temp database..."
  docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    psql -U "${PG_USER}" -c "DROP DATABASE IF EXISTS ${test_db};" >/dev/null 2>&1

  echo ""
  if [ "${restore_ok}" = true ]; then
    echo "=== Test Restore: PASSED ==="
  else
    echo "=== Test Restore: FAILED ==="
    exit 1
  fi
}

# ---------------------------------------------------------------
# generate_checksums: create SHA256SUMS for all files in a backup
# ---------------------------------------------------------------
generate_checksums() {
  local backup_path="$1"
  echo "  Generating SHA-256 checksums..."
  (cd "${backup_path}" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -exec basename {} \; \
    | sort | xargs shasum -a 256 > SHA256SUMS)
  echo "  Checksums written to ${backup_path}/SHA256SUMS"
}

# ---------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------
ACTION="backup"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      ACTION="verify"
      shift
      ;;
    --test-restore)
      ACTION="test-restore"
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

BACKUP_DIR="${POSITIONAL_ARGS[0]:-./backups}"

if [ "${ACTION}" = "verify" ]; then
  do_verify "${BACKUP_DIR}"
  exit 0
fi

if [ "${ACTION}" = "test-restore" ]; then
  do_test_restore "${BACKUP_DIR}"
  exit 0
fi

# ---------------------------------------------------------------
# Normal backup flow
# ---------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"

echo "=== TagBag Backup ==="
echo "  Timestamp: ${TIMESTAMP}"
echo "  Target:    ${BACKUP_PATH}"
echo ""

mkdir -p "${BACKUP_PATH}"

# ---------------------------------------------------------------
# PostgreSQL databases
# ---------------------------------------------------------------
DATABASES=("plane" "gitea" "woodpecker" "tagbag")

echo "[1/3] Backing up PostgreSQL databases..."
for db in "${DATABASES[@]}"; do
  echo "  Dumping ${db}..."
  docker compose exec -T -e PGPASSWORD="${PG_PASSWORD}" postgres \
    pg_dump -U "${PG_USER}" -d "${db}" --format=custom \
    > "${BACKUP_PATH}/${db}.dump" 2>/dev/null || {
      echo "  WARNING: Database '${db}' does not exist or dump failed, skipping."
      rm -f "${BACKUP_PATH}/${db}.dump"
    }
done

# ---------------------------------------------------------------
# Gitea git repositories (bare repos from the volume)
# ---------------------------------------------------------------
echo "[2/3] Backing up Gitea repositories..."
docker compose exec -T gitea sh -c 'tar -czf - /data/git/repositories 2>/dev/null' \
  > "${BACKUP_PATH}/gitea-repos.tar.gz" 2>/dev/null || {
    echo "  WARNING: Gitea repository backup failed, skipping."
    rm -f "${BACKUP_PATH}/gitea-repos.tar.gz"
  }

# ---------------------------------------------------------------
# MinIO uploads (Plane file attachments)
# ---------------------------------------------------------------
echo "[3/3] Backing up MinIO uploads..."
MINIO_CONTAINER=$(docker compose ps -q plane-minio 2>/dev/null || echo "")
if [ -n "${MINIO_CONTAINER}" ]; then
  if docker cp "${MINIO_CONTAINER}:/export" "${BACKUP_PATH}/minio-export" 2>/dev/null; then
    tar -czf "${BACKUP_PATH}/minio-data.tar.gz" -C "${BACKUP_PATH}" minio-export
    rm -rf "${BACKUP_PATH}/minio-export"
  else
    echo "  WARNING: MinIO backup failed, skipping."
    rm -rf "${BACKUP_PATH}/minio-export" "${BACKUP_PATH}/minio-data.tar.gz"
  fi
else
  echo "  WARNING: MinIO container not running, skipping."
fi

# ---------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------
generate_checksums "${BACKUP_PATH}"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "=== Backup Complete ==="
TOTAL_SIZE=$(du -sh "${BACKUP_PATH}" | cut -f1)
echo "  Location: ${BACKUP_PATH}"
echo "  Size:     ${TOTAL_SIZE}"
echo "  Contents:"
find "${BACKUP_PATH}" -maxdepth 1 -type f -exec basename {} \; | sort | while read -r f; do
  SIZE=$(du -h "${BACKUP_PATH}/${f}" | cut -f1)
  printf "    %-30s %s\n" "$f" "$SIZE"
done

# ---------------------------------------------------------------
# Rotation: delete backups older than KEEP_DAYS
# ---------------------------------------------------------------
if [ -d "${BACKUP_DIR}" ]; then
  OLD_COUNT=$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP_DAYS}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${OLD_COUNT}" -gt 0 ]; then
    echo ""
    echo "  Rotating: removing ${OLD_COUNT} backup(s) older than ${KEEP_DAYS} days..."
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP_DAYS}" -exec rm -rf {} +
  fi
fi

echo ""
echo "  Verify checksums:"
echo "    ./scripts/backup.sh --verify ${BACKUP_DIR}"
echo ""
echo "  Test restore:"
echo "    ./scripts/backup.sh --test-restore ${BACKUP_DIR}"
echo ""
echo "  Manual restore:"
echo "    docker compose exec -T postgres pg_restore -U ${PG_USER} -d <dbname> < ${BACKUP_PATH}/<dbname>.dump"
echo ""
