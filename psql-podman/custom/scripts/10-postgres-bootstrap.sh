#!/bin/bash
# Runs once during combustion on first boot.
# Generates a random PostgreSQL superuser password, writes it to
# /etc/postgres/postgres.env (consumed by the postgres.container quadlet
# via EnvironmentFile=), and prints it to the console + journal.
set -euo pipefail

ENV_FILE=/etc/postgres/postgres.env
DATA_DIR=/var/lib/postgres/data

mkdir -p /etc/postgres "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ ! -f "$ENV_FILE" ]; then
  PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  cat > "$ENV_FILE" <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${PASSWORD}
POSTGRES_DB=postgres
PGDATA=/var/lib/postgresql/data
EOF
  chmod 600 "$ENV_FILE"

  cat <<BANNER | tee /dev/console

================================================================
  PostgreSQL superuser password (generated on first boot)
  user:     postgres
  password: ${PASSWORD}
  env file: ${ENV_FILE}
  Retrieve later with:
    sudo grep POSTGRES_PASSWORD ${ENV_FILE}
================================================================

BANNER
fi
