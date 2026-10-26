#!/usr/bin/env bash
# l1 sanity, l2 streaming replication and l4 PgBouncer (which includes l2).
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../postgresql"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

U="${POSTGRES_USER:-pguser}"; P="${POSTGRES_PASSWORD:-pgpassword}"
C=(docker compose -f l4-pgbouncer-pooler.yml)
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; docker compose -f l1-basic-docker-compose.yml down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "l1: single node with init SQL"
docker compose -f l1-basic-docker-compose.yml up -d --wait --wait-timeout 120
l1() { docker compose -f l1-basic-docker-compose.yml exec -T postgres psql -U "$U" -d appdb -qtAX -c "$1"; }
assert_eq 1 "$(l1 "SELECT count(*) FROM information_schema.tables WHERE table_name='events'")" "init SQL created the events table"
docker compose -f l1-basic-docker-compose.yml down -v >/dev/null

log "l2 + l4: primary, streaming replica, PgBouncer"
"${C[@]}" up -d --build --wait --wait-timeout 240
primary() { "${C[@]}" exec -T -e PGPASSWORD="$P" postgres-primary psql -U "$U" -d appdb -qtAX -c "$1"; }
replica() { "${C[@]}" exec -T -e PGPASSWORD="$P" postgres-replica psql -U "$U" -d appdb -qtAX -c "$1"; }

assert_eq t "$(replica 'SELECT pg_is_in_recovery()')" "replica is in recovery (hot standby)"
assert_eq streaming "$(primary "SELECT state FROM pg_stat_replication")" "primary sees a streaming replica"
primary "CREATE TABLE repl_test (id int PRIMARY KEY, v text)" >/dev/null
primary "INSERT INTO repl_test SELECT g, 'row-' || g FROM generate_series(1,500) g" >/dev/null
copied() { [[ "$(replica 'SELECT count(*) FROM repl_test' 2>/dev/null)" == 500 ]]; }
retry 60 "500 rows replicated" copied
if replica "INSERT INTO repl_test VALUES (999,'x')" >/dev/null 2>&1; then fail "replica must be read-only"; fi
log "ok: replica rejects writes"

# PgBouncer: connect from inside the pooler container through the pool
pgb() { "${C[@]}" exec -T -e PGPASSWORD="$P" pgbouncer psql -h 127.0.0.1 -p 6432 -U "$U" "$1" -qtAX -c "$2"; }
assert_eq 500 "$(pgb appdb 'SELECT count(*) FROM repl_test')" "query via PgBouncer to the primary"
assert_eq 500 "$(pgb appdb_replica 'SELECT count(*) FROM repl_test')" "query via PgBouncer to the replica alias"
assert_eq transaction "$(pgb pgbouncer 'SHOW CONFIG' | awk -F'|' '$1=="pool_mode"{print $2}')" "PgBouncer pool_mode"
# 100 concurrent clients must be served by at most default_pool_size + reserve_pool_size (25 + 10) server connections
"${C[@]}" exec -T postgres-primary pgbench -i -s 1 -U "$U" -d appdb >/dev/null 2>&1
"${C[@]}" exec -T -e PGPASSWORD="$P" postgres-primary \
  pgbench -h pgbouncer -p 6432 -U "$U" -c 100 -j 4 -T 8 -S appdb >/tmp/pgbench.out 2>&1 &
bench=$!
sleep 4
# pool(<column>): value of a SHOW POOLS column for the appdb pool (header-driven, version independent)
pool() {
  "${C[@]}" exec -T -e PGPASSWORD="$P" pgbouncer psql --csv -h 127.0.0.1 -p 6432 -U "$U" pgbouncer -c 'SHOW POOLS' \
    | awk -F, -v col="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==col) c=i} NR>1 && $1=="appdb"{print $c}'
}
clients=$(( $(pool cl_active) + $(pool cl_waiting) ))
servers=$(( $(pool sv_active) + $(pool sv_idle) + $(pool sv_used) ))
log "clients=$clients server_connections=$servers"
wait "$bench" || { cat /tmp/pgbench.out; fail "pgbench through PgBouncer failed"; }
[[ "$servers" -le 35 && "$clients" -gt "$servers" ]] || fail "PgBouncer did not multiplex ($clients clients, $servers servers)"
log "ok: $clients clients multiplexed onto $servers server connections"
log "PASS: replication + PgBouncer"
