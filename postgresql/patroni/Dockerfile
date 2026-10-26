# Patroni HA image: official PostgreSQL 18 image + Patroni (etcd3 DCS) + pgBackRest.
# Build: docker build -t patroni-pg18:local ./patroni
FROM postgres:18

ARG PATRONI_VERSION=4.1.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv pgbackrest \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir \
         "patroni[etcd3]==${PATRONI_VERSION}" "psycopg[binary]==3.3.6"

ENV PATH="/opt/patroni/bin:${PATH}"

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY pgbackrest-stanza-create.sh /usr/local/bin/pgbackrest-stanza-create.sh

# /data is NOT a declared VOLUME in the base image, so ownership set here is kept
# when a named volume is mounted on top of it.
RUN mkdir -p /data /var/lib/pgbackrest /etc/patroni \
    && chown -R postgres:postgres /data /var/lib/pgbackrest \
    && chmod 700 /data \
    && chmod +x /usr/local/bin/pgbackrest-stanza-create.sh

USER postgres
STOPSIGNAL SIGTERM
EXPOSE 5432 8008

ENTRYPOINT ["patroni", "/etc/patroni/patroni.yml"]
