#!/usr/bin/env sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PACKAGE_DIRECTORY="$SCRIPT_DIRECTORY"
if [ ! -f "$PACKAGE_DIRECTORY/docker-compose.yml" ]; then
    PACKAGE_DIRECTORY="$(dirname -- "$PACKAGE_DIRECTORY")"
fi
if [ ! -f "$PACKAGE_DIRECTORY/docker-compose.yml" ]; then
    PACKAGE_DIRECTORY="$(dirname -- "$PACKAGE_DIRECTORY")"
fi
COMPOSE_PATH="$PACKAGE_DIRECTORY/docker-compose.yml"

if [ ! -f "$COMPOSE_PATH" ]; then
    echo "ERROR: docker-compose.yml was not found in or above $SCRIPT_DIRECTORY."
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or is not available on PATH."
    exit 1
fi

echo "Stopping the API container..."
docker compose --file "$COMPOSE_PATH" stop api

restart_api() {
    echo "Starting the API container..."
    docker compose --file "$COMPOSE_PATH" start api
}
trap restart_api EXIT

echo "Dropping and recreating the reside database..."
docker compose --file "$COMPOSE_PATH" exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'reside' AND pid <> pg_backend_pid();"
docker compose --file "$COMPOSE_PATH" exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS reside;"
docker compose --file "$COMPOSE_PATH" exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE reside;"

echo "Database reset complete. The API will apply migrations during startup."
