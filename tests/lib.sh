#!/usr/bin/env bash
# Shared helpers for the lab test scripts. Source, do not execute.

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[%s] FAIL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# assert_eq <expected> <actual> <message>
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (expected '$1', got '$2')"
  log "ok: $3 ($2)"
}

# retry <timeout-seconds> <description> <command...>: run until it succeeds
retry() {
  local timeout="$1" what="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    [[ $SECONDS -lt $deadline ]] || fail "timed out after ${timeout}s waiting for: ${what}"
    sleep 2
  done
  log "ok: ${what}"
}
