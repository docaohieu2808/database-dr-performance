#!/usr/bin/env bash
# Sentinel failover: stop the primary hard, assert Sentinel promotes a replica,
# the replicated key is still readable, and the new primary accepts writes.
# REDIS_IMAGE selects Redis or Valkey.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../redis"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l2-sentinel-ha.yml)
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${C[@]}" up -d --wait --wait-timeout 180

# Ask sentinel-1 for the current primary's address (sentinel has no password)
primary_addr() { docker exec redis-sentinel-1 redis-cli -p 26379 sentinel get-master-addr-by-name mymaster | head -1; }
# Which container owns an address (IP or hostname)?
container_for() {
  for c in redis-primary redis-replica-1 redis-replica-2; do
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")"
    [[ "$1" == "$ip" || "$1" == "$c" ]] && { echo "$c"; return; }
  done
}
role_of() { docker exec "$1" redis-cli info replication | tr -d '\r' | awk -F: '/^role:/{print $2}'; }

# num-slaves + num-other-sentinels must reach 2 + 2 once the topology is discovered
discovered() {
  docker exec redis-sentinel-1 redis-cli -p 26379 sentinel master mymaster | tr -d '\r' | paste - - \
    | awk '$1=="num-slaves"||$1=="num-other-sentinels"{s+=$2} END{exit !(s>=4)}'
}
retry 60 "sentinels discovered 2 replicas and 2 other sentinels" discovered

old_addr="$(primary_addr)"
old_primary="$(container_for "$old_addr")"
[[ -n "$old_primary" ]] || fail "cannot map primary address $old_addr to a container"
log "primary before failover: $old_primary ($old_addr)"
assert_eq master "$(role_of "$old_primary")" "role of $old_primary"

docker exec "$old_primary" redis-cli set failover-key before >/dev/null
# WAIT blocks until >=2 replicas acknowledged the write (async replication otherwise)
assert_eq 2 "$(docker exec "$old_primary" redis-cli wait 2 5000)" "write acknowledged by both replicas"

log "stopping $old_primary hard"
docker stop -t 0 "$old_primary" >/dev/null

new_primary=""
failed_over() {
  local addr
  addr="$(primary_addr)" || return 1
  new_primary="$(container_for "$addr")"
  [[ -n "$new_primary" && "$new_primary" != "$old_primary" ]] && [[ "$(role_of "$new_primary" 2>/dev/null)" == "master" ]]
}
retry 90 "sentinel promoted a replica" failed_over
log "new primary: $new_primary"

assert_eq before "$(docker exec "$new_primary" redis-cli get failover-key)" "replicated key survived failover"
assert_eq OK "$(docker exec "$new_primary" redis-cli set failover-key after)" "new primary accepts writes"

log "restarting the old primary: sentinel must demote it to a replica"
docker start "$old_primary" >/dev/null
demoted() { [[ "$(role_of "$old_primary" 2>/dev/null)" == "slave" ]]; }
retry 90 "$old_primary rejoined as replica" demoted
caught_up() { [[ "$(docker exec "$old_primary" redis-cli get failover-key)" == after ]]; }
retry 60 "old primary caught up" caught_up
log "PASS: Sentinel failover"
