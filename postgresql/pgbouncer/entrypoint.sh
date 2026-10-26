#!/bin/sh
# Generate the userlist from env (lab only) and run PgBouncer in the foreground.
set -eu
umask 077
printf '"%s" "%s"\n' "$PGB_USER" "$PGB_PASSWORD" > /tmp/userlist.txt
sed 's#/etc/pgbouncer/userlist.txt#/tmp/userlist.txt#' /etc/pgbouncer/pgbouncer.ini > /tmp/pgbouncer.ini
exec pgbouncer /tmp/pgbouncer.ini
