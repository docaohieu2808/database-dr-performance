# database-dr-performance

Database configs, HA, disaster recovery, and performance testing for PostgreSQL, Redis, and MongoDB. Includes k6/Locust load testing, Litmus chaos engineering, Velero DR, and cloud-managed DB references (AWS RDS, GCP CloudSQL, Azure Database).

## Tier map

### PostgreSQL
| Tier | Path | What it covers |
|------|------|----------------|
| l1 | `postgresql/l1-basic-docker-compose.yml` | Single-node Postgres with pgAdmin |
| l2 | `postgresql/l2-replication-primary-replica.yml` | Streaming replication: 1 primary + 1 hot-standby replica |
| l3 | `postgresql/l3-patroni-ha-cluster.yml` | Patroni 3-node HA cluster with etcd DCS + HAProxy routing |
| l4 | `postgresql/l4-pgbouncer-connection-pool.conf` | PgBouncer connection pooling (transaction mode) |
| l5 | `postgresql/l5-backup-wal-g.sh` | WAL-G continuous WAL archiving + PITR restore |
| l-max | `postgresql/l-max-custom-extension-skeleton.sql` | PostgreSQL extension skeleton (C + SQL) |

Supporting files for l2: `postgresql/replication/primary-init.sh`, `replication/replica-entrypoint.sh`
Supporting files for l3: `postgresql/patroni/Dockerfile`, `patroni/patroni.yml`, `patroni/haproxy.cfg`

> **Note:** Patroni kept as learning material. Production fleet uses docker pg17-alpine standalone.

### Redis
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l-max | `redis/` | Standalone → Sentinel HA → Cluster mode → ACL/TLS |

### MongoDB
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l-max | `mongodb/` | Standalone → Replica set → Sharded cluster |

### Disaster Recovery
| Tier | Path | What it covers |
|------|------|----------------|
| l1 | `disaster-recovery/l1-velero*/` | Velero backup/restore for k8s PVs |
| l-max | `disaster-recovery/` | Go backup controller (486 LOC) — custom CRD-driven backup orchestration |

### Performance & Chaos
| Tier | Path | What it covers |
|------|------|----------------|
| l1 | `performance-chaos/l1*/` | k6 load test scripts |
| l2 | `performance-chaos/l2*/` | Locust Python load test |
| l3 | `performance-chaos/l3*/` | Litmus ChaosEngine experiments (pod kill, network delay) |

### Cloud Platforms
| Path | What it covers |
|------|----------------|
| `cloud-platforms/aws/` | RDS + Aurora + ElastiCache patterns |
| `cloud-platforms/gcp/` | CloudSQL + Memorystore |
| `cloud-platforms/azure/` | Azure Database for PostgreSQL + Redis Cache |

## Run

```bash
# l1 — basic single node
docker compose -f postgresql/l1-basic-docker-compose.yml up -d

# l2 — streaming replication (scripts now exist in replication/)
docker compose -f postgresql/l2-replication-primary-replica.yml up -d

# l3 — Patroni HA (builds custom image first)
docker compose -f postgresql/l3-patroni-ha-cluster.yml up -d --build
# Check cluster: docker exec patroni1 patronictl -c /etc/patroni/patroni.yml list
```

## Interview talking points

- **Streaming replication vs Patroni**: manual replication (`l2`) requires operator-driven failover; Patroni (`l3`) automates leader election via etcd DCS — no manual intervention on primary failure.
- **WAL-G PITR**: `l5` shows continuous WAL shipping to S3 + point-in-time restore to any LSN — RPO near-zero, RTO minutes.
- **PgBouncer transaction mode**: allows 1000s of app connections multiplexed to ~100 Postgres connections — critical for connection-hungry frameworks (Rails, Django).
- **Velero**: backs up PersistentVolumeClaims as volume snapshots; custom Go controller (`l-max`) extends this with CRD-driven scheduling and cross-region copy.
- **Chaos + load test together**: run Litmus pod-kill while k6 is hitting the DB — proves SLO holds under failure (good story for reliability interviews).

## Notes

- `replication/primary-init.sh` and `replication/replica-entrypoint.sh` were created to make `l2` compose runnable (previously only existed as inline comments).
- `patroni/Dockerfile`, `patroni/patroni.yml`, `patroni/haproxy.cfg` created to make `l3` compose buildable.
- All passwords use `${VAR:-default}` pattern; create `.env` before running in any non-local environment.
