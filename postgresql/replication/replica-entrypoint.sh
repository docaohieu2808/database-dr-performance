#!/bin/sh
# replica-entrypoint.sh — custom entrypoint for postgres-replica container
# Performs pg_basebackup on first boot; subsequent boots just start postgres.
# Environment vars from docker-compose: PRIMARY_HOST, PRIMARY_PORT,
# REPLICATION_USER, REPLICATION_PASSWORD, PGDATA.
set -e

PRIMARY_HOST="${PRIMARY_HOST:-postgres-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-repl_secret}"
PGDATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "[replica-entrypoint] PGDATA is empty — performing base backup from ${PRIMARY_HOST}:${PRIMARY_PORT}"

  # Wait for primary to be reachable
  until pg_isready -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}"; do
    echo "[replica-entrypoint] Waiting for primary..."
    sleep 2
  done

  # Write .pgpass so pg_basebackup can authenticate without a password prompt
  PGPASSFILE="/tmp/.pgpass_replica"
  echo "${PRIMARY_HOST}:${PRIMARY_PORT}:replication:${REPLICATION_USER}:${REPLICATION_PASSWORD}" \
    > "${PGPASSFILE}"
  chmod 0600 "${PGPASSFILE}"
  export PGPASSFILE

  pg_basebackup \
    -h "${PRIMARY_HOST}" \
    -p "${PRIMARY_PORT}" \
    -U "${REPLICATION_USER}" \
    -D "${PGDATA}" \
    -Fp \
    -Xs \
    -P \
    -R   # writes recovery.conf / standby.signal + primary_conninfo automatically

  chmod 0700 "${PGDATA}"
  echo "[replica-entrypoint] Base backup complete."
else
  echo "[replica-entrypoint] PGDATA exists — skipping base backup."
fi

echo "[replica-entrypoint] Starting PostgreSQL in hot-standby mode."
exec postgres \
  -c hot_standby=on \
  -c max_standby_streaming_delay=30s \
  -c wal_receiver_status_interval=10s
