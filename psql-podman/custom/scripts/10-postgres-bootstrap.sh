#!/bin/bash
# Runs once during combustion on first boot.
# Generates a random PostgreSQL superuser password, writes it to
# /etc/postgres/postgres.env (consumed by the postgres.container quadlet
# via EnvironmentFile=), and prints it to the console + journal.
#
# NOTE: SL Micro mounts /var as a separate btrfs subvolume that is NOT
# bind-mounted into combustion's transactional-update chroot (log: "Separate
# /var detected."). Anything mkdir'd under /var here lands in the orphaned
# snapshot copy and disappears at boot. The data dir is provisioned instead
# by /etc/tmpfiles.d/postgres.conf, which runs after /var is mounted.
set -euo pipefail

ENV_FILE=/etc/postgres/postgres.env

mkdir -p /etc/postgres

if [ ! -f "$ENV_FILE" ]; then
  PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 256 /dev/urandom))"
  PASSWORD="${PASSWORD:0:32}"
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
