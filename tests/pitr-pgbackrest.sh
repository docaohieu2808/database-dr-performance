#!/usr/bin/env bash
# PITR test with pgBackRest: write rows, full backup, write more rows, record a
# timestamp, DROP the table, restore to the timestamp, assert table and ALL rows
# (including those written after the backup) are back.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../postgresql"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l5-pitr-pgbackrest.yml)
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql_() { "${C[@]}" exec -T postgres psql -U postgres -d appdb -v ON_ERROR_STOP=1 -qtAX -c "$1"; }
br()    { "${C[@]}" exec -T -u postgres postgres pgbackrest --stanza=main "$@"; }

log "starting PostgreSQL with WAL archiving"
"${C[@]}" up -d --build --wait --wait-timeout 180

br stanza-create
br check
log "ok: stanza created and archive check passed"

psql_ "CREATE TABLE orders (id serial PRIMARY KEY, note text)" >/dev/null
psql_ "INSERT INTO orders (note) SELECT 'in-backup-' || g FROM generate_series(1,100) g" >/dev/null
br --type=full backup
log "ok: full base backup taken"

psql_ "INSERT INTO orders (note) SELECT 'after-backup-' || g FROM generate_series(1,100) g" >/dev/null
assert_eq 200 "$(psql_ 'SELECT count(*) FROM orders')" "200 rows before the incident"
sleep 2
target="$(psql_ "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")"
log "recovery target: $target"
sleep 2

psql_ "DROP TABLE orders" >/dev/null
psql_ "SELECT pg_switch_wal()" >/dev/null
br check   # waits until the WAL holding the DROP is archived
if psql_ "SELECT count(*) FROM orders" >/dev/null 2>&1; then fail "table should be gone"; fi
log "ok: table dropped (the incident)"

log "stopping the database and restoring to $target"
"${C[@]}" stop postgres
"${C[@]}" run --rm --no-deps -T --user postgres --entrypoint pgbackrest postgres \
  --stanza=main --delta --type=time "--target=${target}" --target-action=promote restore
"${C[@]}" start postgres

promoted() { [[ "$(psql_ 'SELECT pg_is_in_recovery()' 2>/dev/null)" == "f" ]]; }
retry 120 "recovery finished and server promoted" promoted

assert_eq 200 "$(psql_ 'SELECT count(*) FROM orders')" "table and all 200 rows restored by PITR"
assert_eq 100 "$(psql_ "SELECT count(*) FROM orders WHERE note LIKE 'after-backup-%'")" "rows written after the base backup were replayed from archived WAL"
log "PASS: PITR"
