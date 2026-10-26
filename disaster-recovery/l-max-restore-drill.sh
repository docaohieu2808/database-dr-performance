#!/usr/bin/env bash
# Restore drill: prove a backup is restorable by restoring it into a throw-away
# namespace, waiting for the workloads to become Ready, comparing object counts with
# the live namespace, measuring the recovery time and cleaning up.
# An untested backup is not a backup: run this on a schedule (cron / CI).
#
# Usage: ./l-max-restore-drill.sh <namespace> [backup-name]
#   backup-name defaults to the newest Completed backup that includes <namespace>.
# Env:   VELERO_NS (velero)  VELERO_BIN (velero)  KUBECTL_BIN (kubectl)
#        MAX_RTO_SECONDS (600)  KEEP_DRILL_NS=1 to skip the cleanup
set -euo pipefail

VELERO_NS="${VELERO_NS:-velero}"
VELERO="${VELERO_BIN:-velero}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
MAX_RTO_SECONDS="${MAX_RTO_SECONDS:-600}"

NS="${1:?Usage: $0 <namespace> [backup-name]}"
BACKUP="${2:-}"
DRILL_NS="${NS}-drill-$(date +%s)"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { log "DRILL FAILED: $*" >&2; exit 1; }

cleanup() {
    if [[ "${KEEP_DRILL_NS:-}" != "1" ]]; then
        "$KUBECTL" delete namespace "$DRILL_NS" --ignore-not-found --wait=false >/dev/null
    fi
}
trap cleanup EXIT

if [[ -z "$BACKUP" ]]; then
    BACKUP=$(
        "$KUBECTL" get backups.velero.io -n "$VELERO_NS" -o json | NS="$NS" python3 -c '
import json, os, sys
ns = os.environ["NS"]
best = None
for b in json.load(sys.stdin)["items"]:
    st = b.get("status", {})
    inc = b.get("spec", {}).get("includedNamespaces") or ["*"]
    if st.get("phase") == "Completed" and ("*" in inc or ns in inc):
        key = st.get("completionTimestamp", "")
        if best is None or key > best[0]:
            best = (key, b["metadata"]["name"])
print(best[1] if best else "")
'
    )
    [[ -n "$BACKUP" ]] || die "no Completed backup includes namespace '$NS'"
fi
log "drill: restoring backup '$BACKUP' ($NS) into '$DRILL_NS'"

start=$SECONDS
"$VELERO" restore create "drill-${DRILL_NS}" --namespace "$VELERO_NS" \
    --from-backup "$BACKUP" --include-namespaces "$NS" \
    --namespace-mappings "${NS}:${DRILL_NS}" --wait >/dev/null
phase=$("$KUBECTL" get restores.velero.io "drill-${DRILL_NS}" -n "$VELERO_NS" -o jsonpath='{.status.phase}')
[[ "$phase" == "Completed" ]] || die "restore phase is '$phase'"

for d in $("$KUBECTL" get deployments -n "$DRILL_NS" -o name); do
    "$KUBECTL" rollout status "$d" -n "$DRILL_NS" --timeout="${MAX_RTO_SECONDS}s" >/dev/null \
        || die "$d did not become Ready"
done
rto=$((SECONDS - start))

if "$KUBECTL" get namespace "$NS" >/dev/null 2>&1; then
    for kind in configmaps secrets deployments services; do
        live=$("$KUBECTL" get "$kind" -n "$NS" -o name | awk '!/kube-root-ca.crt/' | wc -l)
        drill=$("$KUBECTL" get "$kind" -n "$DRILL_NS" -o name | awk '!/kube-root-ca.crt/' | wc -l)
        [[ "$live" == "$drill" ]] || die "$kind: live namespace has $live, restored copy has $drill"
    done
    log "object counts match the live namespace"
fi

(( rto <= MAX_RTO_SECONDS )) || die "RTO ${rto}s exceeds the ${MAX_RTO_SECONDS}s objective"
log "DRILL PASSED: backup '$BACKUP' restored and Ready in ${rto}s (objective ${MAX_RTO_SECONDS}s)"
