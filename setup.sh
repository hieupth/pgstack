#!/usr/bin/env bash
# setup.sh — one-shot first-boot bring-up:
#   secrets -> TLS certs -> tuned configs -> stack up -> admin console user.
# All generated secrets land in ./creds/ (chmod 600, gitignored).
#
# Usage: ./setup.sh <public-hostname> [tunner.sh options]
#   e.g. ./setup.sh pgsql01.hieupth.com
#        ./setup.sh pgsql01.hieupth.com --ram 3840 --cpu 3 --disk ssd
# Extra args are forwarded to ./tunner.sh (hardware overrides — use them when
# auto-detection is wrong or unavailable, e.g. Proxmox LXC).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOSTNAME_IN="${1:-}"
[ -n "$HOSTNAME_IN" ] || { echo "Usage: $0 <public-hostname> [tunner.sh options]" >&2; exit 2; }
shift

# umask 022 on purpose: ./password and ./userlist.txt must be readable by the
# containers (uid 999) that consume them as compose secrets. ./creds/* is
# admin-only and gets explicit chmod 600 below. (Do NOT set umask 077 globally:
# tunner.sh inherits it and renders 600 configs postgres cannot read.)
mkdir -p creds; umask 022

# ---- 1. superuser password -------------------------------------------------
# Nobody ever types this password (superuser access is `docker exec` over the
# trusted container-local unix socket), so it is GENERATED, never hand-edited.
# ./password is consumed by postgres ONLY at first initdb (fresh data/).
if [ -d data ]; then
  if grep -qx changeme password 2>/dev/null; then
    echo "ERROR: data/ exists AND ./password is 'changeme' — the initialized" >&2
    echo "       cluster's superuser password is the public placeholder. Either:" >&2
    echo "         a) delete data/ for a fresh start, or" >&2
    echo "         b) rotate it now:" >&2
    echo "            docker compose exec -T postgresql psql -U postgres \\" >&2
    echo "              -c \"ALTER USER postgres PASSWORD '<strong-password>'\"" >&2
    echo "            then write the same value to ./password and ./creds/postgres.pw." >&2
    exit 1
  fi
  echo ">> data/ exists — keeping ./password as-is (inert for an initialized cluster)"
else
  if [ ! -f password ] || grep -qx changeme password 2>/dev/null; then
    openssl rand -base64 24 > password
    cp password creds/postgres.pw
    chmod 600 creds/postgres.pw
    echo ">> generated superuser password -> ./password (copy: creds/postgres.pw)"
  fi
fi
[ -f password ] || openssl rand -base64 24 > password   # compose mounts it as a secret

# ---- 2. pgbouncer auth_file (SCRAM verifiers only — starts empty) ----------
[ -f userlist.txt ] || : > userlist.txt

# ---- 3. TLS certs ------------------------------------------------------------
if [ ! -f ssl/ca.pem ]; then
  ./sslgen.sh "$HOSTNAME_IN"
else
  echo ">> ssl/ exists — skipping sslgen"
fi

# ---- 4. tuned configs --------------------------------------------------------
./tunner.sh "$@"

# ---- 5. stack up ---------------------------------------------------------------
docker compose up -d --wait

# Harden: no role may CONNECT to the admin databases (superuser/owner exempt).
# App databases get the same treatment in ./cred.sh; without this, any app
# role could connect to `postgres` (catalog metadata + temp-table disk abuse).
docker compose exec -T postgresql psql -U postgres -q \
  -c 'REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC'

# ---- 6. admin console user -----------------------------------------------------
./cred.sh pgbouncer_admin

cat <<'EOF'

Done.
  Admin console : psql -h localhost -p 6432 -U pgbouncer_admin pgbouncer
                  (password: cat creds/pgbouncer_admin.pw)
  Add an app    : ./cred.sh <role> [<db>]     e.g. ./cred.sh zitadel zitadel
  Remote access : tailscale serve --bg --tcp=6432 tcp://127.0.0.1:6432
                  (tailnet only — NEVER `funnel` for a database)
EOF
