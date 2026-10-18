#!/usr/bin/env bash
# backup.sh — logical backup of the whole cluster:
#   - globals (roles/tablespaces) via pg_dumpall --globals-only
#   - every non-template database via pg_dump custom format
# Output: ./backups/<name>-<UTC-timestamp>.{sql.gz,dump}
# Retention: BACKUP_KEEP_DAYS (default 14). Copy off-host — a backup that lives
# only on this VPS is not a backup.
# Cron example:  15 3 * * *  cd /path/to/pgstack && ./backup.sh >> backups/backup.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
OUT="$SCRIPT_DIR/backups"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

docker compose exec -T postgresql pg_isready -U postgres >/dev/null 2>&1 \
  || { echo "ERROR: postgresql not reachable" >&2; exit 1; }

mkdir -p "$OUT"
umask 077

echo ">> globals -> globals-$STAMP.sql.gz"
docker compose exec -T postgresql pg_dumpall -U postgres --globals-only | gzip > "$OUT/globals-$STAMP.sql.gz"

for db in $(docker compose exec -T postgresql psql -U postgres -tAc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate"); do
  echo ">> $db -> $db-$STAMP.dump"
  docker compose exec -T postgresql pg_dump -U postgres -Fc "$db" > "$OUT/$db-$STAMP.dump"
done

echo ">> pruning files older than $KEEP_DAYS days"
find "$OUT" -type f \( -name '*.dump' -o -name '*.sql.gz' \) -mtime "+$KEEP_DAYS" -delete

echo ">> done: $(find "$OUT" -maxdepth 1 -type f | wc -l) files in $OUT"
