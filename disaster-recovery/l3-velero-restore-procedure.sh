#!/usr/bin/env bash
# Velero restore procedure — full cluster, namespace, or selective restore
# Covers: pre-flight checks, restore execution, validation, rollback
# Usage: ./l3-velero-restore-procedure.sh [command] [options]

set -euo pipefail

###############################################################################
# Configuration
###############################################################################
VELERO_NS="${VELERO_NS:-velero}"
VELERO="${VELERO_BIN:-velero}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-1800}"   # seconds to wait for completion
LOG_FILE="${LOG_FILE:-/tmp/velero-restore-$(date +%Y%m%d-%H%M%S).log}"

###############################################################################
# Logging
###############################################################################
log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"; }
err()  { log "ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }
warn() { log "WARN: $*"; }

###############################################################################
# Preflight checks
###############################################################################
preflight_checks() {
    log "Running preflight checks..."
    command -v "$VELERO" >/dev/null 2>&1  || die "velero CLI not found"
    command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found"
    "$KUBECTL" cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"
    "$KUBECTL" get namespace "$VELERO_NS" >/dev/null 2>&1 || die "Velero namespace '$VELERO_NS' not found"
    "$VELERO" version --client-only >/dev/null 2>&1 || die "Velero CLI error"
    log "Preflight checks passed"
}

###############################################################################
# List available backups
###############################################################################
list_backups() {
    log "Available backups:"
    "$VELERO" backup get --namespace "$VELERO_NS" 2>&1 | tee -a "$LOG_FILE"
}

###############################################################################
# Describe a specific backup
###############################################################################
describe_backup() {
    local backup_name="${1:?Backup name required}"
    log "Describing backup: $backup_name"
    "$VELERO" backup describe "$backup_name" \
        --namespace "$VELERO_NS" \
        --details 2>&1 | tee -a "$LOG_FILE"
}

###############################################################################
# Full cluster restore
###############################################################################
restore_full_cluster() {
    local backup_name="${1:?Backup name required}"
    local restore_name="restore-full-$(date +%Y%m%d-%H%M%S)"

    log "Starting full cluster restore from backup: $backup_name"
    warn "This will restore ALL namespaces. Existing resources may be overwritten."
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || die "Restore cancelled"

    "$VELERO" restore create "$restore_name" \
        --from-backup "$backup_name" \
        --namespace "$VELERO_NS" \
        --include-cluster-resources=true \
        --wait=false 2>&1 | tee -a "$LOG_FILE"

    wait_for_restore "$restore_name"
    validate_restore "$restore_name"
}

###############################################################################
# Namespace-scoped restore
###############################################################################
restore_namespace() {
    local backup_name="${1:?Backup name required}"
    local target_ns="${2:?Target namespace required}"
    local restore_name="restore-ns-${target_ns}-$(date +%Y%m%d-%H%M%S)"
    local into_ns="${3:-$target_ns}"   # optionally restore into different namespace

    log "Restoring namespace '$target_ns' from backup: $backup_name"
    [[ "$into_ns" != "$target_ns" ]] && log "Mapping into namespace: $into_ns"

    # Scale down deployments to avoid conflicts during restore
    log "Scaling down existing deployments in $into_ns..."
    "$KUBECTL" scale deployment --all --replicas=0 -n "$into_ns" 2>/dev/null || true

    local ns_map_flag=""
    [[ "$into_ns" != "$target_ns" ]] && ns_map_flag="--namespace-mappings ${target_ns}:${into_ns}"

    # shellcheck disable=SC2086
    "$VELERO" restore create "$restore_name" \
        --from-backup "$backup_name" \
        --namespace "$VELERO_NS" \
        --include-namespaces "$target_ns" \
        --include-cluster-resources=false \
        --existing-resource-policy=update \
        $ns_map_flag \
        --wait=false 2>&1 | tee -a "$LOG_FILE"

    wait_for_restore "$restore_name"
    validate_restore "$restore_name"

    log "Scaling deployments back up in $into_ns..."
    "$KUBECTL" scale deployment --all --replicas=1 -n "$into_ns" 2>/dev/null || true
}

###############################################################################
# Selective resource restore (by label or resource type)
###############################################################################
restore_selective() {
    local backup_name="${1:?Backup name required}"
    local namespace="${2:?Namespace required}"
    local resource_types="${3:-deployments,services,configmaps,secrets,persistentvolumeclaims}"
    local label_selector="${4:-}"
    local restore_name="restore-selective-$(date +%Y%m%d-%H%M%S)"

    log "Selective restore: backup=$backup_name ns=$namespace resources=$resource_types"

    local label_flag=""
    [[ -n "$label_selector" ]] && label_flag="--selector $label_selector"

    # shellcheck disable=SC2086
    "$VELERO" restore create "$restore_name" \
        --from-backup "$backup_name" \
        --namespace "$VELERO_NS" \
        --include-namespaces "$namespace" \
        --include-resources "$resource_types" \
        --existing-resource-policy=update \
        $label_flag \
        --wait=false 2>&1 | tee -a "$LOG_FILE"

    wait_for_restore "$restore_name"
    validate_restore "$restore_name"
}

###############################################################################
# PITR: restore from latest backup before a given timestamp
###############################################################################
restore_pitr() {
    local namespace="${1:?Namespace required}"
    local before_time="${2:?Timestamp required (RFC3339, e.g. 2024-01-15T14:30:00Z)}"
    local restore_name="restore-pitr-$(date +%Y%m%d-%H%M%S)"

    log "Finding latest backup before: $before_time"

    # Find most recent backup completed before the target time
    local backup_name
    backup_name=$(
        "$VELERO" backup get --namespace "$VELERO_NS" -o json |
        python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
target = datetime.datetime.fromisoformat('${before_time}'.replace('Z','+00:00'))
candidates = []
for b in data.get('items', []):
    ct = b.get('status', {}).get('completionTimestamp', '')
    if ct:
        t = datetime.datetime.fromisoformat(ct.replace('Z','+00:00'))
        if t < target and b['status'].get('phase') == 'Completed':
            candidates.append((t, b['metadata']['name']))
candidates.sort(reverse=True)
print(candidates[0][1] if candidates else '')
"
    )

    [[ -n "$backup_name" ]] || die "No completed backup found before $before_time"
    log "Selected backup: $backup_name"

    "$VELERO" restore create "$restore_name" \
        --from-backup "$backup_name" \
        --namespace "$VELERO_NS" \
        --include-namespaces "$namespace" \
        --existing-resource-policy=update \
        --wait=false 2>&1 | tee -a "$LOG_FILE"

    wait_for_restore "$restore_name"
    validate_restore "$restore_name"
}

###############################################################################
# Wait for restore completion
###############################################################################
wait_for_restore() {
    local restore_name="${1:?Restore name required}"
    local elapsed=0
    local interval=10

    log "Waiting for restore '$restore_name' to complete (timeout: ${RESTORE_TIMEOUT}s)..."

    while true; do
        local phase
        phase=$("$VELERO" restore get "$restore_name" \
            --namespace "$VELERO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        case "$phase" in
            Completed)
                log "Restore completed successfully"
                return 0
                ;;
            PartiallyFailed)
                warn "Restore completed with partial failures"
                return 1
                ;;
            Failed)
                err "Restore failed"
                "$VELERO" restore describe "$restore_name" --namespace "$VELERO_NS" | tee -a "$LOG_FILE"
                return 1
                ;;
        esac

        if (( elapsed >= RESTORE_TIMEOUT )); then
            die "Restore timed out after ${RESTORE_TIMEOUT}s"
        fi

        log "Status: $phase — waiting ${interval}s... (${elapsed}/${RESTORE_TIMEOUT}s)"
        sleep "$interval"
        (( elapsed += interval ))
    done
}

###############################################################################
# Validate restore
###############################################################################
validate_restore() {
    local restore_name="${1:?Restore name required}"

    log "Validating restore: $restore_name"
    "$VELERO" restore describe "$restore_name" \
        --namespace "$VELERO_NS" \
        --details 2>&1 | tee -a "$LOG_FILE"

    local warnings errors
    warnings=$("$VELERO" restore describe "$restore_name" \
        --namespace "$VELERO_NS" -o json 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',{}).get('warnings',0))")
    errors=$("$VELERO" restore describe "$restore_name" \
        --namespace "$VELERO_NS" -o json 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',{}).get('errors',0))")

    log "Restore summary — warnings: $warnings, errors: $errors"
    [[ "$errors" -gt 0 ]] && warn "Restore completed with $errors errors — review logs"
    log "Restore log: $LOG_FILE"
}

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
Velero Restore Procedure

Usage: $0 <command> [args...]

Commands:
  preflight                           Run preflight checks
  list                                List available backups
  describe <backup-name>              Show backup details
  full <backup-name>                  Restore full cluster
  namespace <backup> <ns> [into-ns]  Restore single namespace
  selective <backup> <ns> [resources] [label-selector]
                                      Restore specific resource types
  pitr <namespace> <timestamp>        Restore to point-in-time (RFC3339)

Examples:
  $0 list
  $0 full full-cluster-daily-backup-20240115020000
  $0 namespace full-cluster-daily-backup-20240115020000 production
  $0 namespace full-cluster-daily-backup-20240115020000 production production-restored
  $0 selective full-cluster-daily-backup-20240115020000 production deployments,services app=myapp
  $0 pitr production 2024-01-15T14:30:00Z

Environment:
  VELERO_NS       Velero namespace (default: velero)
  VELERO_BIN      Path to velero binary (default: velero)
  KUBECTL_BIN     Path to kubectl binary (default: kubectl)
  RESTORE_TIMEOUT Timeout in seconds (default: 1800)
  LOG_FILE        Log output path (default: /tmp/velero-restore-<timestamp>.log)
EOF
}

###############################################################################
# Main
###############################################################################
CMD="${1:-help}"
shift || true

preflight_checks

case "$CMD" in
    preflight)  : ;;   # already ran above
    list)       list_backups ;;
    describe)   describe_backup "$@" ;;
    full)       restore_full_cluster "$@" ;;
    namespace)  restore_namespace "$@" ;;
    selective)  restore_selective "$@" ;;
    pitr)       restore_pitr "$@" ;;
    help|--help|-h) usage ;;
    *) err "Unknown command: $CMD"; usage; exit 1 ;;
esac
