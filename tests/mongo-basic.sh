#!/usr/bin/env bash
# l1: auth is enforced, the init script created appuser, TTL index exists.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../mongodb"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l1-basic-docker-compose.yml)
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${C[@]}" up -d --wait --wait-timeout 120
m() { "${C[@]}" exec -T mongodb mongosh --quiet "$@"; }

denied="$(m --eval "db.getSiblingDB('appdb').events.countDocuments({})" 2>&1 || true)"
[[ "$denied" == *"requires authentication"* || "$denied" == *"Unauthorized"* ]] || fail "anonymous access must be refused (got: $denied)"
log "ok: anonymous access refused"
assert_eq 0 "$(m "mongodb://appuser:${MONGO_APP_PASSWORD:-apppassword}@localhost/appdb" --eval 'db.events.countDocuments({})')" "appuser (created by init script) can query appdb"
assert_eq 1 "$(m "mongodb://appuser:${MONGO_APP_PASSWORD:-apppassword}@localhost/appdb" --eval 'db.events.getIndexes().filter(i => i.expireAfterSeconds).length')" "TTL index created by init script"
log "PASS: MongoDB basic"
