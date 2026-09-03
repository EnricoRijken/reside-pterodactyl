#!/usr/bin/env bash
set -euo pipefail

cd /home/container

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker CLI is missing from the runtime image." >&2
  exit 1
fi

if [ ! -f Api/docker-compose.yml ] || [ ! -f Api/reside-images.tar ]; then
  echo "ReSide backend files are missing. Run the installer again." >&2
  exit 1
fi

if [ -z "${SERVER_MANAGER_ADVERTISED_ADDRESS:-}" ]; then
  echo "SERVER_MANAGER_ADVERTISED_ADDRESS must be set in the server variables." >&2
  exit 1
fi

if [ ! -f Api/.env ]; then
  jwt_key="$(openssl rand -hex 32)"
  admin_api_token="$(openssl rand -hex 32)"
  deployment_id="$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)"
  postgres_password="$(openssl rand -hex 32)"

  cat > Api/.env <<EOF
RESIDE_NETWORK_NAME=${RESIDE_NETWORK_NAME:-vSide}
RESIDE_SERVER_MOTD=${RESIDE_SERVER_MOTD:-Come as you are. Go anywhere.}
NETWORK_DISCOVERY_ENABLED=true
NETWORK_DISCOVERY_API_PORT=3000
SERVER_MANAGER_HOSTING_MODE=${SERVER_MANAGER_HOSTING_MODE:-public}
SERVER_MANAGER_ADVERTISED_ADDRESS=${SERVER_MANAGER_ADVERTISED_ADDRESS}
SERVER_MANAGER_PUBLIC_API_URL=${SERVER_MANAGER_PUBLIC_API_URL:-}
SERVER_MANAGER_PORT_MIN=${SERVER_MANAGER_PORT_MIN:-7777}
SERVER_MANAGER_PORT_MAX=${SERVER_MANAGER_PORT_MAX:-7782}
RUST_LOG=${RUST_LOG:-info}
JWT_KEY=${jwt_key}
ADMIN_API_TOKEN=${admin_api_token}
DEPLOYMENT_ID=${deployment_id}
ADMIN_BIND_ADDRESS=${ADMIN_BIND_ADDRESS:-0.0.0.0}
POSTGRES_PASSWORD=${postgres_password}
DATABASE_URL=postgres://postgres:${postgres_password}@db:5432/reside
RESIDE_IMAGE_TAG=${RESIDE_IMAGE_TAG:-1.1.10}
SERVER_MANAGER_IMAGE=${SERVER_MANAGER_IMAGE:-reside-server:latest}
EOF
fi

echo "Starting ReSide backend..."
sh ./start.sh --host-firewall-configured

echo "ReSide backend ready."
tail -f /dev/null
