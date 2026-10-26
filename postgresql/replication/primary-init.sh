#!/bin/bash
# primary-init.sh — runs once inside postgres-primary via docker-entrypoint-initdb.d
# Creates the replication role and allows replication connections from any host.
# Environment vars come from docker-compose: POSTGRES_USER, POSTGRES_REPLICATION_USER,
# POSTGRES_REPLICATION_PASSWORD, PGDATA.
set -euo pipefail

echo "[primary-init] Creating replication role: ${POSTGRES_REPLICATION_USER:-replicator}"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-pguser}" --dbname "${POSTGRES_DB:-postgres}" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POSTGRES_REPLICATION_USER:-replicator}'
    ) THEN
      CREATE ROLE ${POSTGRES_REPLICATION_USER:-replicator}
        WITH REPLICATION LOGIN
        PASSWORD '${POSTGRES_REPLICATION_PASSWORD:-repl_secret}';
    END IF;
  END
  \$\$;
EOSQL

echo "[primary-init] Adding pg_hba replication entry"
# Allow replication from any address within the Docker network (172.x.x.x / 10.x.x.x)
echo "host replication ${POSTGRES_REPLICATION_USER:-replicator} 0.0.0.0/0 scram-sha-256" \
  >> "${PGDATA}/pg_hba.conf"

echo "[primary-init] Reloading PostgreSQL config"
pg_ctl reload -D "${PGDATA}"

echo "[primary-init] Done."
