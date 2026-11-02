#!/usr/bin/env bash
# backup.sh — logical backup of the whole cluster:
#   - globals (roles/tablespaces) via pg_dumpall --globals-only
#   - every non-template database via pg_dump custom format
# Output: ./backups/<name>-<UTC-timestamp>.{sql.gz,dump}
# Retention: BACKUP_KEEP_DAYS (default 14). Copy off-host ENCRYPTED — the
# globals dump contains every role's SCRAM verifier, and the off-host bundle
# must also carry creds/, userlist.txt, ssl-ca/ and .env (see README Backups).
# Cron — install in the OPERATOR's crontab (`crontab -e` as that user), never
# root's (root-owned dumps break the operator-run DR restore):
#   15 3 * * *  cd /path/to/pgstack && mkdir -p backups && ./backup.sh >> backups/backup.log 2>&1
#
# Design notes (deep-audit round 4):
#   - prune runs FIRST: with the old dump-then-prune order, a dump failing on
#     a full disk (set -e) skipped the prune forever — a deadlock that ended
#     in postgres PANIC (no WAL write space).
#   - every dump goes to *.tmp and is moved into place only on success: gzip
#     writes a VALID trailer over truncated data, so a mid-stream death would
#     otherwise leave a good-looking partial backup that restores "successfully".
#   - one database failing does NOT strand the others; the script exits
#     nonzero with an explicit list of what failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Run as the operator (same rule as setup.sh/cred.sh): root-run cron would
# leave root-owned 0600 dumps unreadable to the operator at restore time.
if [ "$(id -u)" = "0" ]; then
  echo "ERROR: do not run $0 as root — dumps must stay owned by the operator" >&2
  echo "       (install the cron in the operator's crontab, see header)" >&2
  exit 1
fi

KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
OUT="$SCRIPT_DIR/backups"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

docker compose exec -T postgresql pg_isready -U postgres >/dev/null 2>&1 \
  || { echo "ERROR: postgresql not reachable" >&2; exit 1; }

mkdir -p "$OUT" && chmod 700 "$OUT"   # filenames/timestamps are metadata — operator-only too
umask 077

# 1) prune FIRST — frees space for tonight's dumps, and a later dump failure
#    can no longer skip the cleanup (the old order deadlocked on disk-full).
echo ">> pruning files older than $KEEP_DAYS days"
find "$OUT" -type f \( -name '*.dump' -o -name '*.sql.gz' \) -mtime "+$KEEP_DAYS" -delete

FAILED=""

# 2) globals — tmp + move: a mid-stream death must not leave a valid-looking file.
echo ">> globals -> globals-$STAMP.sql.gz"
if docker compose exec -T postgresql pg_dumpall -U postgres --globals-only | gzip > "$OUT/globals-$STAMP.sql.gz.tmp"; then
  mv "$OUT/globals-$STAMP.sql.gz.tmp" "$OUT/globals-$STAMP.sql.gz"
else
  rm -f "$OUT/globals-$STAMP.sql.gz.tmp"
  FAILED="$FAILED globals"
  echo "ERROR: globals dump FAILED" >&2
fi

# 3) per-db — process substitution (not a pipe) so FAILED propagates;
#    while/read (not for+word-split) so db names with spaces survive.
#    NB: every exec inside the loop gets </dev/null — `compose exec -T`
#    otherwise drains THIS loop's stdin and eats the remaining db names
#    (verified live: zitadel silently vanished from a backup run).
while IFS= read -r db; do
  [ -n "$db" ] || continue
  echo ">> $db -> $db-$STAMP.dump"
  if docker compose exec -T postgresql pg_dump -U postgres -Fc "$db" < /dev/null > "$OUT/$db-$STAMP.dump.tmp"; then
    mv "$OUT/$db-$STAMP.dump.tmp" "$OUT/$db-$STAMP.dump"
  else
    rm -f "$OUT/$db-$STAMP.dump.tmp"
    FAILED="$FAILED $db"
    echo "ERROR: dump of '$db' FAILED (continuing with the other databases)" >&2
  fi
done < <(docker compose exec -T postgresql psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate" < /dev/null)

echo ">> done: $(find "$OUT" -maxdepth 1 -type f -name "*-$STAMP.*" | wc -l) files with stamp $STAMP in $OUT"
if [ -n "$FAILED" ]; then
  echo "ERROR: backup INCOMPLETE — failed:${FAILED}" >&2
  exit 1
fi
