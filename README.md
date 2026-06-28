# PostgreSQL Performance Stack

A production-ready PostgreSQL + PgBouncer stack. Configuration is **generated from templates** by `tunner.sh` to match the host hardware — it is never hand-tuned to one machine.

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Applications  │───→│    PgBouncer    │───→│   PostgreSQL    │
│                 │    │ Connection Pool │    │   Databases     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
       :6432 (TLS)              internal only
```

## Quick start

```bash
# 1. Set the real postgres password (ships with `changeme`):
#    ./password = the password ;  ./userlist.txt = "postgres" "<that password>"
./sslgen.sh pgsql01.hieupth.com   # 2. TLS certs -> ./ssl/  (app trusts ./ssl/ca.pem)
./tunner.sh                       # 3. config tuned to this host's CPU/RAM/disk
docker compose up -d              # 4. start
```

`postgresql.conf`, `pgbouncer.ini`, and `ssl/` are generated and gitignored.

## Tuning (`tunner.sh`)

Detects CPU cores, RAM, and disk type, then writes both config files from templates:

- **PostgreSQL** — full PGTune-style hardware tuning: `shared_buffers` ≈ 25% RAM, `effective_cache_size` ≈ 75%, `work_mem` scaled to RAM/connections, worker/parallel settings scaled to cores, SSD/HDD I/O params.
- **PgBouncer** — `default_pool_size`/`pool_size` scaled to cores and `max_db_connections` tied to `max_connections`; the rest stays workload-driven (tune under load — see below).

It then verifies the generated `postgresql.conf` boots in a throwaway postgres container.

```bash
./tunner.sh                                  # auto-detect
./tunner.sh --ram 3840 --cpu 3 --disk ssd    # explicit overrides
./tunner.sh --no-verify                      # skip the docker boot check
```

### PgBouncer under load (measure, don't guess)

These are safe starting points, not optimal values. After running under real load, inspect the admin console:

```bash
psql -h localhost -p 6432 -U postgres pgbouncer   # then:
SHOW POOLS;      # cl_waiting > 0 => clients wait => raise default_pool_size/reserve_pool_size
SHOW STATS;      # avg_query_time, total_query_count per db
```

If `cl_waiting` grows, raise the pool; if `sv_active` stays well above 2-3x cores, the box itself is the bottleneck (add hardware, don't raise the pool). Re-run `./tunner.sh` only after a hardware change.

## Security checklist

- **Replace placeholders** `changeme` in `./password` and `./userlist.txt` (kept as placeholders in this repo on purpose).
- **Port 6432** is published on all host interfaces. Bind it tighter (`127.0.0.1:6432:5432` in `compose.yml`) or firewall it if apps don't connect from outside the host.
- `pg_hba.conf` uses `scram-sha-256`.
- TLS is enforced app→PgBouncer (`client_tls_sslmode = require`); PgBouncer→PostgreSQL TLS is optional (see `pgbouncer.ini.template`).
- `pg_stat_statements` is preloaded — run `CREATE EXTENSION pg_stat_statements;` in each database to query it.

## License

[Apache License 2.0](LICENSE).<br>
Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth). All rights reserved.
