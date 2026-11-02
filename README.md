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
- **Images are digest-pinned** (`image: tag@sha256:...`) — a moved tag can never silently change what runs. Update deliberately: `docker compose pull`, check `docker images --digests`, then update the digest in `compose.yml`.
- **Secret file permissions**: pgbouncer runs as your uid (`.env` → compose `user:`), so `userlist.txt` and the TLS key are `0600`; the CA signing key lives in `./ssl-ca/` (never mounted into any container); `./password` is locked to `0600` uid 999 when root/sudo is available. Compose file-secrets are plain bind mounts — docker does not enforce modes, the scripts do.
- Slow-query logging never writes bind-parameter values (`log_parameter_max_length = 0`); query text with `$n` placeholders is still logged.
- `pg_stat_statements` is preloaded — run `CREATE EXTENSION pg_stat_statements;` in each database to query it.
- **Backups**: run `./backup.sh` from cron and copy dumps off-host (see Backups).

## Backups

```bash
./backup.sh    # globals + every database -> ./backups/ (custom format, gzipped globals)
# cron: 15 3 * * *  cd /path/to/pgstack && ./backup.sh >> backups/backup.log 2>&1
```

Keeps `BACKUP_KEEP_DAYS` (default 14) days of dumps locally — copy them off-host
(rclone/rsync); a backup that lives only on this VPS is not a backup. Restore a
database **directly through the postgres container** (not through PgBouncer):

```bash
docker compose exec -T postgresql pg_restore -U postgres -C -d postgres backups/<db>-<stamp>.dump
```

### Disaster recovery (full cluster — tested end-to-end)

```bash
./backup.sh                                                  # fresh backup
docker compose down
docker run --rm -v "$PWD/data":/data alpine sh -c 'rm -rf /data/*'
docker compose up -d --wait                                  # fresh cluster; same ./password = same superuser
zcat backups/globals-<stamp>.sql.gz | docker compose exec -T postgresql psql -U postgres
# EXPECTED above: exactly one `ERROR: role "postgres" already exists` — the
# fresh initdb already created the superuser; every other role + password still
# applies. Do NOT add ON_ERROR_STOP (it aborts the whole globals restore).
# Any OTHER error: stop and inspect. Globals MUST run before the dumps — the
# dump's ALTER ... OWNER statements need their roles to exist.
for f in backups/*-<stamp>.dump; do                          # skip the postgres db dump if undesired
  docker compose exec -T postgresql pg_restore -U postgres -C -d postgres < "$f"
done
docker compose restart pgbouncer                             # clear cached auth state
./setup.sh <hostname>                                        # RE-APPLY hardening lost in the fresh cluster
```

Tested: roles come back with identical SCRAM verifiers, so apps reconnect with
their existing credentials (userlist/creds live on the host, not in data/).
Note the last step also rotates the admin password (expected `setup.sh`
behavior) — read it from `creds/pgbouncer_admin.pw`. The REVOKE CONNECT
hardening on `postgres`/`template1` is NOT part of the globals dump, which is
why the final `setup.sh` re-run is required.

## License

[Apache License 2.0](LICENSE).<br>
Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth).
