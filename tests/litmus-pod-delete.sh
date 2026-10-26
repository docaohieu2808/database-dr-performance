#!/usr/bin/env bash
# Litmus 3 on a kind cluster: install the operator, run the pod-delete ChaosEngine from
# l4 against a 3-replica service and require verdict Pass; then validate l-max against
# the real CRDs (server-side dry run) and install its fault definitions.
# Needs kubectl, helm, yq and a running kind cluster.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../performance-chaos"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

CHART_VERSION="${LITMUS_CHART_VERSION:-3.31.1}"
CHARTS_REF="${LITMUS_CHAOS_CHARTS_REF:-3.31.0}"
FAULTS="https://raw.githubusercontent.com/litmuschaos/chaos-charts/${CHARTS_REF}/faults/kubernetes"

helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/ >/dev/null
helm repo update >/dev/null
helm install litmus-core litmuschaos/litmus-core --version "$CHART_VERSION" \
  --namespace litmus --create-namespace --wait --timeout 5m
kubectl wait --for=condition=established --timeout=60s \
  crd/chaosengines.litmuschaos.io crd/chaosexperiments.litmuschaos.io crd/chaosresults.litmuschaos.io

kubectl create namespace chaos-demo
kubectl apply -n chaos-demo -f "${FAULTS}/pod-delete/fault.yaml"

log "deploying the target (everything in l4 except the ChaosEngine)"
yq 'select(.kind != "ChaosEngine")' l4-litmus-chaos-experiment.yaml | kubectl apply -f -
kubectl -n chaos-demo rollout status deployment/my-api-service --timeout=180s

log "running the pod-delete ChaosEngine"
yq 'select(.kind == "ChaosEngine")' l4-litmus-chaos-experiment.yaml | kubectl apply -f -
result() { kubectl -n chaos-demo get chaosresult pod-delete-chaos-engine-pod-delete -o jsonpath='{.status.experimentStatus.verdict}' 2>/dev/null; }
finished() { local v; v="$(result)"; [[ "$v" == Pass || "$v" == Fail || "$v" == Stopped ]]; }
retry 420 "chaos experiment finished" finished
verdict="$(result)"
kubectl -n chaos-demo get chaosresult pod-delete-chaos-engine-pod-delete -o yaml | yq '.status'
assert_eq Pass "$verdict" "ChaosResult verdict"
assert_eq 100 "$(kubectl -n chaos-demo get chaosresult pod-delete-chaos-engine-pod-delete -o jsonpath='{.status.experimentStatus.probeSuccessPercentage}')" "probe success percentage"
kubectl -n chaos-demo rollout status deployment/my-api-service --timeout=120s
log "ok: service recovered to full strength after the chaos"

log "l-max: fault definitions + engine validated against the real CRDs"
for f in pod-network-latency pod-cpu-hog disk-fill; do
  kubectl apply -n chaos-demo -f "${FAULTS}/${f}/fault.yaml"
done
kubectl apply --dry-run=server -f l-max-custom-chaos-experiment.yaml
log "PASS: Litmus"
