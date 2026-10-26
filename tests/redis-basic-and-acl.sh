#!/usr/bin/env bash
# l1 (password + persistence) and l4 (ACL file) checks. REDIS_IMAGE selects Redis or Valkey.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../redis"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l1-basic-docker-compose.yml)
IMAGE="${REDIS_IMAGE:-redis:8.10-alpine}"
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; docker rm -f redis-acl >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "l1: start with password and AOF/RDB persistence"
"${C[@]}" up -d --wait --wait-timeout 90
rc() { "${C[@]}" exec -T redis redis-cli "$@"; }

assert_eq PONG "$(rc ping)" "authenticated PING"
bad="$("${C[@]}" exec -T -e REDISCLI_AUTH=wrong redis redis-cli ping 2>&1 || true)"
[[ "$bad" == *"WRONGPASS"* || "$bad" == *"invalid"* ]] || fail "wrong password must be rejected (got: $bad)"
log "ok: wrong password rejected"
rc set persisted-key hello >/dev/null
"${C[@]}" restart redis
retry 60 "redis back after restart" rc ping
assert_eq hello "$(rc get persisted-key)" "key survived a restart (AOF)"
assert_eq yes "$(rc config get appendonly | tail -1)" "appendonly enabled"

log "l4: load the ACL file"
docker run -d --name redis-acl -v "$PWD/l4-redis-acl-config.conf:/acl/users.acl:ro" "$IMAGE" \
  redis-server --aclfile /acl/users.acl >/dev/null
acl() { docker exec redis-acl redis-cli --no-auth-warning "$@"; }
u() { local user="$1"; shift; acl --user "$user" --pass "${user}-lab-password" "$@"; }
retry 30 "ACL redis up" bash -c "docker exec redis-acl redis-cli --no-auth-warning --user admin --pass admin-lab-password ping | grep -q PONG"

[[ "$(acl ping 2>&1)" == *NOAUTH* ]] || fail "default user must be disabled"
log "ok: unauthenticated access refused"
assert_eq OK "$(u appuser set app:one 1)" "appuser may write app:*"
[[ "$(u appuser set other:one 1 2>&1)" == *NOPERM* ]] || fail "appuser must not write outside app:*"
[[ "$(u appuser flushall 2>&1)" == *NOPERM* ]] || fail "appuser must not FLUSHALL"
log "ok: appuser confined to its key prefix and denied dangerous commands"
assert_eq 1 "$(u readonly get app:one)" "readonly may read"
[[ "$(u readonly set app:one 2 2>&1)" == *NOPERM* ]] || fail "readonly must not write"
log "ok: readonly cannot write"
assert_eq OK "$(u cacheuser set cache:a 1)" "cacheuser may write cache:*"
[[ "$(u cacheuser set app:a 1 2>&1)" == *NOPERM* ]] || fail "cacheuser must not write app:*"
assert_eq admin "$(u admin acl whoami)" "admin identity"
log "PASS: redis basic + ACL"
