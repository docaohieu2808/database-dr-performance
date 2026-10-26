# Builds and installs the extension into a PostgreSQL 18 image (pgxs).
FROM postgres:18
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential postgresql-server-dev-18 \
    && rm -rf /var/lib/apt/lists/*
COPY . /src/my_extension
WORKDIR /src/my_extension
RUN make clean && make && make install
