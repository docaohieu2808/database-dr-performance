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

# Passwordless-in-conninfo: both pg_basebackup and the running walreceiver read the
# replication password from this file (so it must exist on every start).
PGPASSFILE="/tmp/.pgpass_replica"
echo "${PRIMARY_HOST}:${PRIMARY_PORT}:replication:${REPLICATION_USER}:${REPLICATION_PASSWORD}" \
  > "${PGPASSFILE}"
chmod 0600 "${PGPASSFILE}"
export PGPASSFILE

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "[replica-entrypoint] PGDATA is empty — performing base backup from ${PRIMARY_HOST}:${PRIMARY_PORT}"

  # Wait for primary to be reachable
  until pg_isready -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}"; do
    echo "[replica-entrypoint] Waiting for primary..."
    sleep 2
  done

  pg_basebackup \
    -h "${PRIMARY_HOST}" \
    -p "${PRIMARY_PORT}" \
    -U "${REPLICATION_USER}" \
    -D "${PGDATA}" \
    -Fp \
    -Xs \
    -P \
    -R   # writes standby.signal + primary_conninfo (no password) automatically

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
