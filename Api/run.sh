#!/usr/bin/env sh

set -eu

# --host-firewall-configured is passed by the package-root start launcher, which sets up the host
# firewall itself. Running this script directly leaves those rules unset, so the operator is told so
# rather than finding out when a remote client cannot connect.
HOST_FIREWALL_CONFIGURED=0
for argument in "$@"; do
    case "$argument" in
        --host-firewall-configured) HOST_FIREWALL_CONFIGURED=1 ;;
        *) echo "ERROR: unknown argument: $argument" >&2; exit 1 ;;
    esac
done

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
IMAGE_ARCHIVE_PATH="$PACKAGE_DIRECTORY/reside-images.tar"

if [ ! -f "$COMPOSE_PATH" ]; then
    echo "ERROR: docker-compose.yml was not found in or above $SCRIPT_DIRECTORY."
    echo "Re-extract the complete API release folder."
    exit 1
fi
if [ ! -f "$IMAGE_ARCHIVE_PATH" ]; then
    echo "ERROR: reside-images.tar was not found in $PACKAGE_DIRECTORY."
    echo "Re-extract the complete API release folder."
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or is not available on PATH."
    exit 1
fi

# Compose reads SERVER_MANAGER_ADVERTISED_ADDRESS from .env at "up" time, so this has to happen here
# rather than only in the package-root launcher. A deployment started straight from this script would
# otherwise advertise the packaged 127.0.0.1 default, and every game server it creates would be
# unreachable off-host with nothing in the output saying so.
configure_advertised_address() {
    [ -f "$ENVIRONMENT_PATH" ] || return 0
    current=$(sed -n 's/^SERVER_MANAGER_ADVERTISED_ADDRESS=//p' "$ENVIRONMENT_PATH" | head -n 1 | tr -d '\r')
    case "$current" in
        ""|AUTO_DETECT|127.0.0.1|localhost) ;;
        *) echo "Using operator-configured game-server address: $current"; return 0 ;;
    esac
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    if [ -z "$detected" ]; then
        detected=$(ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, address, "/"); print address[1]; exit }')
    fi
    if [ -z "$detected" ]; then
        echo "WARNING: No non-loopback IPv4 address was detected; configure SERVER_MANAGER_ADVERTISED_ADDRESS in $ENVIRONMENT_PATH before creating servers." >&2
        return 0
    fi
    if grep -q '^SERVER_MANAGER_ADVERTISED_ADDRESS=' "$ENVIRONMENT_PATH"; then
        sed "s/^SERVER_MANAGER_ADVERTISED_ADDRESS=.*/SERVER_MANAGER_ADVERTISED_ADDRESS=$detected/" "$ENVIRONMENT_PATH" > "$ENVIRONMENT_PATH.tmp"
        mv "$ENVIRONMENT_PATH.tmp" "$ENVIRONMENT_PATH"
    else
        printf '
SERVER_MANAGER_ADVERTISED_ADDRESS=%s
' "$detected" >> "$ENVIRONMENT_PATH"
    fi
    if grep -q '^SERVER_MANAGER_HOSTING_MODE=' "$ENVIRONMENT_PATH"; then
        sed 's/^SERVER_MANAGER_HOSTING_MODE=.*/SERVER_MANAGER_HOSTING_MODE=lan/' "$ENVIRONMENT_PATH" > "$ENVIRONMENT_PATH.tmp"
        mv "$ENVIRONMENT_PATH.tmp" "$ENVIRONMENT_PATH"
    else
        printf 'SERVER_MANAGER_HOSTING_MODE=lan\n' >> "$ENVIRONMENT_PATH"
    fi
    echo "Detected game-server address: $detected"
    echo "This usually works for LAN clients. VPN clients may need the VPN address; internet clients need a public DNS/IP plus UDP port forwarding and firewall rules."
}

echo "Loading the packaged ReSide images..."
docker load --input "$IMAGE_ARCHIVE_PATH"

configure_advertised_address
if [ "$HOST_FIREWALL_CONFIGURED" -eq 0 ]; then
    echo "Host firewall rules were not configured. Run the package-root start launcher instead of this script to open TCP 3000, UDP 3002, and the managed game-server UDP range, or add those rules by hand before remote clients connect."
fi

echo "Starting the ReSide core services..."
docker compose --env-file "$ENVIRONMENT_PATH" --file "$COMPOSE_PATH" up --detach --no-build

api_is_ready() {
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --max-time 3 http://127.0.0.1:3001/api/ >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --timeout=3 --output-document=/dev/null http://127.0.0.1:3001/api/ >/dev/null 2>&1
    else
        echo "ERROR: curl or wget is required for the API readiness check." >&2
        exit 1
    fi
}

echo "Waiting for the API to become ready..."
attempt=0
until api_is_ready; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "ERROR: The core services started, but the API did not become ready." >&2
        exit 1
    fi
    sleep 2
done

ADMIN_API_TOKEN=$(sed -n 's/^ADMIN_API_TOKEN=//p' "$ENVIRONMENT_PATH" | head -n 1 | tr -d '\r')
if [ -z "$ADMIN_API_TOKEN" ]; then
    echo "ERROR: ADMIN_API_TOKEN is missing from $ENVIRONMENT_PATH; managed game servers were not reconciled." >&2
    exit 1
fi
echo "Reconciling managed game servers..."
if command -v curl >/dev/null 2>&1; then
    if ! RECONCILE_RESPONSE=$(curl --fail --silent --show-error --max-time 600 --request POST --header "Authorization: Bearer $ADMIN_API_TOKEN" http://127.0.0.1:3001/api/server-instances/reconcile); then
        echo "ERROR: The API is ready, but managed game-server reconciliation failed." >&2
        exit 1
    fi
else
    if ! RECONCILE_RESPONSE=$(wget --quiet --timeout=600 --post-data='' --header="Authorization: Bearer $ADMIN_API_TOKEN" --output-document=- http://127.0.0.1:3001/api/server-instances/reconcile); then
        echo "ERROR: The API is ready, but managed game-server reconciliation failed." >&2
        exit 1
    fi
fi
if ! printf '%s' "$RECONCILE_RESPONSE" | grep -Eq '"failures"[[:space:]]*:[[:space:]]*0([,}])'; then
    echo "ERROR: Managed game-server reconciliation reported failures. No Saved volumes were removed." >&2
    printf '%s\n' "$RECONCILE_RESPONSE" >&2
    exit 1
fi
printf '%s\n' "$RECONCILE_RESPONSE"

echo
echo "Admin panel: http://localhost:3000/admin/"
echo "API docs:    http://localhost:3000/docs/"
echo "Admin token: open $ENVIRONMENT_PATH and use the ADMIN_API_TOKEN value."
if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open http://localhost:3000/admin/ >/dev/null 2>&1 || true
elif command -v open >/dev/null 2>&1; then
    open http://localhost:3000/admin/ >/dev/null 2>&1 || true
fi
