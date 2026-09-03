#!/usr/bin/env bash
set -euo pipefail

cd /home/container

ensure_runtime() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing Docker CLI and Compose inside the server container..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends docker.io docker-compose-v2 curl ca-certificates openssl
}

generate_env() {
  local deployment_id jwt_key admin_api_token postgres_password server_image version_tag
  local advertised_address public_api_url hosting_mode port_min port_max
  local network_name network_description motd admin_bind_address rust_log

  deployment_id="$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)"
  jwt_key="$(openssl rand -hex 32)"
  admin_api_token="$(openssl rand -hex 32)"
  postgres_password="$(openssl rand -hex 32)"

  server_image="$(grep -E '^Image=' ServerImage.txt | head -n1 | cut -d= -f2- || true)"
  version_tag="$(tr -d '\r\n' < Version.txt 2>/dev/null || true)"
  server_image="${server_image:-reside-server:${version_tag:-1.1.10}-89a00244c63f}"

  advertised_address="${SERVER_MANAGER_ADVERTISED_ADDRESS:-}"
  public_api_url="${SERVER_MANAGER_PUBLIC_API_URL:-}"
  hosting_mode="${SERVER_MANAGER_HOSTING_MODE:-public}"
  port_min="${SERVER_MANAGER_PORT_MIN:-7777}"
  port_max="${SERVER_MANAGER_PORT_MAX:-7782}"
  network_name="${RESIDE_NETWORK_NAME:-vSide}"
  network_description="${RESIDE_NETWORK_DESCRIPTION:-Welcome back to vSide!}"
  motd="${RESIDE_SERVER_MOTD:-Come as you are. Go anywhere.}"
  admin_bind_address="${ADMIN_BIND_ADDRESS:-0.0.0.0}"
  rust_log="${RUST_LOG:-info}"

  if [ -z "$advertised_address" ]; then
    echo "ERROR: SERVER_MANAGER_ADVERTISED_ADDRESS must be set in the server configuration." >&2
    exit 1
  fi

  mkdir -p Api

  cat > Api/.env <<EOF
RESIDE_NETWORK_NAME="$network_name"
RESIDE_SERVER_MOTD="$motd"
NETWORK_DISCOVERY_ENABLED=true
NETWORK_DISCOVERY_API_PORT=3000
SERVER_MANAGER_HOSTING_MODE="$hosting_mode"
SERVER_MANAGER_ADVERTISED_ADDRESS="$advertised_address"
SERVER_MANAGER_PUBLIC_API_URL="$public_api_url"
SERVER_MANAGER_PORT_MIN="$port_min"
SERVER_MANAGER_PORT_MAX="$port_max"
RUST_LOG="$rust_log"
JWT_KEY=$jwt_key
ADMIN_API_TOKEN=$admin_api_token
DEPLOYMENT_ID=$deployment_id
ADMIN_BIND_ADDRESS="$admin_bind_address"
POSTGRES_PASSWORD=$postgres_password
DATABASE_URL=postgres://postgres:$postgres_password@db:5432/reside
RESIDE_IMAGE_TAG=${version_tag:-1.1.10}
SERVER_MANAGER_IMAGE=$server_image
EOF
}

cleanup() {
  if [ -x ./stop.sh ]; then
    sh ./stop.sh || true
  fi
}

trap cleanup INT TERM EXIT

ensure_runtime
generate_env

if [ ! -f Api/docker-compose.yml ]; then
  echo "ERROR: ReSide backend files were not found in /home/container." >&2
  exit 1
fi

echo "Starting ReSide backend..."
sh ./start.sh --host-firewall-configured

echo "ReSide backend ready."

while true; do
  sleep 3600
done
