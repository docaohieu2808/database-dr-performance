#!/usr/bin/env bash
# WAL-G continuous backup to S3 (or S3-compatible storage).
# Alternative to the pgBackRest lab in l5-pitr-pgbackrest.yml; needs a real bucket,
# so it is shellchecked in CI but not executed there.
# Supports: base backups, WAL archiving, PITR restore
# Requires: wal-g binary, AWS credentials, PostgreSQL >= 12

set -euo pipefail

###############################################################################
# Configuration — override via environment variables
###############################################################################
export WALG_S3_PREFIX="${WALG_S3_PREFIX:-s3://my-pg-backups/walg}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
# Credentials are checked in require_credentials (so `help` and `wal-archive` stay usable)
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
# For S3-compatible (MinIO, Ceph, etc.)
# export AWS_ENDPOINT="${AWS_ENDPOINT:-http://minio:9000}"
# export WALG_S3_CA_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Compression (lz4 is fastest; brotli gives best ratio)
export WALG_COMPRESSION_METHOD="${WALG_COMPRESSION_METHOD:-lz4}"

# Upload concurrency and disk limits
export WALG_UPLOAD_CONCURRENCY="${WALG_UPLOAD_CONCURRENCY:-16}"
export WALG_DOWNLOAD_CONCURRENCY="${WALG_DOWNLOAD_CONCURRENCY:-10}"
export WALG_UPLOAD_DISK_CONCURRENCY="${WALG_UPLOAD_DISK_CONCURRENCY:-2}"

# Delta backup: only changed pages since last full backup
export WALG_DELTA_MAX_STEPS="${WALG_DELTA_MAX_STEPS:-7}"
export WALG_DELTA_ORIGIN="${WALG_DELTA_ORIGIN:-LATEST}"

# Retention: keep last N full backups (a variable of THIS script, not a wal-g setting)
 WALG_RETAIN_FULL_BACKUP_COUNT="${WALG_RETAIN_FULL_BACKUP_COUNT:-7}"

# PostgreSQL connection
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-}"   # only psql needs it; wal-push does not
export PGDATABASE="${PGDATABASE:-postgres}"
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"

WALG_BIN="${WALG_BIN:-/usr/local/bin/wal-g}"
# Default log in /tmp: the postgres user running archive_command cannot write /var/log
LOG_FILE="${LOG_FILE:-${TMPDIR:-/tmp}/walg-backup.log}"

###############################################################################
# Logging
###############################################################################
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

require_credentials() {
    [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
        || die "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required"
}

###############################################################################
# Preflight checks
###############################################################################
check_prerequisites() {
    log "Checking prerequisites..."
    require_credentials
    [[ -n "$PGPASSWORD" ]] || die "PGPASSWORD is required"
    [[ -x "$WALG_BIN" ]] || die "wal-g not found at $WALG_BIN"
    command -v psql >/dev/null 2>&1 || die "psql not found"
    psql -c "SELECT 1" >/dev/null 2>&1 || die "Cannot connect to PostgreSQL"
    log "Prerequisites OK"
}

###############################################################################
# Full base backup
###############################################################################
run_base_backup() {
    log "Starting WAL-G full base backup..."
    "$WALG_BIN" backup-push "$PGDATA" \
        --full \
        --verify 2>&1 | tee -a "$LOG_FILE"
    log "Base backup completed successfully"
}

###############################################################################
# Delta backup (incremental since last full)
###############################################################################
run_delta_backup() {
    log "Starting WAL-G delta backup..."
    "$WALG_BIN" backup-push "$PGDATA" 2>&1 | tee -a "$LOG_FILE"
    log "Delta backup completed successfully"
}

###############################################################################
# WAL archiving (called by PostgreSQL archive_command)
# Usage: ./l5-backup-wal-g.sh wal-archive %p %f
###############################################################################
run_wal_archive() {
    local wal_path="${1:?WAL path required}"
    local wal_file="${2:?WAL filename required}"
    require_credentials
    log "Archiving WAL segment: $wal_file"
    "$WALG_BIN" wal-push "$wal_path" 2>&1 | tee -a "$LOG_FILE"
    log "WAL archived: $wal_file"
}

###############################################################################
# List available backups
###############################################################################
list_backups() {
    log "Available backups:"
    "$WALG_BIN" backup-list --pretty --detail 2>&1 | tee -a "$LOG_FILE"
}

###############################################################################
# Restore from backup
# Usage: ./l5-backup-wal-g.sh restore [backup-name] [target-time]
# backup-name: LATEST or specific backup name from backup-list
# target-time: RFC3339 timestamp for PITR, e.g. "2024-01-15T14:30:00Z"
###############################################################################
run_restore() {
    local backup_name="${1:-LATEST}"
    local target_time="${2:-}"

    require_credentials
    log "Starting restore from backup: $backup_name"
    [[ -d "$PGDATA" && "$(ls -A "$PGDATA")" ]] && \
        die "PGDATA $PGDATA is not empty. Stop PostgreSQL and clear it first."

    # Fetch base backup
    "$WALG_BIN" backup-fetch "$PGDATA" "$backup_name" 2>&1 | tee -a "$LOG_FILE"

    # Write recovery config (PostgreSQL 12+ uses postgresql.auto.conf)
    cat > "$PGDATA/postgresql.auto.conf" <<EOF
restore_command = '$WALG_BIN wal-fetch %f %p'
recovery_target_action = promote
EOF

    if [[ -n "$target_time" ]]; then
        log "Setting PITR target: $target_time"
        echo "recovery_target_time = '$target_time'" >> "$PGDATA/postgresql.auto.conf"
        echo "recovery_target_inclusive = true" >> "$PGDATA/postgresql.auto.conf"
    fi

    # Signal PostgreSQL to enter recovery mode
    touch "$PGDATA/recovery.signal"

    log "Restore prepared. Start PostgreSQL to begin recovery."
    log "Monitor with: tail -f /var/log/postgresql/postgresql.log"
}

###############################################################################
# Delete old backups (retain N full backups)
###############################################################################
run_delete_old() {
    log "Deleting old backups, retaining $WALG_RETAIN_FULL_BACKUP_COUNT full backups..."
    "$WALG_BIN" delete retain FULL "$WALG_RETAIN_FULL_BACKUP_COUNT" \
        --confirm 2>&1 | tee -a "$LOG_FILE"
    log "Cleanup complete"
}

###############################################################################
# Configure PostgreSQL for WAL archiving
# Run once to update postgresql.conf
###############################################################################
configure_postgres_wal_archiving() {
    log "Configuring PostgreSQL WAL archiving..."
    SCRIPT_PATH="$(realpath "$0")"
    psql <<EOF
ALTER SYSTEM SET wal_level = replica;
ALTER SYSTEM SET archive_mode = on;
ALTER SYSTEM SET archive_command = '$SCRIPT_PATH wal-archive %p %f';
ALTER SYSTEM SET archive_timeout = 300;
ALTER SYSTEM SET max_wal_senders = 5;
ALTER SYSTEM SET wal_keep_size = '1GB';
SELECT pg_reload_conf();
EOF
    log "PostgreSQL configured for WAL archiving. Restart required for wal_level/archive_mode."
}

###############################################################################
# Scheduled backup cron setup (prints crontab entries)
###############################################################################
print_cron_schedule() {
    SCRIPT_PATH="$(realpath "$0")"
    cat <<EOF
# WAL-G backup schedule — add to /etc/cron.d/walg-backup
# Full backup: Sunday 02:00 UTC
0 2 * * 0 postgres $SCRIPT_PATH base-backup >> $LOG_FILE 2>&1
# Delta backup: Mon-Sat 02:00 UTC
0 2 * * 1-6 postgres $SCRIPT_PATH delta-backup >> $LOG_FILE 2>&1
# Cleanup old backups: Sunday 03:00 UTC (after full backup)
0 3 * * 0 postgres $SCRIPT_PATH delete-old >> $LOG_FILE 2>&1
EOF
}

###############################################################################
# Main entrypoint
###############################################################################
usage() {
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  check                    Verify prerequisites
  base-backup              Run full base backup
  delta-backup             Run incremental delta backup
  wal-archive <path> <f>   Archive a WAL segment (called by archive_command)
  list                     List available backups
  restore [name] [time]    Restore backup (PITR optional)
  delete-old               Delete old backups per retention policy
  configure-pg             Configure PostgreSQL WAL archiving
  cron-schedule            Print recommended crontab entries

Environment variables:
  WALG_S3_PREFIX           S3 path prefix (required)
  AWS_ACCESS_KEY_ID        AWS access key (required)
  AWS_SECRET_ACCESS_KEY    AWS secret key (required)
  AWS_REGION               AWS region (default: us-east-1)
  PGDATA                   PostgreSQL data directory
  PGHOST/PGPORT/PGUSER     PostgreSQL connection settings
  PGPASSWORD               PostgreSQL password (required)
EOF
}

CMD="${1:-help}"
shift || true

case "$CMD" in
    check)            check_prerequisites ;;
    base-backup)      check_prerequisites; run_base_backup ;;
    delta-backup)     check_prerequisites; run_delta_backup ;;
    wal-archive)      run_wal_archive "$@" ;;
    list)             require_credentials; list_backups ;;
    restore)          run_restore "$@" ;;
    delete-old)       require_credentials; run_delete_old ;;
    configure-pg)     configure_postgres_wal_archiving ;;
    cron-schedule)    print_cron_schedule ;;
    help|--help|-h)   usage ;;
    *)                err "Unknown command: $CMD"; usage; exit 1 ;;
esac
