#!/bin/sh
# Patroni bootstrap.post_bootstrap hook: runs once on the first node after initdb,
# with PostgreSQL up. Creates the pgBackRest stanza so archive_command can push WAL.
set -eu
exec pgbackrest --stanza=main stanza-create
