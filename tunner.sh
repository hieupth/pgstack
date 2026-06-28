#!/usr/bin/env bash
# tunner.sh — detect host hardware, generate tuned PostgreSQL + PgBouncer config
# from templates, and verify the generated postgresql.conf actually boots in a
# throwaway postgres container.
#
# Run on the host that runs the stack, BEFORE `docker compose up`.
#   ./tunner.sh
#   ./tunner.sh --ram 3840 --cpu 3 --disk ssd     # explicit overrides
#   ./tunner.sh --no-verify                        # skip the docker boot check
#
# Proxmox LXC/VM: in-container detection of CPU/disk is often wrong (nproc may
# report host cores; virtio rotational flag may lie). Pass --cpu/--ram/--disk
# from your container's actual Proxmox allocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_TEMPLATE="$SCRIPT_DIR/postgresql.conf.template"
PG_OUT="$SCRIPT_DIR/postgresql.conf"
BOUNCER_TEMPLATE="$SCRIPT_DIR/pgbouncer.ini.template"
BOUNCER_OUT="$SCRIPT_DIR/pgbouncer.ini"
PG_IMAGE="postgres:17"
PG_MAX_CONNECTIONS=150   # PostgreSQL backend cap; also drives pgbouncer max_db_connections

usage() {
  cat <<EOF
Usage: $0 [options]

Generate tuned postgresql.conf + pgbouncer.ini from templates based on this host.

Options:
  --ram MB      override detected RAM in MB        (e.g. 3840)
  --cpu N       override detected CPU cores        (e.g. 6)
  --disk TYPE   force disk type: ssd | hdd
  --no-verify   skip the docker postgres boot check
  -h, --help    show this help
EOF
}

# ---- arg parsing
OPT_RAM=""; OPT_CPU=""; OPT_DISK=""; OPT_VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --ram)        OPT_RAM="$2";  shift 2;;
    --cpu)        OPT_CPU="$2";  shift 2;;
    --disk)       OPT_DISK="$2"; shift 2;;
    --no-verify)  OPT_VERIFY=0;  shift;;
    -h|--help)    usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# ---- hardware detection
detect_cpu() {
  if [ -n "$OPT_CPU" ]; then printf '%s' "$OPT_CPU"; return; fi
  nproc 2>/dev/null || true
}

detect_ram() {
  if [ -n "$OPT_RAM" ]; then printf '%s' "$OPT_RAM"; return; fi
  awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null \
    || free -m 2>/dev/null | awk '/^Mem:/{print $2}' \
    || true
}

DETECTED_DEV=""
detect_disk() {
  # prints "0" (SSD), "1" (HDD), or "" (unknown); sets DETECTED_DEV
  if [ -n "$OPT_DISK" ]; then
    case "$OPT_DISK" in
      ssd) printf '0';; hdd) printf '1';; *) printf '';;
    esac; return
  fi
  local dev base rota
  dev="$(df --output=source "$SCRIPT_DIR" 2>/dev/null | tail -1 || true)"
  DETECTED_DEV="$dev"
  base="$(basename "${dev:-x}")"
  # Virtual/NVMe devices are virtually always non-rotational (handles Proxmox virtio lying)
  case "$base" in
    nvme*|vd*|xvd*|pmem*|mmcblk*) printf '0'; return;;
  esac
  if [ -n "$dev" ]; then
    rota="$(lsblk -ndo ROTA "$dev" 2>/dev/null | tr -dc '01' || true)"
    if [ -n "$rota" ]; then printf '%s' "$rota"; return; fi
    if [ -f "/sys/block/$base/queue/rotational" ]; then
      cat "/sys/block/$base/queue/rotational"; return
    fi
  fi
  printf ''
}

echo ">> Detecting hardware..."
CPU="$(detect_cpu)"; RAM="$(detect_ram)"; DISK="$(detect_disk)"

if [ -z "$CPU" ]; then
  CPU="$(nproc 2>/dev/null || printf '4')"
fi
if ! [[ "$CPU" =~ ^[0-9]+$ ]] || [ "$CPU" -lt 1 ]; then
  echo "ERROR: invalid CPU count '$CPU'" >&2; exit 1
fi
if [ -z "$RAM" ]; then
  echo "ERROR: cannot detect RAM (no /proc/meminfo or free). Re-run with --ram MB" >&2
  exit 1
fi
if ! [[ "$RAM" =~ ^[0-9]+$ ]] || [ "$RAM" -lt 256 ]; then
  echo "ERROR: invalid RAM '$RAM' MB (minimum 256)" >&2; exit 1
fi

case "$DISK" in
  0) DISK_TYPE="SSD";;
  1) DISK_TYPE="HDD";;
  *) DISK="0"; DISK_TYPE="SSD (assumed — confirm with --disk ssd|hdd)";;
esac

printf '   CPU=%s cores   RAM=%sMB   Disk=%s   device=%s\n' \
  "$CPU" "$RAM" "$DISK_TYPE" "${DETECTED_DEV:-(n/a)}"

# ---- PGTune-style heuristics
compute() {
  SHARED_BUFFERS=$(( RAM / 4 ))
  EFFECTIVE_CACHE_SIZE=$(( RAM * 3 / 4 ))
  MAINTENANCE_WORK_MEM=$(( RAM / 8 ))
  if [ "$MAINTENANCE_WORK_MEM" -gt 2048 ]; then MAINTENANCE_WORK_MEM=2048; fi
  if [ "$MAINTENANCE_WORK_MEM" -lt 64 ];  then MAINTENANCE_WORK_MEM=64; fi

  local per_gather=$(( CPU / 2 ))
  if [ "$per_gather" -lt 1 ]; then per_gather=1; fi
  MAX_PARALLEL_WORKERS_PER_GATHER=$per_gather
  MAX_PARALLEL_MAINTENANCE_WORKERS=$per_gather

  # work_mem is driven by expected concurrent connections, not parallelism (the
  # x3 already accounts for multiple sort/hash nodes per query).
  WORK_MEM=$(( (RAM - SHARED_BUFFERS) / (PG_MAX_CONNECTIONS * 3) ))
  if [ "$WORK_MEM" -lt 4 ]; then WORK_MEM=4; fi

  # PgBouncer: keep the backend pool coherent with postgres max_connections and
  # scale the per-(db,user) pool to cores. These are STARTING POINTS - measure
  # real load and tune (see README "Tuning PgBouncer").
  MAX_DB_CONNECTIONS=$(( PG_MAX_CONNECTIONS - 30 ))   # room for admin/maint/autovacuum
  DEFAULT_POOL_SIZE=$(( CPU * 3 ))
  if [ "$DEFAULT_POOL_SIZE" -lt 10 ]; then DEFAULT_POOL_SIZE=10; fi
  if [ "$DEFAULT_POOL_SIZE" -gt 50 ]; then DEFAULT_POOL_SIZE=50; fi

  WAL_BUFFERS=$(( SHARED_BUFFERS / 32 ))
  if [ "$WAL_BUFFERS" -gt 16 ]; then WAL_BUFFERS=16; fi
  if [ "$WAL_BUFFERS" -lt 1 ];  then WAL_BUFFERS=1; fi

  MAX_WORKER_PROCESSES=$(( CPU + 4 ))   # headroom: autovacuum(2) + parallel + launcher
  MAX_PARALLEL_WORKERS=$CPU

  if [ "$DISK" = "1" ]; then
    RANDOM_PAGE_COST="4.0"; EFFECTIVE_IO_CONCURRENCY=0
  else
    RANDOM_PAGE_COST="1.1"; EFFECTIVE_IO_CONCURRENCY=200
  fi
}
compute

printf '   -> shared_buffers=%sMB  effective_cache_size=%sMB  work_mem=%sMB  maintenance_work_mem=%sMB\n' \
  "$SHARED_BUFFERS" "$EFFECTIVE_CACHE_SIZE" "$WORK_MEM" "$MAINTENANCE_WORK_MEM"
printf '   -> max_worker_processes=%s  parallel=%s/%s  maintenance_parallel=%s  wal_buffers=%sMB\n' \
  "$MAX_WORKER_PROCESSES" "$MAX_PARALLEL_WORKERS" "$MAX_PARALLEL_WORKERS_PER_GATHER" \
  "$MAX_PARALLEL_MAINTENANCE_WORKERS" "$WAL_BUFFERS"
printf '   -> max_connections=%s   pgbouncer: max_db_connections=%s  default_pool_size=%s\n' \
  "$PG_MAX_CONNECTIONS" "$MAX_DB_CONNECTIONS" "$DEFAULT_POOL_SIZE"
printf '   -> random_page_cost=%s  effective_io_concurrency=%s\n' \
  "$RANDOM_PAGE_COST" "$EFFECTIVE_IO_CONCURRENCY"

# ---- render templates: substitute @TOKEN@ -> value, fail on leftovers
render() {
  local tmpl="$1" out="$2"
  if [ ! -f "$tmpl" ]; then echo "ERROR: missing template $tmpl" >&2; exit 1; fi
  sed \
    -e "s|@SHARED_BUFFERS@|$SHARED_BUFFERS|g" \
    -e "s|@EFFECTIVE_CACHE_SIZE@|$EFFECTIVE_CACHE_SIZE|g" \
    -e "s|@WORK_MEM@|$WORK_MEM|g" \
    -e "s|@MAINTENANCE_WORK_MEM@|$MAINTENANCE_WORK_MEM|g" \
    -e "s|@WAL_BUFFERS@|$WAL_BUFFERS|g" \
    -e "s|@MAX_WORKER_PROCESSES@|$MAX_WORKER_PROCESSES|g" \
    -e "s|@MAX_PARALLEL_WORKERS@|$MAX_PARALLEL_WORKERS|g" \
    -e "s|@MAX_PARALLEL_WORKERS_PER_GATHER@|$MAX_PARALLEL_WORKERS_PER_GATHER|g" \
    -e "s|@MAX_PARALLEL_MAINTENANCE_WORKERS@|$MAX_PARALLEL_MAINTENANCE_WORKERS|g" \
    -e "s|@MAX_CONNECTIONS@|$PG_MAX_CONNECTIONS|g" \
    -e "s|@MAX_DB_CONNECTIONS@|$MAX_DB_CONNECTIONS|g" \
    -e "s|@DEFAULT_POOL_SIZE@|$DEFAULT_POOL_SIZE|g" \
    -e "s|@RANDOM_PAGE_COST@|$RANDOM_PAGE_COST|g" \
    -e "s|@EFFECTIVE_IO_CONCURRENCY@|$EFFECTIVE_IO_CONCURRENCY|g" \
    -e "s|@DISK_TYPE@|$DISK_TYPE|g" \
    "$tmpl" > "$out"
  if grep -qE '@[A-Z_]+@' "$out"; then
    echo "ERROR: unsubstituted token(s) in $out:" >&2
    grep -nE '@[A-Z_]+@' "$out" >&2
    exit 1
  fi
}

echo ">> Rendering postgresql.conf ..."
render "$PG_TEMPLATE" "$PG_OUT"
echo ">> Rendering pgbouncer.ini ..."
render "$BOUNCER_TEMPLATE" "$BOUNCER_OUT"

# ---- verify postgresql.conf boots in a throwaway postgres container
verify() {
  command -v docker >/dev/null 2>&1 || { echo "   (docker not found; skipping boot check)"; return 0; }
  docker info >/dev/null 2>&1 || { echo "   (docker daemon not reachable; skipping boot check)"; return 0; }
  if ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
    echo "   pulling $PG_IMAGE ..."
    if ! docker pull "$PG_IMAGE" >/dev/null 2>&1; then
      echo "   (cannot pull $PG_IMAGE; skipping boot check)"
      return 0
    fi
  fi
  echo ">> Verifying postgresql.conf boots (postgres test container) ..."
  local name="pgstack-tunner-$$" log
  log="$(mktemp)"
  trap "docker rm -f $name >/dev/null 2>&1 || true; rm -f $log" EXIT
  docker run -d --name "$name" \
    -v "$PG_OUT":/etc/postgresql/postgresql.conf:ro \
    -e POSTGRES_PASSWORD=dummy \
    "$PG_IMAGE" \
    postgres -c config_file=/etc/postgresql/postgresql.conf >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    docker logs "$name" >"$log" 2>&1 || true
    if grep -qi "database system is ready to accept connections" "$log"; then
      echo "   OK - postgres accepted the generated config."
      return 0
    fi
    if grep -qiE "FATAL|invalid configuration parameter|unrecognized configuration parameter|syntax error" "$log"; then
      echo "   FAIL - postgres rejected the config:" >&2
      grep -iE "FATAL|invalid|unrecognized|syntax|error" "$log" | head -5 >&2
      return 1
    fi
    sleep 1
  done
  echo "   TIMEOUT - no ready/error within 30s. Last logs:" >&2
  tail -5 "$log" >&2
  return 1
}

if [ "$OPT_VERIFY" = "1" ]; then
  verify || { echo "Verification failed. Generated files were left for inspection." >&2; exit 1; }
fi

echo ">> Done. Generated:"
echo "   - postgresql.conf"
echo "   - pgbouncer.ini"
echo "Next: docker compose up -d"
