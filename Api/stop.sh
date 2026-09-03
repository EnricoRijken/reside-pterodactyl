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
ENVIRONMENT_PATH="$PACKAGE_DIRECTORY/.env"

if [ ! -f "$COMPOSE_PATH" ]; then
    echo "ERROR: docker-compose.yml was not found in or above $SCRIPT_DIRECTORY."
    echo "Re-extract the complete API release folder."
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or is not available on PATH."
    exit 1
fi
if [ ! -f "$ENVIRONMENT_PATH" ]; then
    echo "ERROR: .env was not found in $PACKAGE_DIRECTORY; refusing an unscoped stop." >&2
    exit 1
fi

deployment_id=$(sed -n 's/^DEPLOYMENT_ID=//p' "$ENVIRONMENT_PATH" | sed -n '1p' | tr -d '\r')
case "$deployment_id" in
    ''|[!a-z0-9]*|*[!a-z0-9_-]*)
        echo "ERROR: DEPLOYMENT_ID is missing or invalid in $ENVIRONMENT_PATH; refusing an unscoped stop." >&2
        exit 1
        ;;
esac
deployment_network="reside_${deployment_id}_backend"

# Keep IDs in files and read them one line at a time. Command substitution would
# subject a multi-container result to shell word splitting.
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/reside-stop.XXXXXX")
paused_ids_path="$temporary_directory/paused-api-ids"
: >"$paused_ids_path"
cleanup() {
    while IFS= read -r container_id || [ -n "$container_id" ]; do
        [ -n "$container_id" ] && docker unpause "$container_id" >/dev/null 2>&1 || true
    done <"$paused_ids_path"
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM
api_ids_path="$temporary_directory/api-ids"
managed_ids_path="$temporary_directory/managed-ids"

# Freeze the manager while managed servers are stopped and detached.
echo "Quiescing the ReSide server manager..."
if ! docker compose --env-file "$ENVIRONMENT_PATH" --file "$COMPOSE_PATH" ps --all --quiet api >"$api_ids_path"; then
    echo "ERROR: Docker Compose failed to identify the API container." >&2
    exit 1
fi
while IFS= read -r container_id || [ -n "$container_id" ]; do
    [ -n "$container_id" ] || continue
    quiesced=false
    quiesce_attempt=1
    while [ "$quiesce_attempt" -le 15 ]; do
        state=$(docker inspect --format '{{.State.Status}} {{.State.Paused}}' "$container_id") || {
            echo "ERROR: Docker failed to inspect API container $container_id." >&2
            exit 1
        }
        case "$state" in
            'running false')
                if docker pause "$container_id" >/dev/null 2>&1; then
                    printf '%s\n' "$container_id" >>"$paused_ids_path"
                    quiesced=true
                    break
                fi
                ;;
            'running true'|'created false'|'exited false'|'dead false')
                quiesced=true
                break
                ;;
        esac
        sleep 1
        quiesce_attempt=$((quiesce_attempt + 1))
    done
    if [ "$quiesced" != true ]; then
        echo "ERROR: API container $container_id could not be quiesced after 15 seconds; managed-server cleanup cannot be made reliable." >&2
        exit 1
    fi
done <"$api_ids_path"

echo "Stopping API-managed game servers..."
cleanup_succeeded=false
attempt=1
while [ "$attempt" -le 3 ]; do
    if ! docker ps --all --quiet \
        --filter label=com.reside.managed=true \
        --filter label=com.reside.kind=game-server \
        --filter "label=com.reside.deployment-id=$deployment_id" >"$managed_ids_path"; then
        echo "ERROR: Docker failed to list API-managed game servers." >&2
        exit 1
    fi
    while IFS= read -r container_id || [ -n "$container_id" ]; do
        [ -n "$container_id" ] || continue
        if ! docker stop --time 30 "$container_id" >/dev/null; then
            echo "ERROR: Docker failed to stop managed game-server container $container_id." >&2
            exit 1
        fi
        networks=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$container_id") || exit 1
        case "$networks" in
            *\"$deployment_network\"*)
                if ! docker network disconnect "$deployment_network" "$container_id"; then
                    echo "ERROR: Docker failed to disconnect $container_id from $deployment_network." >&2
                    exit 1
                fi
                ;;
        esac
    done <"$managed_ids_path"
    if ! docker ps --all --quiet \
        --filter label=com.reside.managed=true \
        --filter label=com.reside.kind=game-server \
        --filter "label=com.reside.deployment-id=$deployment_id" >"$managed_ids_path"; then
        echo "ERROR: Docker failed to verify managed game-server cleanup." >&2
        exit 1
    fi
    connected=false
    while IFS= read -r container_id || [ -n "$container_id" ]; do
        [ -n "$container_id" ] || continue
        networks=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$container_id") || exit 1
        case "$networks" in *\"$deployment_network\"*) connected=true ;; esac
    done <"$managed_ids_path"
    if [ "$connected" = false ]; then
        cleanup_succeeded=true
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done
if [ "$cleanup_succeeded" != true ]; then
    remaining_ids=$(tr '\n' ' ' <"$managed_ids_path")
    echo "ERROR: Managed game-server disconnect failed for deployment '$deployment_id': $remaining_ids" >&2
    echo "Core services were not removed." >&2
    exit 1
fi

while IFS= read -r container_id || [ -n "$container_id" ]; do
    [ -n "$container_id" ] && docker unpause "$container_id" >/dev/null
done <"$paused_ids_path"
: >"$paused_ids_path"

echo "Stopping the ReSide core services..."
docker compose --env-file "$ENVIRONMENT_PATH" --file "$COMPOSE_PATH" down
echo "ReSide services stopped."
