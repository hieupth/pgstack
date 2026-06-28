#!/usr/bin/env bash
# sslgen.sh — generate a local CA + server TLS certificate for PgBouncer.
# Output: ./ssl/{ca.pem, cert.pem, privkey.pem}  (+ ca-key.pem, kept to sign future certs)
# Usage: ./sslgen.sh <hostname> [--force]
#   <hostname> becomes the certificate SAN, e.g. pgsql01.hieupth.com or 203.0.113.5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="$SCRIPT_DIR/ssl"

usage() { echo "Usage: $0 <hostname> [--force]" >&2; }

FORCE=0
HOSTNAME_IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) if [ -n "$HOSTNAME_IN" ]; then
         echo "error: unexpected arg '$1'" >&2; usage; exit 2
       fi
       HOSTNAME_IN="$1"; shift;;
  esac
done

if [ -z "$HOSTNAME_IN" ]; then
  echo "error: hostname is required" >&2; usage; exit 2
fi

# SAN type: IPv4 address vs DNS name
if [[ "$HOSTNAME_IN" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
  SAN="IP:${HOSTNAME_IN}"
else
  SAN="DNS:${HOSTNAME_IN}"
fi

# Don't clobber existing certs unless --force
if [ "$FORCE" != "1" ]; then
  for f in ca.pem cert.pem privkey.pem; do
    if [ -f "$SSL_DIR/$f" ]; then
      echo "error: $SSL_DIR/$f already exists. Re-run with --force to overwrite." >&2
      exit 1
    fi
  done
fi

mkdir -p "$SSL_DIR"
chmod 755 "$SSL_DIR"   # traversable by the container uid (pgbouncer/70)
cd "$SSL_DIR"

echo ">> Generating local CA ..."
openssl genrsa -out ca-key.pem 4096 2>/dev/null
openssl req -x509 -new -key ca-key.pem -sha256 -days 3650 \
  -subj "/CN=${HOSTNAME_IN} local CA" -out ca.pem \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

echo ">> Generating server certificate for '$HOSTNAME_IN' (SAN: $SAN) ..."
openssl genrsa -out privkey.pem 2048 2>/dev/null
openssl req -new -key privkey.pem -subj "/CN=${HOSTNAME_IN}" -out server.csr
cat > server.ext <<EOF
subjectAltName=$SAN
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out cert.pem -days 825 -sha256 -extfile server.ext
rm -f server.csr server.ext ca.srl

# Permissions: pgbouncer in the container runs as uid 70 (not root) and can't read
# a host-owned 600 key, so make the key world-readable (644). ./ssl is 755 so uid 70
# can traverse it. ca-key.pem stays 600 - the container never needs it, so the CA
# key stays protected.
# (Stricter option: run pgbouncer as YOUR uid via `user:` in compose.yml, keep key 600.)
chmod 600 ca-key.pem
chmod 644 ca.pem cert.pem privkey.pem

echo ">> Verifying CA signs the server cert ..."
openssl verify -CAfile ca.pem cert.pem

echo ">> Certificate SAN:"
openssl x509 -in cert.pem -noout -ext subjectAltName | sed 's/^/   /'

echo ""
echo ">> Done. Files in $SSL_DIR :"
( cd "$SSL_DIR" && ls -l ca.pem cert.pem privkey.pem ca-key.pem )
echo ""
echo "App connection (distribute ca.pem to each app):"
echo "   host=$HOSTNAME_IN port=6432 sslmode=verify-full sslrootcert=/path/to/ca.pem"
echo "(Tip: use Let's Encrypt on $HOSTNAME_IN so apps trust it without ca.pem.)"
