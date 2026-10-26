#!/usr/bin/env bash
# Patroni HA test: start 3 nodes + etcd + HAProxy, write data, stop the leader hard,
# assert another node is promoted and writes keep working through HAProxy, then
# bring the old leader back and assert it rejoins as a replica. Also checks that
# pgBackRest WAL archiving works from the newly promoted primary.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../postgresql"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l3-patroni-ha-cluster.yml)
PW="${PG_SUPERUSER_PASSWORD:-superpassword}"
NODES=(patroni1 patroni2 patroni3)

cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# members_json <via-node>: patronictl list as JSON, from the given node
members_json() { "${C[@]}" exec -T "$1" patronictl -c /etc/patroni/patroni.yml list -f json; }
# leader_of <via-node>: name of the running leader, empty if none
leader_of() { members_json "$1" 2>/dev/null | jq -r '[.[] | select(.Role=="Leader" and .State=="running")][0].Member // empty'; }
# sql <via-node> <sql>: run through HAProxy (always the current primary)
sql() {
  "${C[@]}" exec -T -e PGPASSWORD="$PW" "$1" \
    psql -h haproxy -p 5000 -U postgres -v ON_ERROR_STOP=1 -qtAX -c "$2"
}

log "building and starting the cluster"
"${C[@]}" up -d --build --wait --wait-timeout 300

retry 120 "3 running members with a leader" bash -c \
  "[[ \$(docker exec patroni1 patronictl -c /etc/patroni/patroni.yml list -f json | jq '[.[]|select(.State==\"running\" or .State==\"streaming\")]|length') == 3 ]]"

old_leader="$(leader_of patroni1)"
[[ -n "$old_leader" ]] || fail "no leader found"
log "initial leader: $old_leader"

# HAProxy needs a few health-check rounds before it routes to the new leader
haproxy_ready() { sql patroni1 "SELECT 1" >/dev/null 2>&1; }
retry 60 "HAProxy routes to the primary" haproxy_ready
sql patroni1 "CREATE TABLE IF NOT EXISTS ha_test (id serial PRIMARY KEY, note text)" >/dev/null
sql patroni1 "INSERT INTO ha_test (note) SELECT 'before-failover-' || g FROM generate_series(1,1000) g" >/dev/null
before="$(sql patroni1 "SELECT count(*) FROM ha_test")"
assert_eq 1000 "$before" "rows written through HAProxy before failover"
sleep 5   # let replication catch up (async replication)

log "stopping leader $old_leader hard (SIGKILL)"
docker stop -t 0 "$old_leader" >/dev/null

survivor=""
for n in "${NODES[@]}"; do [[ "$n" != "$old_leader" ]] && { survivor="$n"; break; }; done
new_leader=""
promoted() {
  new_leader="$(leader_of "$survivor")"
  [[ -n "$new_leader" && "$new_leader" != "$old_leader" ]]
}
retry 120 "a replica was promoted to leader" promoted
log "new leader: $new_leader"

write_after() { sql "$survivor" "INSERT INTO ha_test (note) SELECT 'after-failover-' || g FROM generate_series(1,500) g" >/dev/null 2>&1; }
retry 90 "writes succeed again through HAProxy" write_after
total="$(sql "$survivor" "SELECT count(*) FROM ha_test")"
assert_eq 1500 "$total" "no committed row lost, new writes accepted"

"${C[@]}" exec -T -u postgres "$new_leader" pgbackrest --stanza=main check
log "ok: pgBackRest archiving works from the promoted primary"

log "restarting the old leader, expecting it to rejoin as a replica"
docker start "$old_leader" >/dev/null
rejoined() {
  members_json "$survivor" 2>/dev/null \
    | jq -e --arg n "$old_leader" \
        '.[] | select(.Member==$n and .Role=="Replica" and (.State=="streaming" or .State=="running"))' >/dev/null
}
retry 180 "$old_leader rejoined as replica" rejoined
log "PASS: Patroni failover"
