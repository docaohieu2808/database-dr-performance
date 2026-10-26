#!/usr/bin/env bash
# Replica set election: stop the primary hard, assert the others elect a new one,
# majority-acknowledged data survives, writes continue, old primary rejoins.
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS/../mongodb"
# shellcheck source=lib.sh
source "$TESTS/lib.sh"

C=(docker compose -f l2-replica-set.yml)
U="${MONGO_ROOT_USER:-admin}"; P="${MONGO_ROOT_PASSWORD:-adminpassword}"
URI="mongodb://${U}:${P}@mongo1:27017,mongo2:27017,mongo3:27017/admin?replicaSet=rs0&authSource=admin"
cleanup() { [[ $? -eq 0 ]] || "${C[@]}" logs --no-color --tail 80 || true; "${C[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${C[@]}" up -d
retry 240 "replica set initiated" bash -c "[[ \$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' mongo-rs-init) == 'exited 0' ]]"

# ms <via-container> <js>: run mongosh through the replica-set URI (follows the primary)
ms() { docker exec "$1" mongosh --quiet "$URI" --eval "$2"; }
# primary_of <via-container>: name of the current primary
primary_of() { ms "$1" "db.hello().primary" 2>/dev/null | cut -d: -f1; }
members() { ms "$1" "rs.status().members.map(m => m.name.split(':')[0] + '=' + m.stateStr).join(' ')"; }

settled() { [[ "$(ms mongo2 "rs.status().members.map(m => m.stateStr).sort().join(',')" 2>/dev/null)" == "PRIMARY,SECONDARY,SECONDARY" ]]; }
retry 90 "3 members: 1 PRIMARY + 2 SECONDARY" settled
old_primary="$(primary_of mongo2)"
assert_eq mongo1 "$old_primary" "mongo1 (priority 2) is the primary"

ms mongo2 "db.getSiblingDB('appdb').notes.insertOne({_id: 'before', v: 1}, {writeConcern: {w: 'majority', wtimeout: 10000}}).acknowledged" >/dev/null
log "ok: wrote a majority-acknowledged document"

log "stopping $old_primary hard"
docker stop -t 0 "$old_primary" >/dev/null
survivor=mongo2
new_primary=""
elected() { new_primary="$(primary_of "$survivor")"; [[ -n "$new_primary" && "$new_primary" != "$old_primary" ]]; }
retry 90 "a new primary was elected" elected
log "new primary: $new_primary"

assert_eq 1 "$(ms "$survivor" "db.getSiblingDB('appdb').notes.countDocuments({_id: 'before'})")" "majority-written document survived the election"
ms "$survivor" "db.getSiblingDB('appdb').notes.insertOne({_id: 'after', v: 2}).acknowledged" >/dev/null
assert_eq 2 "$(ms "$survivor" "db.getSiblingDB('appdb').notes.countDocuments({})")" "new primary accepts writes"

log "restarting $old_primary, expecting it to rejoin as SECONDARY (priority 2 then triggers a step-up election)"
docker start "$old_primary" >/dev/null
rejoined() { [[ "$(members "$survivor" 2>/dev/null)" == *"${old_primary}=SECONDARY"* || "$(members "$survivor" 2>/dev/null)" == *"${old_primary}=PRIMARY"* ]]; }
retry 120 "$old_primary rejoined the set" rejoined
log "PASS: MongoDB replica set election"
