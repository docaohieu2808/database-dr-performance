#!/usr/bin/env bash
# l-max: build the C extension with pgxs inside a PostgreSQL 18 image, load it and
# assert every function, the aggregate and the DDL audit trigger.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../postgresql/l-max-custom-extension"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

NAME=pg-ext-test
cleanup() { [[ $? -eq 0 ]] || docker logs --tail 60 "$NAME" || true; docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -t pg-extension:local .
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=lab pg-extension:local >/dev/null
ready() { docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; }
retry 60 "postgres ready" ready
# the entrypoint restarts the server once after initdb; wait for the final one
sleep 3
retry 30 "postgres ready (final server)" ready

q() { docker exec "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -qtAX -c "$1"; }
q "CREATE EXTENSION my_extension"
assert_eq 5 "$(q 'SELECT my_add(2, 3)')" "my_add (C)"
if q 'SELECT my_add(2147483647, 1)' >/dev/null 2>&1; then fail "my_add must raise on overflow"; fi
log "ok: my_add raises on integer overflow"
assert_eq 5 "$(q 'SELECT my_distance(ROW(0,0)::my_point, ROW(3,4)::my_point)')" "my_distance (C, composite arguments)"
assert_eq 10 "$(q 'SELECT my_clamp(15, 0, 10)')" "my_clamp (plpgsql)"
assert_eq 6 "$(q 'SELECT my_running_sum(g) FROM generate_series(1,3) g')" "my_running_sum aggregate"
q "CREATE TABLE audited (id int)" >/dev/null
q "ALTER TABLE audited ADD COLUMN note text" >/dev/null
assert_eq "CREATE TABLE,ALTER TABLE" "$(q "SELECT string_agg(command_tag, ',' ORDER BY id) FROM my_ddl_log WHERE object_identity = 'public.audited'")" "event trigger logged the DDL"
q "DROP EXTENSION my_extension CASCADE" >/dev/null
log "PASS: custom extension"
