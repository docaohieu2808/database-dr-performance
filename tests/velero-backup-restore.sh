#!/usr/bin/env bash
# Velero on a kind cluster: install the chart with the l1 values (+ in-cluster S3),
# apply the l2 schedules, back a namespace up, DELETE it, restore it with the l3
# procedure script and assert the data came back.
# Needs: kubectl, helm, velero CLI and a running kind cluster (CI creates one).
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../disaster-recovery"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

CHART_VERSION="${VELERO_CHART_VERSION:-12.2.1}"

log "installing the S3 stand-in and Velero ${CHART_VERSION}"
kubectl create namespace velero
kubectl apply -f ci/seaweedfs.yaml
kubectl -n velero rollout status deployment/seaweedfs --timeout=180s
kubectl -n velero run create-bucket --image=curlimages/curl:8.23.0 --restart=Never --command -- \
  curl -fsS -X PUT http://seaweedfs:8333/velero
kubectl -n velero wait --for=jsonpath='{.status.phase}'=Succeeded pod/create-bucket --timeout=120s

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm install velero vmware-tanzu/velero --version "$CHART_VERSION" --namespace velero \
  -f l1-velero-install-helm-values.yaml -f ci/velero-kind-values.yaml --wait --timeout 5m

retry 120 "backup storage location Available" bash -c \
  "[[ \$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}') == Available ]]"

log "l2: schedules and locations are accepted by the real Velero CRDs"
kubectl apply --dry-run=server -f l2-velero-schedule-backup.yaml

log "creating the workload that will be lost"
kubectl create namespace dr-demo
kubectl -n dr-demo create configmap app-config --from-literal=greeting=hello-from-backup
kubectl -n dr-demo create secret generic app-secret --from-literal=token=s3cr3t-demo
kubectl -n dr-demo create deployment web --image=nginx:1.31-alpine --replicas=2
kubectl -n dr-demo rollout status deployment/web --timeout=180s

velero backup create demo-backup --include-namespaces dr-demo --wait
assert_eq Completed "$(kubectl -n velero get backup demo-backup -o jsonpath='{.status.phase}')" "backup phase"

log "disaster: deleting namespace dr-demo"
kubectl delete namespace dr-demo --wait=true --timeout=180s
if kubectl get namespace dr-demo >/dev/null 2>&1; then fail "namespace should be gone"; fi

log "l3: restoring with the procedure script"
ASSUME_YES=1 ./l3-velero-restore-procedure.sh namespace demo-backup dr-demo
kubectl -n dr-demo rollout status deployment/web --timeout=180s
assert_eq hello-from-backup "$(kubectl -n dr-demo get configmap app-config -o jsonpath='{.data.greeting}')" "ConfigMap restored"
assert_eq s3cr3t-demo "$(kubectl -n dr-demo get secret app-secret -o jsonpath='{.data.token}' | base64 -d)" "Secret restored"
assert_eq 2 "$(kubectl -n dr-demo get deployment web -o jsonpath='{.status.readyReplicas}')" "Deployment restored with its replica count"
log "l-max: restore drill into a throw-away namespace"
./l-max-restore-drill.sh dr-demo demo-backup
log "PASS: Velero backup / delete / restore / drill"
