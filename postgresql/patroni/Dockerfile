# Patroni HA image — PostgreSQL 16 + Patroni 3.x + etcd client
# Build: docker build -t patroni:latest ./patroni
# NOTE: Patroni kept as learning material; production fleet uses docker pg17-alpine standalone.
FROM python:3.12-slim

ARG PATRONI_VERSION=3.3.2
ARG PG_MAJOR=16

# Install PostgreSQL client + server binaries
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      gnupg \
      lsb-release \
      procps \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
         postgresql-${PG_MAJOR} \
         postgresql-client-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni with etcd extras
RUN pip install --no-cache-dir \
      "patroni[etcd]==${PATRONI_VERSION}" \
      psycopg2-binary

# Add postgres binaries to PATH
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

# Patroni config is bind-mounted at runtime (see docker-compose)
RUN mkdir -p /etc/patroni /var/lib/postgresql/data
RUN chown -R postgres:postgres /var/lib/postgresql

USER postgres
EXPOSE 5432 8008

ENTRYPOINT ["patroni", "/etc/patroni/patroni.yml"]
