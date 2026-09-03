#!/usr/bin/env bash

set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    DIM=$'\033[2m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED= GREEN= YELLOW= CYAN= DIM= BOLD= RESET=
fi

info() {
    printf '%b[INFO]%b %s\n' "$CYAN" "$RESET" "$1"
}

success() {
    printf '%b[ OK ]%b %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1" >&2
}

die() {
    printf '\n%b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2
    printf '%bNo support archive was created. Correct the problem above and try again.%b\n' "$YELLOW" "$RESET" >&2
    exit 1
}

printf '\n%b============================================================%b\n' "$CYAN" "$RESET"
printf '%b                 ReSide Log Collector%b\n' "$BOLD$CYAN" "$RESET"
printf '%b============================================================%b\n' "$CYAN" "$RESET"
printf '%bCollects ReSide logs into one support archive.%b\n\n' "$DIM" "$RESET"

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$SCRIPT_DIRECTORY
REPOSITORY_VERSION_FILE="$REPO_ROOT/ReSide/Config/DefaultGame.ini"
PACKAGED_VERSION_FILE="$REPO_ROOT/Version.txt"

info "Reading ReSide version information..."
IS_REPOSITORY=false
if [[ -f "$REPOSITORY_VERSION_FILE" ]]; then
    IS_REPOSITORY=true
    VERSION=$(sed -n 's/^[[:space:]]*ProjectVersion[[:space:]]*=[[:space:]]*//p' "$REPOSITORY_VERSION_FILE" |
        sed -n "1{s/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//; p;}")
elif [[ -f "$PACKAGED_VERSION_FILE" ]]; then
    VERSION=$(sed -n "1{s/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//; p;}" "$PACKAGED_VERSION_FILE")
else
    die "Version metadata was not found beside the collector. Re-extract the complete ReSide package."
fi

VERSION=${VERSION#\"}
VERSION=${VERSION%\"}
VERSION=${VERSION#\'}
VERSION=${VERSION%\'}

if [[ -z "$VERSION" || ! "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    die "ProjectVersion '$VERSION' cannot be used in an archive file name."
fi
success "Version: $VERSION"
if $IS_REPOSITORY; then
    info "Mode: development repository"
else
    info "Mode: extracted release package"
fi

if command -v zip >/dev/null 2>&1; then
    ARCHIVER=zip
elif command -v python3 >/dev/null 2>&1; then
    ARCHIVER=python
    PYTHON_COMMAND=python3
elif command -v python >/dev/null 2>&1; then
    ARCHIVER=python
    PYTHON_COMMAND=python
else
    die "The 'zip' command or Python is required to collect logs."
fi
success "Archive tool: $ARCHIVER"

TIMESTAMP=$(date '+%Y%m%d%H%M%S')
ARCHIVE_PATH="$REPO_ROOT/ReSide-$VERSION-logs-$TIMESTAMP.zip"
if [[ -e "$ARCHIVE_PATH" ]]; then
    die "Archive already exists: $ARCHIVE_PATH"
fi
info "Archive destination: $ARCHIVE_PATH"

DOCKER_LOG_FILE=
if $IS_REPOSITORY && [[ -d "$REPO_ROOT/Logs" ]]; then
    COLLECTOR_DIAGNOSTICS_LOG="$REPO_ROOT/Logs/collector-diagnostics-$$-$TIMESTAMP.log"
else
    COLLECTOR_DIAGNOSTICS_LOG="$REPO_ROOT/collector-diagnostics-$$-$TIMESTAMP.log"
fi
# Every log captured from Docker rather than from disk is written beside the package so the archive
# builder below picks it up, then removed on the way out.
GAME_SERVER_LOG_FILES=()
ZIP_STAGING_DIRECTORY=
cleanup() {
    if [[ -n "$DOCKER_LOG_FILE" && -f "$DOCKER_LOG_FILE" ]]; then
        rm -f -- "$DOCKER_LOG_FILE"
    fi
    rm -f -- "$COLLECTOR_DIAGNOSTICS_LOG"
    if (( ${#GAME_SERVER_LOG_FILES[@]} > 0 )); then
        rm -f -- "${GAME_SERVER_LOG_FILES[@]}"
    fi
    if [[ -n "$ZIP_STAGING_DIRECTORY" && -d "$ZIP_STAGING_DIRECTORY" ]]; then
        rm -rf -- "$ZIP_STAGING_DIRECTORY"
    fi
}
trap cleanup EXIT

cat >"$COLLECTOR_DIAGNOSTICS_LOG" <<EOF
ReSide log collector diagnostics
Timestamp: $(date -Iseconds)
Version: $VERSION
Mode: $(if $IS_REPOSITORY; then printf 'development repository'; else printf 'extracted release package'; fi)
Platform: $(uname -a)
Docker command available: $(if command -v docker >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)
EOF

if ! $IS_REPOSITORY && [[ -f "$REPO_ROOT/Api/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    info "Capturing Docker Compose logs from the API stack..."
    DOCKER_LOG_FILE="$REPO_ROOT/Api/docker-compose-collector-$$-$TIMESTAMP.log"
    COMPOSE_LOG_ARGUMENTS=(--file "$REPO_ROOT/Api/docker-compose.yml")
    if [[ -f "$REPO_ROOT/Api/.env" ]]; then
        COMPOSE_LOG_ARGUMENTS+=(--env-file "$REPO_ROOT/Api/.env")
    fi
    if ! docker compose "${COMPOSE_LOG_ARGUMENTS[@]}" logs --no-color >"$DOCKER_LOG_FILE" 2>&1; then
        warn "Docker Compose logs could not be collected; the Docker error will be included in the archive."
    else
        success "Docker Compose output captured."
    fi

    # The worlds an operator actually needs logs for are not Compose services: the API's server
    # manager creates one container per hosted server, so "docker compose logs" never sees them.
    # Collect them by their manager labels instead, including exited ones, whose logs are the whole
    # point of a support archive after a crash.
    info "Capturing logs from API-managed game servers..."
    MANAGED_FILTERS=(
        --filter label=com.reside.managed=true
        --filter label=com.reside.kind=game-server
    )
    if [[ -f "$REPO_ROOT/Api/.env" ]]; then
        DEPLOYMENT_ID=$(sed -n 's/^DEPLOYMENT_ID=//p' "$REPO_ROOT/Api/.env" | head -n 1 | tr -d '[:space:]')
        if [[ "$DEPLOYMENT_ID" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
            MANAGED_FILTERS+=(--filter "label=com.reside.deployment-id=$DEPLOYMENT_ID")
        else
            printf '\nManaged-container query skipped: DEPLOYMENT_ID is not safe to use as a Docker label filter.\n' >>"$COLLECTOR_DIAGNOSTICS_LOG"
            MANAGED_FILTERS=()
        fi
    fi
    if (( ${#MANAGED_FILTERS[@]} > 0 )); then
        if ! MANAGED_CONTAINERS=$(docker ps --all --no-trunc --format '{{.ID}} {{.Names}}' "${MANAGED_FILTERS[@]}" 2>>"$COLLECTOR_DIAGNOSTICS_LOG"); then
            warn "API-managed game-server containers could not be listed; the Docker error will be included in the archive."
            MANAGED_CONTAINERS=
        fi
    else
        MANAGED_CONTAINERS=
    fi
    if [[ -z "$MANAGED_CONTAINERS" ]]; then
        printf '%b[SKIP]%b %s
' "$YELLOW" "$RESET" "No API-managed game-server containers were found."
    else
        while read -r container_id container_name; do
            [[ -n "$container_id" ]] || continue
            safe_name=$(printf '%s' "$container_name" | tr -c 'A-Za-z0-9._-' '_')
            container_log_file="$REPO_ROOT/Api/game-server-$safe_name-collector-$$-$TIMESTAMP.log"
            GAME_SERVER_LOG_FILES+=("$container_log_file")
            if ! docker logs --timestamps "$container_id" >"$container_log_file" 2>&1; then
                warn "Logs for game-server container $container_name could not be collected; the Docker error will be included."
                continue
            fi
            success "Captured game-server logs: $container_name"
        done <<< "$MANAGED_CONTAINERS"
    fi
elif ! $IS_REPOSITORY && [[ -f "$REPO_ROOT/Api/docker-compose.yml" ]]; then
    warn "Docker is not available; collecting log files on disk only."
    printf '\nDocker diagnostics unavailable: the docker command was not found.\n' >>"$COLLECTOR_DIAGNOSTICS_LOG"
fi

if $IS_REPOSITORY; then
    COLLECTION_ROOTS=()
    for candidate in Logs ReSide reside-api-rs reside-admin-panel; do
        if [[ -d "$REPO_ROOT/$candidate" ]]; then
            COLLECTION_ROOTS+=("$candidate")
        fi
    done
else
    COLLECTION_ROOTS=(.)

    CLIENT_DATA_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}
    EXTERNAL_CLIENT_LOG_ROOT="$CLIENT_DATA_ROOT/ReSide/Saved/Logs"
    if [[ -d "$EXTERNAL_CLIENT_LOG_ROOT" ]]; then
        COLLECTION_ROOTS+=("$EXTERNAL_CLIENT_LOG_ROOT")
    fi
fi

if [[ ${#COLLECTION_ROOTS[@]} -eq 0 ]]; then
    die "No ReSide project directories were found below $REPO_ROOT."
fi

info "Searching for log files in:"
for collection_root in "${COLLECTION_ROOTS[@]}"; do
    if [[ "$collection_root" == . ]]; then
        display_root=$REPO_ROOT
    else
        display_root="$REPO_ROOT/$collection_root"
    fi
    printf '       %b%s%b\n' "$DIM" "$display_root" "$RESET"
done

ADDED_COUNT=0
SKIPPED_COUNT=0
shopt -s nocasematch

cd -- "$REPO_ROOT"
add_to_archive() {
    local log_file=$1
    local archive_path=$log_file
    if [[ -n "${EXTERNAL_CLIENT_LOG_ROOT:-}" && "$log_file" == "$EXTERNAL_CLIENT_LOG_ROOT/"* ]]; then
        archive_path="Client/Saved/Logs/${log_file#"$EXTERNAL_CLIENT_LOG_ROOT/"}"
    fi
    if [[ "$ARCHIVER" == zip ]]; then
        if [[ "$archive_path" == "$log_file" ]]; then
            zip -q "$ARCHIVE_PATH" "$log_file"
        else
            if [[ -z "$ZIP_STAGING_DIRECTORY" ]]; then
                ZIP_STAGING_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/reside-logs.XXXXXX")
            fi
            mkdir -p -- "$ZIP_STAGING_DIRECTORY/$(dirname -- "$archive_path")"
            cp -- "$log_file" "$ZIP_STAGING_DIRECTORY/$archive_path"
            (cd -- "$ZIP_STAGING_DIRECTORY" && zip -q "$ARCHIVE_PATH" "$archive_path")
        fi
    else
        "$PYTHON_COMMAND" - "$ARCHIVE_PATH" "$log_file" "$archive_path" <<'PYTHON'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED) as archive:
    archive.write(sys.argv[2], sys.argv[3])
PYTHON
    fi
}

LOG_FILES=()
while IFS= read -r LOG_FILE; do
    LOG_FILE=${LOG_FILE#./}
    case "$LOG_FILE" in
        *.log|*.log.*)
            LOG_FILES+=("$LOG_FILE")
            ;;
    esac
done < <(find "${COLLECTION_ROOTS[@]}" \
    \( -type d \( -name .git -o -name node_modules -o -name target -o -name DerivedDataCache \) -prune \) -o \
    -type f -print)

diagnostics_relative_path=${COLLECTOR_DIAGNOSTICS_LOG#"$REPO_ROOT/"}
if [[ ! " ${LOG_FILES[*]} " =~ " $diagnostics_relative_path " ]]; then
    LOG_FILES+=("$diagnostics_relative_path")
fi

success "Found ${#LOG_FILES[@]} log files."
info "Compressing logs..."
for LOG_FILE in "${LOG_FILES[@]}"; do
    printf '       [%d/%d] %s\n' "$((ADDED_COUNT + SKIPPED_COUNT + 1))" "${#LOG_FILES[@]}" "$LOG_FILE"
    if add_to_archive "$LOG_FILE"; then
        ((ADDED_COUNT += 1))
    else
        warn "Skipping '$REPO_ROOT/$LOG_FILE'."
        ((SKIPPED_COUNT += 1))
    fi
done

if [[ $ADDED_COUNT -eq 0 ]]; then
    rm -f -- "$ARCHIVE_PATH"
    die "None of the discovered log files could be added to the archive."
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | awk '{print $1}')
printf '\n%b============================================================%b\n' "$GREEN" "$RESET"
printf '%b Support archive created successfully%b\n' "$BOLD$GREEN" "$RESET"
printf '%b============================================================%b\n' "$GREEN" "$RESET"
printf '%bArchive:%b   %s\n' "$CYAN" "$RESET" "$ARCHIVE_PATH"
printf '%bSize:%b      %s\n' "$CYAN" "$RESET" "$ARCHIVE_SIZE"
printf '%bCollected:%b %d files\n' "$CYAN" "$RESET" "$ADDED_COUNT"
printf '%bSkipped:%b   %d files\n\n' "$CYAN" "$RESET" "$SKIPPED_COUNT"
printf '%bSend this ZIP with your support request.%b\n' "$YELLOW" "$RESET"
