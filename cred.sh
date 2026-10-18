#!/usr/bin/env bash
# cred.sh — create (or rotate) one user's credential, end-to-end:
#   1. random password -> role in PostgreSQL (create if missing, else rotate)
#   2. optional database owned by the role (app users); CONNECT revoked from
#      PUBLIC so roles cannot see each other's databases
#   3. SCRAM verifier copied byte-identical from pg_shadow -> ./userlist.txt
#      (identical bytes are REQUIRED for PgBouncer SCRAM pass-through)
#   4. restart pgbouncer (clears its cached auth state after a rotation)
#   5. plaintext saved once to ./creds/<role>.pw (chmod 600, gitignored)
#
# Usage:
#   ./cred.sh pgbouncer_admin        # console user (no database)
#   ./cred.sh zitadel zitadel        # app user + its database
# Re-running rotates the password.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "Usage: $0 <role> [dbname]" >&2; exit 2; }
ROLE="$1"; DB="${2:-}"
for ident in "$ROLE" "$DB"; do
  [ -z "$ident" ] && continue
  [[ "$ident" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || { echo "ERROR: '$ident' is not a valid lowercase identifier" >&2; exit 2; }
done

# Serialize concurrent runs: two cred.sh racing on userlist.txt (shared tmp
# file, read-modify-write) can silently drop a line. Cheap lock, no luck.
exec 9>"$SCRIPT_DIR/.cred.lock"
flock 9

psql_root() { docker compose exec -T postgresql psql -U postgres "$@"; }

umask 022   # normalize regardless of caller; creds/*.pw gets explicit 600 below

psql_root -tAc 'SELECT 1' >/dev/null 2>&1 \
  || { echo "ERROR: postgresql not reachable — run ./setup.sh or 'docker compose up -d' first" >&2; exit 1; }
[ -f userlist.txt ] || : > userlist.txt

# URL-safe alphabet on purpose: these credentials end up in DSNs
# (postgresql://user:PW@host/...), where base64's + / = break URL parsing.
NEW_PW="$(openssl rand -hex 24)"

psql_root -q -v role="$ROLE" -v new_pw="$NEW_PW" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'new_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'new_pw')\gexec
SQL

if [ -n "$DB" ]; then
  psql_root -q -v role="$ROLE" -v dbname="$DB" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'dbname')\gexec
REVOKE CONNECT ON DATABASE :"dbname" FROM PUBLIC;
SQL
fi

# Fetch the SCRAM verifier straight from the server (no client-side crypto;
# byte-identical to pg_shadow -> SCRAM pass-through works).
VERIFIER="$(psql_root -tAc "SELECT passwd FROM pg_shadow WHERE usename = '${ROLE}'")"
[ -n "$VERIFIER" ] || { echo "ERROR: could not read the SCRAM verifier from pg_shadow" >&2; exit 1; }

grep -v "^\"${ROLE}\"" userlist.txt > userlist.txt.tmp || true
printf '"%s" "%s"\n' "$ROLE" "$VERIFIER" >> userlist.txt.tmp
# Write IN PLACE (not mv): the container bind-mounts this file's inode —
# mv would hand it a stale empty file no reload can ever see.
cat userlist.txt.tmp > userlist.txt
rm -f userlist.txt.tmp
chmod 644 userlist.txt   # pgbouncer (container uid) must be able to read it

# Restart pgbouncer (NOT just SIGHUP): tested — after a rotation, pgbouncer's
# in-memory per-user auth state keeps failing NEW server logins until a full
# restart, while existing pooled connections mask it for up to server_lifetime.
# A restart drops client connections for ~1s; acceptable for a rotation event.
docker compose restart pgbouncer >/dev/null

mkdir -p creds; umask 077
printf '%s\n' "$NEW_PW" > "creds/${ROLE}.pw"

echo ">> ${ROLE}: password set -> creds/${ROLE}.pw (chmod 600)"
if [ "$ROLE" = "pgbouncer_admin" ]; then
  echo ">> Console:  psql -h localhost -p 6432 -U pgbouncer_admin pgbouncer"
else
  echo ">> DSN:      postgresql://${ROLE}:<pw>@<host>:6432/${DB:-<db>}?sslmode=verify-full&sslrootcert=<ca.pem>"
fi
