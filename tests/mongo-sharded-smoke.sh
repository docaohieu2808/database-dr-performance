#!/usr/bin/env bash
# Sharded cluster: form it, insert through mongos, assert data lands on BOTH shards.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../mongodb"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l3-sharded-cluster.yml)
U="${MONGO_ROOT_USER:-admin}"; P="${MONGO_ROOT_PASSWORD:-adminpassword}"
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${C[@]}" up -d
retry 420 "shards registered" bash -c "[[ \$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' shard-add) == 'exited 0' ]]"

ms() { docker exec "$1" mongosh --quiet -u "$U" -p "$P" --authenticationDatabase admin "${@:2}"; }

assert_eq 2 "$(ms mongos2 --eval "db.adminCommand({listShards: 1}).shards.length")" "two shards visible through the second router"
ms mongos1 --eval "const c = db.getSiblingDB('appdb').events; c.insertMany(Array.from({length: 2000}, (_, i) => ({userId: i, note: 'doc-' + i})))" >/dev/null
assert_eq 2000 "$(ms mongos2 --eval "db.getSiblingDB('appdb').events.countDocuments({})")" "2000 documents visible via mongos2"
per_shard="$(ms mongos1 --eval "db.getSiblingDB('appdb').events.aggregate([{\$collStats: {storageStats: {}}}]).toArray().map(s => s.storageStats.count).join(' ')")"
log "documents per shard: $per_shard"
for n in $per_shard; do [[ "$n" -gt 0 ]] || fail "a shard holds no data: $per_shard"; done
[[ "$(wc -w <<<"$per_shard")" -eq 2 ]] || fail "expected stats from 2 shards: $per_shard"
log "PASS: MongoDB sharded cluster"
