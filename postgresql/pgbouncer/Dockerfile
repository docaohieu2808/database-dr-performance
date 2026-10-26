# PgBouncer from Alpine's package repo (no official upstream image).
FROM alpine:3.24
RUN apk add --no-cache pgbouncer postgresql18-client
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER pgbouncer
EXPOSE 6432
ENTRYPOINT ["/entrypoint.sh"]
