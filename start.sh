#!/usr/bin/env sh
# Starts the packaged ReSide core services and opens the admin panel on Linux.

set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
API_LAUNCHER="$SCRIPT_DIRECTORY/Api/run.sh"

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
    else
        return 1
    fi
}

env_value() {
    key=$1
    default=$2
    environment_path="$SCRIPT_DIRECTORY/Api/.env"
    [ -f "$environment_path" ] || { printf '%s' "$default"; return 0; }
    value=$(sed -n "s/^$key=//p" "$environment_path" | head -n 1)
    if [ -z "$value" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

config_value() {
    key=$1
    default=$2
    value=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$SCRIPT_DIRECTORY/config.toml" | head -n 1 | tr -d '\r')
    case "$value" in "\""*"\"") value=${value#\"}; value=${value%\"} ;; esac
    if [ -z "$value" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

set_config_value() {
    key=$1
    value=$2
    kind=$3
    if [ "$kind" = string ]; then rendered="\"$value\""; else rendered=$value; fi
    awk -v key="$key" -v rendered="$rendered" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!found) print key " = " rendered; found = 1; next }
        { print }
        END { if (!found) exit 2 }
    ' "$SCRIPT_DIRECTORY/config.toml" > "$SCRIPT_DIRECTORY/config.toml.tmp" || {
        rm -f "$SCRIPT_DIRECTORY/config.toml.tmp"
        echo "ERROR: $key is missing from config.toml. Restore it from the package." >&2
        exit 1
    }
    mv "$SCRIPT_DIRECTORY/config.toml.tmp" "$SCRIPT_DIRECTORY/config.toml"
}

set_env_value() {
    key=$1
    value=$2
    environment_path="$SCRIPT_DIRECTORY/Api/.env"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { if (!found) print key "=" value; found = 1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$environment_path" > "$environment_path.tmp"
    mv "$environment_path.tmp" "$environment_path"
}

sync_hosting_config() {
    mode=$(config_value hosting_mode '')
    address=$(config_value advertised_address '')
    port_min=$(config_value game_port_min 0)
    port_max=$(config_value game_port_max 0)
    public_api_url=$(config_value public_api_url '')
    case "$mode" in lan|public|private|custom) ;; *) echo "ERROR: hosting_mode in config.toml must be lan, public, private, or custom." >&2; exit 1 ;; esac
    case "$mode:$address" in
        lan:AUTO_DETECT|lan:127.0.0.1|lan:localhost)
            address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)
            [ -n "$address" ] || address=$(ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, item, "/"); print item[1]; exit }' || true)
            [ -n "$address" ] || { echo "ERROR: No LAN IPv4 address was detected. Set advertised_address in config.toml manually." >&2; exit 1; }
            set_config_value advertised_address "$address" string
            ;;
    esac
    case "$address" in ""|AUTO_DETECT|127.0.0.1|localhost|*://*|*/*|*\\*) echo "ERROR: advertised_address in config.toml must be a reachable IP address or DNS name without a scheme, port, or path." >&2; exit 1 ;; esac
    case "$port_min:$port_max" in *[!0-9:]*|:*) echo "ERROR: Game ports in config.toml must be whole numbers." >&2; exit 1 ;; esac
    if [ "$port_min" -lt 1 ] || [ "$port_max" -gt 65535 ] || [ "$port_min" -gt "$port_max" ]; then
        echo "ERROR: Game ports in config.toml must be between 1 and 65535, with the minimum first." >&2
        exit 1
    fi
    set_env_value SERVER_MANAGER_HOSTING_MODE "$mode"
    set_env_value SERVER_MANAGER_ADVERTISED_ADDRESS "$address"
    set_env_value SERVER_MANAGER_PORT_MIN "$port_min"
    set_env_value SERVER_MANAGER_PORT_MAX "$port_max"
    set_env_value SERVER_MANAGER_PUBLIC_API_URL "$public_api_url"
}

read_host_address() {
    prompt=$1
    while :; do
        printf '%s: ' "$prompt" >&2
        IFS= read -r value
        case "$value" in
            ""|*://*|*/*|*\\*) echo "Enter only an IP address or DNS name, without http://, a port, or a path." >&2 ;;
            *) printf '%s' "$value"; return 0 ;;
        esac
    done
}

configure_hosting_mode() {
    echo "[1/4] Choose who can join"
    echo "  1. Local network (LAN)"
    echo "  2. Public internet"
    echo "  3. Private network or VPN"
    echo "  4. Custom setup"
    while :; do
        printf 'Select 1-4 [1]: '
        IFS= read -r choice
        choice=${choice:-1}
        case "$choice" in 1|2|3|4) break ;; *) echo "Choose 1, 2, 3, or 4." ;; esac
    done
    case "$choice" in
        1)
            address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)
            [ -n "$address" ] || address=$(ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, item, "/"); print item[1]; exit }' || true)
            [ -n "$address" ] || { echo "ERROR: No LAN IPv4 address was detected. Choose Custom setup and enter an address manually." >&2; exit 1; }
            set_config_value advertised_address "$address" string
            set_config_value hosting_mode lan string
            echo "LAN hosting selected: $address"
            echo "This address applies to every existing and future managed world."
            echo "Players on this network can discover ReSide automatically."
            ;;
        2)
            address=$(read_host_address "Public IP or DNS name")
            set_config_value advertised_address "$address" string
            set_config_value hosting_mode public string
            echo "Public hosting selected: $address"
            echo "This address applies to every existing and future managed world."
            echo "Your router must forward TCP 3000 and the game-server UDP ports to this computer."
            ;;
        3)
            address=$(read_host_address "This computer's VPN IP or DNS name")
            set_config_value advertised_address "$address" string
            set_config_value hosting_mode private string
            echo "Private/VPN hosting selected: $address"
            echo "This address applies to every existing and future managed world."
            echo "Every player must join the same VPN."
            ;;
        4)
            set_config_value hosting_mode custom string
            current_address=$(config_value advertised_address AUTO_DETECT)
            printf 'Advertised IP or DNS name [%s]: ' "$current_address"
            IFS= read -r address
            case "$current_address:$address" in
                AUTO_DETECT:|127.0.0.1:|localhost:) address=$(read_host_address "Advertised IP or DNS name") ;;
            esac
            if [ -n "$address" ]; then
                case "$address" in *://*|*/*|*\\*) echo "ERROR: Advertised address must be an IP address or DNS name without a scheme, port, or path." >&2; exit 1 ;; esac
                set_config_value advertised_address "$address" string
            fi
            current_min=$(config_value game_port_min 7777)
            current_max=$(config_value game_port_max 7877)
            printf 'First game UDP port [%s]: ' "$current_min"
            IFS= read -r port_min
            printf 'Last game UDP port [%s]: ' "$current_max"
            IFS= read -r port_max
            selected_min=${port_min:-$current_min}
            selected_max=${port_max:-$current_max}
            case "$selected_min:$selected_max" in *[!0-9:]*|:*) echo "ERROR: Game ports must be whole numbers." >&2; exit 1 ;; esac
            if [ "$selected_min" -lt 1 ] || [ "$selected_max" -gt 65535 ] || [ "$selected_min" -gt "$selected_max" ]; then
                echo "ERROR: Game ports must be between 1 and 65535, and the first port cannot exceed the last port." >&2
                exit 1
            fi
            set_config_value game_port_min "$selected_min" number
            set_config_value game_port_max "$selected_max" number
            echo "Custom settings saved in config.toml for every managed world."
            ;;
    esac
}

configure_firewall() {
    game_port_min=$1
    game_port_max=$2
    game_port_range="$game_port_min-$game_port_max"
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for port in 3000/tcp 3002/udp "$game_port_range/udp"; do
            if ! firewall-cmd --query-port="$port" >/dev/null 2>&1; then
                if ! run_privileged firewall-cmd --permanent --add-port="$port" >/dev/null 2>&1; then
                    echo "WARNING: Could not configure firewalld without privilege. Allow inbound TCP 3000, UDP 3002, and UDP $game_port_range from the trusted LAN manually. Startup will continue." >&2
                    return 0
                fi
            fi
        done
        run_privileged firewall-cmd --reload >/dev/null 2>&1 || true
        echo "firewalld allows ReSide TCP 3000, UDP 3002, and UDP $game_port_range."
    elif command -v ufw >/dev/null 2>&1; then
        if ! run_privileged ufw allow 3000/tcp comment "ReSide Backend Gateway" >/dev/null 2>&1 ||
           ! run_privileged ufw allow 3002/udp comment "ReSide Backend Discovery" >/dev/null 2>&1 ||
           ! run_privileged ufw allow "$game_port_min:$game_port_max/udp" comment "ReSide Managed Game Servers" >/dev/null 2>&1; then
            echo "WARNING: Could not configure ufw without privilege. Allow inbound TCP 3000, UDP 3002, and UDP $game_port_range from the trusted LAN manually. Startup will continue." >&2
            return 0
        fi
        echo "ufw rules allow ReSide TCP 3000, UDP 3002, and UDP $game_port_range (rules are not duplicated by ufw)."
    else
        echo "No supported host firewall tool detected. If a firewall is active, allow inbound TCP 3000, UDP 3002, and UDP $game_port_range from the trusted LAN."
    fi
}

if [ ! -f "$API_LAUNCHER" ]; then
    echo "ERROR: Api/run.sh is missing." >&2
    echo "Extract the complete ReSide backend package before running this launcher." >&2
    exit 1
fi
if [ ! -f "$SCRIPT_DIRECTORY/Api/.env" ]; then
    echo "ERROR: Api/.env is missing." >&2
    echo "Extract the complete ReSide backend package before running this launcher." >&2
    exit 1
fi
if [ ! -f "$SCRIPT_DIRECTORY/config.toml" ]; then
    echo "ERROR: config.toml is missing." >&2
    echo "Extract the complete ReSide backend package before running this launcher." >&2
    exit 1
fi
if [ -t 0 ]; then
    configure_hosting_mode
else
    echo "[1/4] Using the saved hosting settings (non-interactive start)"
fi
sync_hosting_config
echo "[2/4] Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker Engine is not installed or is not available on PATH." >&2
    echo "Install Docker Engine from https://docs.docker.com/engine/install/ and try again." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running or your user cannot access its socket." >&2
    echo "Start Docker and grant this operator account Docker access, then try again." >&2
    exit 1
fi

# Api/run.sh detects and writes SERVER_MANAGER_ADVERTISED_ADDRESS itself, so a deployment started
# from that script directly cannot silently advertise loopback. Only the host-level firewall work,
# which needs privilege, stays here.
game_port_min=$(config_value game_port_min 7777)
game_port_max=$(config_value game_port_max 7877)
echo "[3/4] Configuring network access"
configure_firewall "$game_port_min" "$game_port_max"
echo "[4/4] Starting ReSide services"
sh "$API_LAUNCHER" --host-firewall-configured
echo "Create and control Linux game servers from http://localhost:3000/admin/."
admin_api_token=$(sed -n 's/^ADMIN_API_TOKEN=//p' "$SCRIPT_DIRECTORY/Api/.env" | head -n 1)
if [ -z "$admin_api_token" ]; then
    echo "ERROR: ADMIN_API_TOKEN is missing from $SCRIPT_DIRECTORY/Api/.env." >&2
    exit 1
fi
echo
echo "Admin API token:"
echo "$admin_api_token"
echo "Enter this token when the admin panel prompts for it. Keep it private."
lan_address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)
if [ -n "$lan_address" ]; then
    echo "LAN API URL:   http://$lan_address:3000/api"
    echo "LAN admin URL: http://$lan_address:3000/admin/"
fi
echo "Use these HTTP URLs only on a trusted LAN or VPN. Do not enter the token over an untrusted plaintext network."
