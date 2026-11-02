#!/usr/bin/env bash
# sslgen.sh — generate a local CA + server TLS certificate for PgBouncer.
# Output: ./ssl/{ca.pem, cert.pem, privkey.pem}  +  ./ssl-ca/ca-key.pem
# The CA key deliberately lives OUTSIDE ./ssl — that directory is bind-mounted
# into the pgbouncer container (compose.yml); the signing key never ships with it.
#
# The CA is REUSED across runs (rotate it by deleting ssl/ca.pem); --force only
# re-issues the server certificate, e.g. to add SANs — apps keep trusting the
# same CA.
#
# Usage: ./sslgen.sh <hostname> [extra-san ...] [--force]
#   Every argument becomes a SAN (DNS: or IP: auto-detected), e.g.:
#     ./sslgen.sh pgbouncer 10.8.0.1 127.0.0.1 localhost
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="$SCRIPT_DIR/ssl"
CA_KEY_DIR="$SCRIPT_DIR/ssl-ca"

usage() { echo "Usage: $0 <hostname> [extra-san ...] [--force]" >&2; }

FORCE=0
HOSTNAME_IN=""
EXTRA_SANS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) if [ -z "$HOSTNAME_IN" ]; then
         HOSTNAME_IN="$1"
       else
         EXTRA_SANS+=("$1")
       fi
       shift;;
  esac
done

if [ -z "$HOSTNAME_IN" ]; then
  echo "error: hostname is required" >&2; usage; exit 2
fi

# SAN type: IPv4 address vs DNS name
san_of() {
  if [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then printf 'IP:%s' "$1"
  else printf 'DNS:%s' "$1"
  fi
}
SAN="$(san_of "$HOSTNAME_IN")"
for extra in "${EXTRA_SANS[@]}"; do
  SAN="$SAN,$(san_of "$extra")"
done

# Don't clobber existing server cert/key unless --force (the CA is reused, not
# rotated, by --force — see header).
if [ "$FORCE" != "1" ]; then
  for f in cert.pem privkey.pem; do
    if [ -f "$SSL_DIR/$f" ]; then
      echo "error: $SSL_DIR/$f already exists. Re-run with --force to overwrite." >&2
      exit 1
    fi
  done
fi

mkdir -p "$SSL_DIR" "$CA_KEY_DIR"
# pgbouncer runs as YOUR uid (compose `user:`) — no world traversal needed.
chmod 700 "$SSL_DIR" "$CA_KEY_DIR"
cd "$SSL_DIR"

# One-time migration from the old layout (CA key inside the mounted ./ssl)
if [ -f ca-key.pem ] && [ ! -f "$CA_KEY_DIR/ca-key.pem" ]; then
  mv ca-key.pem "$CA_KEY_DIR/ca-key.pem"
  echo ">> moved existing ca-key.pem -> $CA_KEY_DIR/ca-key.pem (outside the container mount)"
fi

if [ ! -f ca.pem ] || [ ! -f "$CA_KEY_DIR/ca-key.pem" ]; then
  echo ">> Generating local CA ..."
  openssl genrsa -out "$CA_KEY_DIR/ca-key.pem" 4096 2>/dev/null
  chmod 600 "$CA_KEY_DIR/ca-key.pem"
  openssl req -x509 -new -key "$CA_KEY_DIR/ca-key.pem" -sha256 -days 3650 \
    -subj "/CN=${HOSTNAME_IN} local CA" -out ca.pem \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
else
  echo ">> Reusing existing CA (ssl/ca.pem) — server cert gets the new SANs"
fi

echo ">> Generating server certificate for '$HOSTNAME_IN' (SAN: $SAN) ..."
# Stage everything first; the live ./ssl files are only replaced after the
# key/cert pair proves consistent — an interrupted run can never leave a
# mismatched (or half-written) pair behind.
STAGING="$SSL_DIR/.staging"
rm -rf "$STAGING"; mkdir "$STAGING"; chmod 700 "$STAGING"
openssl genrsa -out "$STAGING/privkey.pem" 2048 2>/dev/null
openssl req -new -key "$STAGING/privkey.pem" -subj "/CN=${HOSTNAME_IN}" -out "$STAGING/server.csr"
cat > "$STAGING/server.ext" <<EOF
subjectAltName=$SAN
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "$STAGING/server.csr" -CA ca.pem -CAkey "$CA_KEY_DIR/ca-key.pem" -CAcreateserial \
  -out "$STAGING/cert.pem" -days 825 -sha256 -extfile "$STAGING/server.ext"

# Pair + chain verification BEFORE publishing (a bad pair never lands):
openssl x509 -in "$STAGING/cert.pem" -noout -pubkey > "$STAGING/cert.pub"
openssl pkey -in "$STAGING/privkey.pem" -pubout > "$STAGING/key.pub" 2>/dev/null
if ! cmp -s "$STAGING/cert.pub" "$STAGING/key.pub"; then
  echo "error: generated key/cert pair mismatch — nothing written" >&2
  rm -rf "$STAGING"; exit 1
fi
openssl verify -CAfile ca.pem "$STAGING/cert.pem" || { rm -rf "$STAGING"; exit 1; }

# Publish: renames within ./ssl are atomic per file and container-visible
# (./ssl is a DIRECTORY mount — it follows paths, not inodes, unlike the
# single-file mounts where in-place writes are mandatory).
chmod 600 "$STAGING/privkey.pem"
chmod 644 "$STAGING/cert.pem"
mv "$STAGING/privkey.pem" privkey.pem
mv "$STAGING/cert.pem" cert.pem
rm -rf "$STAGING" server.csr server.ext ca.srl

# Permissions: pgbouncer runs as YOUR uid in the container (compose `user:`),
# so the private key never needs to be world-readable.
chmod 644 ca.pem

echo ">> NOTE: if the stack is running, load the new cert/key:"
echo "         docker compose restart pgbouncer"

echo ">> Certificate SAN:"
openssl x509 -in cert.pem -noout -ext subjectAltName | sed 's/^/   /'

echo ""
echo ">> Done. Certs in $SSL_DIR, CA key in $CA_KEY_DIR (never mounted anywhere)."
echo ""
echo "App connection (distribute ssl/ca.pem to each app):"
echo "   host=<any SAN above> port=6432 sslmode=verify-full sslrootcert=/path/ca.pem"
