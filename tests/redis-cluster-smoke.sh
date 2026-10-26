#!/usr/bin/env bash
# Redis Cluster: form the cluster, spread keys over all slots, stop a primary and
# assert its replica takes over without data loss. REDIS_IMAGE selects Redis or Valkey.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../redis"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l3-cluster-mode.yml)
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${C[@]}" up -d
retry 120 "cluster init finished" bash -c "[[ \$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' redis-cluster-init) == 'exited 0' ]]"

cinfo() { docker exec "$1" redis-cli cluster info | tr -d '\r'; }
retry 60 "cluster_state:ok on node 1" bash -c "docker exec redis-node-1 redis-cli cluster info | grep -q cluster_state:ok"
assert_eq 6 "$(cinfo redis-node-1 | awk -F: '/cluster_known_nodes/{print $2}')" "6 nodes known"
assert_eq 3 "$(cinfo redis-node-1 | awk -F: '/cluster_size/{print $2}')" "3 primaries serving slots"

for i in $(seq 1 60); do docker exec redis-node-1 redis-cli -c set "key:$i" "value-$i" >/dev/null; done
assert_eq 60 "$(for i in $(seq 1 60); do docker exec redis-node-1 redis-cli -c get "key:$i"; done | grep -c value-)" "60 keys readable across shards"

sleep 3   # replication is asynchronous: let the replicas catch up before the primary dies
# Stop a primary: node 1 is a primary after a fresh create with replicas 1
role_of() { docker exec "$1" redis-cli info replication | tr -d '\r' | awk -F: '/^role:/{print $2}'; }
assert_eq master "$(role_of redis-node-1)" "redis-node-1 is a primary"
log "stopping redis-node-1 hard"
docker stop -t 0 redis-node-1 >/dev/null

# healed = cluster_state ok AND three primaries without the "fail" flag own slots (the stopped
# primary is still listed, flagged fail, until the replica that replaced it is promoted)
healed() {
  [[ "$(cinfo redis-node-2 2>/dev/null | awk -F: '/cluster_state/{print $2}')" == ok ]] || return 1
  [[ "$(docker exec redis-node-2 redis-cli cluster nodes | awk '$3 ~ /master/ && $3 !~ /fail/ && NF >= 9' | wc -l)" == 3 ]]
}
retry 90 "cluster healed (replica promoted)" healed
assert_eq 60 "$(for i in $(seq 1 60); do docker exec redis-node-2 redis-cli -c get "key:$i"; done | grep -c value-)" "all 60 keys still readable after losing a primary"
log "PASS: Redis Cluster"
