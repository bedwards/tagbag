#!/usr/bin/env bash
# scripts/backup.sh — Back up all TagBag data (4 databases + Gitea repos + MinIO)
# Usage: ./scripts/backup.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-./backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"
KEEP_DAYS="${TAGBAG_BACKUP_RETAIN_DAYS:-30}"

# Read DB credentials from env or defaults
PG_USER="${POSTGRES_USER:-plane}"
PG_PASSWORD="${POSTGRES_PASSWORD:-plane}"

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
echo "  Restore example:"
echo "    docker compose exec -T postgres pg_restore -U ${PG_USER} -d <dbname> < ${BACKUP_PATH}/<dbname>.dump"
echo ""
