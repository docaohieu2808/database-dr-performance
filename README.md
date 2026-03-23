# Database, DR & Performance — Legacy Grouped Repository

Legacy grouped repository containing configurations for databases (MongoDB, PostgreSQL, Redis), disaster recovery (Velero), and performance/chaos testing (k6, Locust, Litmus). Standalone repos exist for MongoDB, k6, Locust, and Litmus.

## Repository Structure

```
database-dr-performance/
├── mongodb/            → see /home/hieudc/mongodb
├── postgresql/         (PostgreSQL HA configs)
├── redis/              (Redis Sentinel + Cluster)
├── disaster-recovery/  (Velero backup/restore)
├── performance-chaos/  → see /home/hieudc/k6-load-testing, /home/hieudc/locust, /home/hieudc/litmus-chaos
└── cloud-platforms/    (Cloud-specific DR strategies)
```

## Standalone Repos (preferred)

| Tool | Standalone Repo | Description |
|------|----------------|-------------|
| MongoDB | `/home/hieudc/mongodb` | Replica set + sharded cluster |
| k6 | `/home/hieudc/k6-load-testing` | Load testing |
| Locust | `/home/hieudc/locust` | Distributed load testing |
| Litmus | `/home/hieudc/litmus-chaos` | Chaos engineering |

## PostgreSQL Levels

| File | Level | Covers |
|------|-------|--------|
| `postgresql/l1-basic-docker-compose.yml` | L1 | Single PostgreSQL instance with auth + persistence |
| `postgresql/l2-replication-primary-replica.yml` | L2 | Streaming replication: primary + read replica |
| `postgresql/l3-patroni-ha-cluster.yml` | L3 | Patroni HA: automatic failover via etcd/Consul |
| `postgresql/l4-pgbouncer-connection-pool.conf` | L4 | PgBouncer connection pooling |
| `postgresql/l5-backup-wal-g.sh` | L5 | WAL-G continuous archiving to S3 |
| `postgresql/l-max-custom-extension-skeleton.sql` | L-MAX | Custom PostgreSQL extension skeleton |

## Redis Levels

| File | Level | Covers |
|------|-------|--------|
| `redis/l1-basic-docker-compose.yml` | L1 | Single Redis with auth, persistence (RDB+AOF) |
| `redis/l2-sentinel-ha.yml` | L2 | Redis Sentinel: 1 master + 2 replicas + 3 sentinels |
| `redis/l3-cluster-mode.yml` | L3 | Redis Cluster: 3 masters + 3 replicas, hash slots |
| `redis/l4-redis-acl-config.conf` | L4 | ACL: per-user command/key restrictions |

## Disaster Recovery (Velero) Levels

| File | Level | Covers |
|------|-------|--------|
| `disaster-recovery/l1-velero-install-helm-values.yaml` | L1 | Helm install: S3/GCS backend, plugin config |
| `disaster-recovery/l2-velero-schedule-backup.yaml` | L2 | Scheduled backups: namespace + PVC snapshots |
| `disaster-recovery/l3-velero-restore-procedure.sh` | L3 | Restore procedure: namespace, selective, cross-cluster |
| `disaster-recovery/l4-multi-region-strategy.yaml` | L4 | Multi-region DR: backup replication, RTO/RPO targets |
| `disaster-recovery/l-max-custom-backup-controller.go` | L-MAX | Custom backup controller: pre/post hooks, validation |

## Prerequisites

- Docker + Docker Compose (local)
- Kubernetes + `helm` 3.x (cluster deployments)
- `velero` CLI for DR operations
- S3-compatible storage (Velero backups)

## Quick Start

**PostgreSQL L1:**
```bash
docker compose -f postgresql/l1-basic-docker-compose.yml up -d
psql -h localhost -U postgres
```

**Redis Sentinel L2:**
```bash
docker compose -f redis/l2-sentinel-ha.yml up -d
redis-cli -h localhost -p 26379 sentinel master mymaster
```

**Velero install:**
```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  -f disaster-recovery/l1-velero-install-helm-values.yaml
velero backup-location get
```

**Velero backup + restore:**
```bash
# Create on-demand backup
velero backup create prod-backup --include-namespaces production

# Schedule daily backup
kubectl apply -f disaster-recovery/l2-velero-schedule-backup.yaml

# Restore
chmod +x disaster-recovery/l3-velero-restore-procedure.sh
./disaster-recovery/l3-velero-restore-procedure.sh prod-backup production
```

## Key Concepts

- **Patroni** — PostgreSQL HA via distributed consensus (etcd/Consul/ZooKeeper); automatic primary election and failover
- **WAL-G** — continuous WAL archiving to object storage; enables PITR (point-in-time recovery) with minimal data loss
- **PgBouncer** — connection pooler; `transaction` mode reduces server connections from hundreds to tens
- **Redis Sentinel** — monitors master health; promotes replica on failure; clients discover master via Sentinel API
- **Redis Cluster** — data sharded across 16384 hash slots; horizontal scaling; requires cluster-aware client
- **Velero** — K8s-native backup using object storage + volume snapshots; backup/restore both K8s resources and PVC data
- **RTO vs RPO** — RTO (Recovery Time Objective): how fast to recover; RPO (Recovery Point Objective): how much data loss is acceptable
