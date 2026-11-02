# PostgreSQL Performance Stack

A production-ready PostgreSQL + PgBouncer stack. Configuration is **generated from templates** by `tunner.sh` to match the host hardware — it is never hand-tuned to one machine.

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Applications  │───→│    PgBouncer    │───→│   PostgreSQL    │
│                 │    │ Connection Pool │    │   Databases     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
       :6432 (TLS, loopback + WireGuard)   internal only
```

## Quick start

```bash
./setup.sh pgsql01.hieupth.com   # secrets + TLS + tuned config + up + admin user
./cred.sh zitadel zitadel        # each app: role + db + verifier + creds/zitadel.pw
```

`setup.sh` generates every secret (superuser, console user), refuses to run on
the `changeme` placeholder against an existing `data/`, and leaves all plaintext
copies in `./creds/` (chmod 600, gitignored). `postgresql.conf`, `pgbouncer.ini`,
and `ssl/` are generated and gitignored — re-run `./tunner.sh` after pulling
template changes.

## Secrets & authentication model

| Secret | Where | Who uses it |
| --- | --- | --- |
| superuser password | `./password` (+ copy `./creds/postgres.pw`) | postgres, **only at first `initdb`** — inert afterwards; break-glass access is `docker exec` (trusted unix socket) |
| `pgbouncer_admin` | `./creds/pgbouncer_admin.pw` | PgBouncer admin console |
| each app role | `./creds/<role>.pw` | that app's DSN |

`./userlist.txt` holds **SCRAM verifiers only** — copied byte-identical from
`pg_shadow` by `./cred.sh` (required for PgBouncer SCRAM pass-through). No
plaintext lives in it; clients must speak SCRAM (every modern driver does).

## Admin console

The PgBouncer console (virtual database `pgbouncer`) is guarded by a dedicated
`pgbouncer_admin` user with a **random password — never the postgres superuser**.
Until `./cred.sh pgbouncer_admin` has run once, the console is unreachable (by
design: forgetting costs you nothing).

```bash
./cred.sh pgbouncer_admin     # first run = create; every later run = rotate
cat creds/pgbouncer_admin.pw  # chmod 600 — the only plaintext copy
psql -h localhost -p 6432 -U pgbouncer_admin pgbouncer   # e.g. SHOW POOLS;
```

## Remote app access (WireGuard only)

`6432` binds to loopback **plus this host's WireGuard address** (`WG_BIND` in
`.env`, default `10.8.0.1`) — nothing is exposed on the public internet. Every
app VPS joins the same WireGuard network (kernel-built-in, no daemon to run):

```ini
# /etc/wireguard/wg0.conf — DB host (hub)
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <db-host-private-key>

[Peer]                          # one block per app VPS
PublicKey = <app-vps-public-key>
AllowedIPs = 10.8.0.11/32
```

```ini
# /etc/wireguard/wg0.conf — app VPS
[Interface]
Address = 10.8.0.11/24
PrivateKey = <app-vps-private-key>

[Peer]
PublicKey = <db-host-public-key>
Endpoint = pgsql01.hieupth.com:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
```

`systemctl enable --now wg-quick@wg0` on both sides, then set
`WG_BIND=10.8.0.1` in `.env` (setup.sh does this automatically once the address
exists on an interface) and `docker compose up -d`. The server certificate
carries `IP:10.8.0.1` (plus `127.0.0.1`/`localhost`) as SANs, so apps verify it
fully — no sslmode downgrades needed:

```
postgresql://zitadel:<pw>@10.8.0.1:6432/zitadel?sslmode=verify-full&sslrootcert=/path/ca.pem
```

One-off admin from anywhere: `ssh -L 6432:127.0.0.1:6432 <host>`, then use
`psql -h localhost` as above.

Defense-in-depth (optional, needs root once): the WG bind itself only answers
on the tunnel address — peers cannot route to it without valid keys — but you
can also enforce it at the firewall:

```
nft add rule inet filter input iifname "wg0" tcp dport 6432 accept
nft add rule inet filter input tcp dport 6432 drop
```

## Tuning (`tunner.sh`)

Detects CPU cores, RAM, and disk type, then writes both config files from templates:

- **PostgreSQL** — full PGTune-style hardware tuning: `shared_buffers` ≈ 25% RAM, `effective_cache_size` ≈ 75%, `work_mem` scaled to RAM/connections, worker/parallel settings scaled to cores, SSD/HDD I/O params.
- **PgBouncer** — `default_pool_size`/`pool_size` scaled to cores, `max_db_connections`/`max_user_connections` tied to `max_connections` (and split per app via `--apps`); the rest stays workload-driven (tune under load — see below).

It then verifies the generated `postgresql.conf` boots in a throwaway postgres container.

```bash
./tunner.sh                                  # auto-detect
./tunner.sh --ram 3840 --cpu 3 --disk ssd    # explicit overrides
./tunner.sh --apps 4                         # 4 app databases: per-app backend
                                              # budget = (max_connections-30)/4
./tunner.sh --no-verify                      # skip the docker boot check
```

`max_db_connections`/`max_user_connections` are **per** database/user: with N
app databases their budgets must sum below `max_connections` — that is what
`--apps N` does (Σ Bᵢ ≤ max_connections − 30).

### PgBouncer under load (measure, don't guess)

These are safe starting points, not optimal values. After running under real load, inspect the admin console:

```bash
psql -h localhost -p 6432 -U pgbouncer_admin pgbouncer   # then (pw: cat creds/pgbouncer_admin.pw):
SHOW POOLS;      # cl_waiting > 0 => clients wait => raise default_pool_size/reserve_pool_size
SHOW STATS;      # avg_query_time, total_query_count per db
```

If `cl_waiting` grows, raise the pool; if `sv_active` stays well above 2-3x cores, the box itself is the bottleneck (add hardware, don't raise the pool). Re-run `./tunner.sh` only after a hardware change.

## Security checklist

- **Secrets**: all generated by `./setup.sh`/`./cred.sh`, stored in `./creds/` (600, gitignored) — see Secrets & authentication model. The superuser password only takes effect at first `initdb`; rotating it later requires `ALTER USER postgres PASSWORD '...'` inside the cluster. `userlist.txt` contains SCRAM verifiers only (no plaintext anywhere on disk).
- **Port 6432 binds to loopback + the WireGuard address only** — nothing is exposed off-host by default; remote apps come in via WireGuard, one-off admin via an SSH tunnel (see Remote app access).
- **Admin console** requires the dedicated `pgbouncer_admin` user (random password from `./cred.sh pgbouncer_admin`), never the postgres superuser. Connection logging (`log_connections`) is on at both layers.
- `pg_hba.conf` is mounted and wired via `hba_file`: SCRAM on every TCP path; trust only on the container-local unix socket (`docker exec` = host root).
- TLS is enforced app→PgBouncer (`client_tls_sslmode = require`). The server cert's SANs cover every access path (WireGuard IP, `127.0.0.1`, `localhost`) — always use `sslmode=verify-full` + `ca.pem`. Re-issuing the cert (`sslgen.sh ... --force`) needs `docker compose restart pgbouncer` to take effect. PgBouncer→PostgreSQL TLS is optional (see `pgbouncer.ini.template`).
- **Images are digest-pinned** (`image: tag@sha256:...`) — a moved tag can never silently change what runs. Note both `docker compose pull` and `docker images --digests` re-show the *pinned* digest and cannot tell you a newer one exists; check freshness against the Hub and bump deliberately:
  `curl -s https://hub.docker.com/v2/repositories/library/postgres/tags/17 | jq -r .digest` (same for `edoburu/pgbouncer/tags/v1.26.1-p0`), compare with `compose.yml`, then update the digest and `docker compose up -d`.
- **The superuser can never log in over TCP** — `pg_hba.conf` rejects user `postgres` on every host line (break-glass is `docker exec` only). The host itself can route to container IPs on the docker bridge, so this is what makes a readable `./password` worthless to any local process.
- Idle pgbouncer clients are evicted after 10 min (`client_idle_timeout = 600`) — one leaked app password cannot starve every tenant by holding `max_client_conn` idle.
- Cert expiry has **no automation by design** — calendar it: `openssl x509 -in ssl/cert.pem -noout -enddate` (server cert ~2.3y, CA ~10y; renew: `./sslgen.sh <host> <wg-ip> 127.0.0.1 localhost --force` + `docker compose restart pgbouncer`).
- `/var/lib/docker` grows with every deliberate image bump (digest pins accumulate) — `docker image prune` after each update.
- **Secret file permissions**: pgbouncer runs as your uid (`.env` → compose `user:`), so `userlist.txt` and the TLS key are `0600`; the CA signing key lives in `./ssl-ca/` (never mounted into any container); `./password` is locked to `0600` uid 999 when root/sudo is available. Compose file-secrets are plain bind mounts — docker does not enforce modes, the scripts do.
- Slow-query logging never writes bind-parameter values (`log_parameter_max_length = 0`); query text with `$n` placeholders is still logged.
- `pg_stat_statements` is preloaded — run `CREATE EXTENSION pg_stat_statements;` in each database to query it.
- **Backups**: run `./backup.sh` from cron and copy dumps off-host (see Backups).

## Backups

```bash
./backup.sh    # globals + every database -> ./backups/ (custom format, gzipped globals)
# cron — the OPERATOR's crontab (`crontab -e` as that user), never root's
# (root-owned dumps break the operator-run DR restore; /etc/cron.d also
# requires a user field, a bare paste there is silently ignored):
15 3 * * *  cd /path/to/pgstack && mkdir -p backups && ./backup.sh >> backups/backup.log 2>&1
```

Keeps `BACKUP_KEEP_DAYS` (default 14) days of dumps locally — copy them off-host
(rclone/rsync); a backup that lives only on this VPS is not a backup. Two rules
for the off-host copy:

- **Encrypt it** (`age`/`gpg`, or an `rclone crypt` remote): the globals dump
  contains every role's **SCRAM verifier** — the same bytes pgbouncer
  authenticates against. 192-bit random passwords make offline attack
  infeasible *today*, but the dump must not sit plaintext on third-party
  storage the day any role gets a hand-chosen password.
- **Bundle the host-only secrets with it**: `creds/`, `userlist.txt`,
  `ssl-ca/`, `.env`. They live on this VPS and nowhere else — lose the host
  and you lose the restore path itself (every app credential, the CA key,
  the TLS identity), even with perfect dumps in hand.

Restore a database **directly through the postgres container** (not through PgBouncer):

```bash
docker compose exec -T postgresql pg_restore -U postgres -C -d postgres backups/<db>-<stamp>.dump
```

### Disaster recovery (full cluster — tested end-to-end)

```bash
./backup.sh                                                  # fresh backup
# STOP — before wiping anything, prove the fresh dumps are readable:
pg_restore -l backups/zitadel-<stamp>.dump >/dev/null && echo "dump OK"   # per dump
docker compose down
# Wipe the old cluster. The guard refuses to run from any directory not named
# pgstack — `rm -rf` on a wrong $PWD must not be possible:
[ "${PWD##*/}" = "pgstack" ] && docker run --rm -v "$PWD/data":/data alpine sh -c 'rm -rf /data/*' \
  || echo "REFUSING: run from the pgstack checkout"
docker compose up -d --wait                                  # fresh cluster; same ./password = same superuser
zcat backups/globals-<stamp>.sql.gz | docker compose exec -T postgresql psql -U postgres
# EXPECTED above: exactly one `ERROR: role "postgres" already exists` — the
# fresh initdb already created the superuser; every other role + password still
# applies. Do NOT add ON_ERROR_STOP (it aborts the whole globals restore).
# Any OTHER error: stop and inspect. Globals MUST run before the dumps — the
# dump's ALTER ... OWNER statements need their roles to exist.
for f in backups/*-<stamp>.dump; do
  case "${f##*/}" in postgres-*) continue;; esac              # postgres db exists already; -C would error on it
  docker compose exec -T postgresql pg_restore -U postgres -C -d postgres < "$f"
done
docker compose restart pgbouncer                             # clear cached auth state
./setup.sh <hostname>                                        # RE-APPLY hardening lost in the fresh cluster
```

Tested: roles come back with identical SCRAM verifiers, so apps reconnect with
their existing credentials (userlist/creds live on the host, not in data/).
Note the last step provisions `pgbouncer_admin` only if missing — it does
**not** rotate the console password on re-run (rotate deliberately with
`./cred.sh pgbouncer_admin`). The REVOKE CONNECT
hardening on `postgres`/`template1` is NOT part of the globals dump, which is
why the final `setup.sh` re-run is required.

## License

[Apache License 2.0](LICENSE).<br>
Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth).
