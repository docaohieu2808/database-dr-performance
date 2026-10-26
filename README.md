# database-dr-performance

[![ci](https://github.com/docaohieu2808/database-dr-performance/actions/workflows/ci.yml/badge.svg)](https://github.com/docaohieu2808/database-dr-performance/actions/workflows/ci.yml)

A learning ladder for running databases like an SRE: single node, replication, automatic
failover, backups with point-in-time recovery, disaster recovery on Kubernetes, and load and
chaos testing. Every level that can run on a laptop is run by CI every week on a GitHub-hosted
runner, with an assertion that proves it works (a leader is killed and a replica takes over, a
table is dropped and brought back, ...).

Versions checked on 2026-10-26: PostgreSQL 18, Patroni 4.1.5, etcd 3.7.3, HAProxy 3.4, pgBackRest
(distro package, 2.5x/2.60), PgBouncer (Alpine package), MongoDB 9.0, Redis 8.10, Valkey 9.1,
Velero 1.18.4 (chart 12.2.1), Litmus 3.31, k6 2.3.0, Locust 2.47.0.

## Tier map

### PostgreSQL (`postgresql/`)

| Tier | Path | What it teaches | Proven in CI by |
|------|------|-----------------|-----------------|
| l1 | `l1-basic-docker-compose.yml` | Single node, tuned settings, init SQL | init SQL ran |
| l2 | `l2-replication-primary-replica.yml` | Streaming replication, hot standby | rows replicate, replica refuses writes |
| l3 | `l3-patroni-ha-cluster.yml` | Patroni 4 + etcd 3.7 + HAProxy, 3 nodes | **leader is killed, a replica is promoted, writes continue, old leader rejoins** |
| l4 | `l4-pgbouncer-pooler.yml` + `l4-pgbouncer-connection-pool.conf` | Transaction pooling in front of l2 | 100 pgbench clients multiplexed onto <= 35 server connections (pool 25 + reserve 10) |
| l5 | `l5-pitr-pgbackrest.yml` | Continuous WAL archiving + base backup + PITR with pgBackRest | **rows written, base backup, more rows, timestamp, `DROP TABLE`, restore to the timestamp: table and all rows back** |
| l5 alt | `l5-backup-wal-g.sh` | The same idea with WAL-G + S3 | shellcheck only (needs a bucket) |
| l-max | `l-max-custom-extension/` | A real C extension built with pgxs (functions, composite type, aggregate, DDL audit event trigger) | built and loaded in a PostgreSQL 18 image, every function asserted |

PostgreSQL 18 is the newest major (supported until 2030-11). 17 and 16 are still supported; 13
(used by the first version of this repo) is end of life.

WAL archiving in l3 and l5 uses **pgBackRest**. The old `archive_command: /bin/true` is gone: it
reported success while throwing every WAL segment away, which looks like PITR but is not. In l3 the
three Patroni nodes share one archive volume, so whichever node is primary keeps archiving;
the failover test runs `pgbackrest check` on the promoted node to prove it.

### Redis / Valkey (`redis/`)

| Tier | Path | What it teaches | Proven in CI by |
|------|------|-----------------|-----------------|
| l1 | `l1-basic-docker-compose.yml` + `redis.conf` | Password, RDB + AOF persistence | wrong password refused, key survives a restart |
| l2 | `l2-sentinel-ha.yml` | 1 primary + 2 replicas + 3 Sentinels | **primary stopped, Sentinel promotes a replica, data kept, old primary returns as replica** |
| l3 | `l3-cluster-mode.yml` | 6-node Redis Cluster (3 primaries + 3 replicas) | cluster forms, 60 keys across shards, **primary stopped, replica takes over, no data lost** |
| l4 | `l4-redis-acl-config.conf` | ACL file: per-user commands, keys and channels, hashed passwords | each user's allowed and denied commands asserted |

**Licence note.** Redis 8 is tri-licensed (RSALv2, SSPLv1 or AGPLv3); the Redis 7.2 used before
was BSD. **Valkey** is the Linux Foundation BSD fork. Every Redis compose file takes
`REDIS_IMAGE`, and CI runs all three tests against both:

```bash
REDIS_IMAGE=redis:8.10-alpine        docker compose -f redis/l2-sentinel-ha.yml up -d   # default
REDIS_IMAGE=valkey/valkey:9.1-alpine docker compose -f redis/l2-sentinel-ha.yml up -d
```

The ACL file has one `user` line per account and no comments or blank lines (Redis tolerates
comments, Valkey does not, and neither supports line continuation). Passwords are SHA-256 hashes;
the lab password of each user is `<username>-lab-password`.

| User | May do |
|------|--------|
| `default` | disabled: every client must log in as a named user |
| `admin` | everything |
| `appuser` | read/write data structures on keys `app:*`, no admin or dangerous commands |
| `readonly` | read-only on all keys |
| `cacheuser`, `sessionuser` | a handful of commands on `cache:*` / `session:*` only |
| `pubsubuser` | publish/subscribe on `notifications:*` and `alerts:*` channels, no keys |
| `monitoring`, `backupuser` | INFO/SLOWLOG/... and BGSAVE/CONFIG GET, no data access |

TLS is not covered (the README used to claim it): it is a `redis.conf` concern (`tls-port`,
`tls-cert-file`, ...), not an ACL one.

### MongoDB (`mongodb/`)

| Tier | Path | What it teaches | Proven in CI by |
|------|------|-----------------|-----------------|
| l1 | `l1-basic-docker-compose.yml` | Auth, init script, TTL index | anonymous access refused, init script ran |
| l2 | `l2-replica-set.yml` | 3-member replica set, keyFile auth | **primary stopped, new primary elected, majority-written data kept, old primary rejoins** |
| l3 | `l3-sharded-cluster.yml` | Config servers + 2 shards + 2 mongos, hashed shard key | 2000 inserts land on **both** shards |

The keyFile is generated automatically into a named volume by a one-shot `keyfile-init`
service; there is nothing to create by hand.

### Disaster recovery (`disaster-recovery/`)

| Tier | Path | What it teaches | Proven in CI by |
|------|------|-----------------|-----------------|
| l1 | `l1-velero-install-helm-values.yaml` | Velero 1.18.4 Helm values (AWS S3 + IRSA shaped) | installed on kind (with `ci/velero-kind-values.yaml` swapping AWS for an in-cluster S3) |
| l2 | `l2-velero-schedule-backup.yaml` | Schedules, secondary BackupStorageLocation | kubeconform with the Velero CRD schemas and a server-side dry run against the real CRDs |
| l3 | `l3-velero-restore-procedure.sh` | Restore runbook as a script: full, namespace, selective, "latest before time" | **namespace backed up, deleted, restored with this script; ConfigMap, Secret and Deployment asserted** |
| l4 | `l4-multi-region-strategy.yaml` | Multi-region DR reference (Route 53 failover, replication checks) | kubeconform only (needs AWS) |
| l-max | `l-max-restore-drill.sh` | Restore drill: restore the latest backup into a throw-away namespace, wait for Ready, compare object counts, measure RTO | runs at the end of the Velero test |

The previous l-max, a 486-line Go "backup controller", could not compile (no `go.mod`, no generated
deepcopy code, a placeholder fixed 24 h schedule instead of cron). It was replaced by the restore
drill, which is what a DR practice needs most: proof that a backup actually restores.

### Performance and chaos (`performance-chaos/`)

| Tier | Path | What it teaches | Proven in CI by |
|------|------|-----------------|-----------------|
| l1 | `l1-k6-load-test.js` | k6 basics: checks, thresholds, custom metrics | `k6 inspect` |
| l2 | `l2-k6-advanced-scenarios.js` | k6 scenarios (ramp, spike, soak, admin) | `k6 inspect` |
| l3 | `l3-locust-distributed.py` | Locust user classes, distributed mode | module imports, user classes found |
| l4 | `l4-litmus-chaos-experiment.yaml` | Litmus 3.31 pod-delete with HTTP and k8s probes | **kind cluster: experiment runs, verdict `Pass`, probes 100%, service back at full strength** |
| l-max | `l-max-custom-chaos-experiment.yaml` | Multi-fault ChaosEngine: network latency, CPU hog, disk fill | server-side dry run against the real Litmus CRDs, fault definitions installed |

The k6 and Locust scripts call a generic REST API (`/api/auth/login`, `/api/items`, ...) that this
repo does not ship, so CI checks that they parse and load, not that they hit a target. Point
`BASE_URL` / `--host` at your own service to run them. The old `ChaosSchedule` CRD (legacy scheduler,
not part of the Litmus 3 operator) and the dead hub URL were removed; schedule chaos with ChaosCenter
or a CronJob. Chaos Mesh 2.8.6 is the other maintained option; this repo only uses Litmus.

### Cloud platforms (`cloud-platforms/`)

Reference configs for the **compute** platforms that run an application in front of these
databases: EKS (eksctl), Lambda (SAM), ECS task definition, GKE, Cloud Run, Cloud Functions, AKS, App
Service and Azure Functions. They contain **no managed database** resources (no RDS, Aurora,
CloudSQL or Azure Database); an earlier README claimed they did. Checked in CI: `cfn-lint` on the SAM
template, JSON parse, kubeconform on the Cloud Run (Knative) service, yamllint on the rest.
The GKE, AKS and App Service files are illustrative configuration, not tool-validated.
Runtimes were moved to Node.js 24 (Node 20 is end of life) and Kubernetes to EKS 1.37 / AKS 1.36.

## Running a level locally

Needs Docker with Compose v2.20+ (the l4 PgBouncer file uses `include`).

```bash
# PostgreSQL
docker compose -f postgresql/l1-basic-docker-compose.yml up -d
docker compose -f postgresql/l2-replication-primary-replica.yml up -d
docker compose -f postgresql/l3-patroni-ha-cluster.yml up -d --build
docker exec patroni1 patronictl -c /etc/patroni/patroni.yml list
docker compose -f postgresql/l4-pgbouncer-pooler.yml up -d --build     # psql -p 6432 appdb
docker compose -f postgresql/l5-pitr-pgbackrest.yml up -d --build      # then see tests/pitr-pgbackrest.sh

# Redis / MongoDB
docker compose -f redis/l2-sentinel-ha.yml up -d
docker compose -f mongodb/l2-replica-set.yml up -d
```

Each test script brings its level up, asserts, and tears it down (`down -v`), so they double as
walk-throughs; read them next to the compose files:

| Script | Level |
|--------|-------|
| `tests/postgres-replication-pooler.sh` | PostgreSQL l1, l2, l4 |
| `tests/patroni-failover.sh` | PostgreSQL l3 |
| `tests/pitr-pgbackrest.sh` | PostgreSQL l5 |
| `tests/pg-extension.sh` | PostgreSQL l-max |
| `tests/redis-basic-and-acl.sh`, `redis-sentinel-failover.sh`, `redis-cluster-smoke.sh` | Redis l1-l4 |
| `tests/mongo-basic.sh`, `mongo-replica-election.sh`, `mongo-sharded-smoke.sh` | MongoDB l1-l3 |
| `tests/velero-backup-restore.sh` | DR l1-l3, l-max (needs a kind cluster, helm, velero CLI) |
| `tests/litmus-pod-delete.sh` | Chaos l4, l-max (needs a kind cluster, helm, yq) |

The lab passwords in the compose files (`superpassword`, `adminpassword`, ...) are placeholders for
a throw-away lab network; every port is bound to `127.0.0.1`. Override them through `.env`.

## What CI checks

`.github/workflows/ci.yml` runs on every push and pull request, manually, and every Monday at
02:41 UTC (09:41 Asia/Saigon). Jobs and their time limits:

| Job | Checks |
|-----|--------|
| `static` (20 min) | actionlint, shellcheck, yamllint --strict, `docker compose config` on every compose file, hadolint on every Dockerfile, `haproxy -c`, JSON parse, cfn-lint, kubeconform (-strict, Velero and Knative CRD schemas), `k6 inspect`, Locust import, every action pinned to an existing commit SHA |
| `postgres-replication` | l1, l2, l4 |
| `patroni-failover` | `patroni --validate-config`, then the l3 failover test |
| `postgres-pitr` | l5 point-in-time recovery |
| `postgres-extension` | l-max build and test |
| `redis` (matrix: Redis 8.10 and Valkey 9.1 x 3 tests) | l1-l4 |
| `mongodb` (matrix: 3 tests) | l1-l3 |
| `velero` | kind + Velero backup / delete / restore / drill |
| `litmus` | kind + Litmus pod-delete chaos |

Dependabot keeps the actions, Docker images, compose images and pip pins current.

## Honest limits

- Single-host Docker: failover and election are real, network partitions and disk failures are not.
- The "kill" in the tests is `docker stop -t 0` (an immediate SIGKILL), not a pulled network cable.
- Patroni runs with a single-node etcd, which is a single point of failure by design here; production
  uses three etcd members.
- MinIO no longer publishes images, so the Velero test uses SeaweedFS as its S3 endpoint.
- k6/Locust scripts need your own API; cloud files need real accounts (see above).
- l5 alt (WAL-G) and `l4-multi-region-strategy.yaml` need AWS and are only linted.

## Interview talking points

- **Streaming replication vs Patroni**: l2 needs an operator to promote; l3 elects a leader through
  etcd and repoints HAProxy within about 30 s (`ttl: 30`). Know `maximum_lag_on_failover`,
  `synchronous_mode` (zero RPO, slower writes) and why the old primary needs `pg_rewind`.
- **PITR**: a base backup is only a starting point; the archived WAL after it is what lets you
  stop at 14:29:59. `archive_command` that always succeeds is worse than none.
- **PgBouncer transaction mode**: thousands of clients on tens of server connections, but session
  state (`SET`, advisory locks, `LISTEN`) does not survive; `max_prepared_statements > 0` keeps
  prepared-statement drivers working.
- **Redis**: Sentinel (HA, one dataset) vs Cluster (sharding); async replication means `WAIT`
  is needed for acknowledged writes to survive a failover; the Redis 8 licence change and Valkey.
- **MongoDB**: elections need a majority, `w: majority` is what makes a write survive one;
  a hashed shard key spreads inserts, a ranged one can hot-spot.
- **Velero**: backups are only real after a restore drill; know what it does not cover (volumes
  need CSI snapshots or the node agent).
- **Chaos + load together**: run the Litmus pod-delete while k6 hits the service; the probes turn
  "it survived" into a pass/fail verdict.

## License

MIT, see [LICENSE](LICENSE).
