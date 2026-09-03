#!/usr/bin/env sh
# Stops packaged ReSide services and managed servers while preserving persistent data.

set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STOP_LAUNCHER="$SCRIPT_DIRECTORY/Api/stop.sh"

if [ ! -f "$STOP_LAUNCHER" ]; then
    echo "ERROR: Api/stop.sh is missing." >&2
    echo "Extract the complete ReSide package before running this launcher." >&2
    exit 1
fi

if ! sh "$STOP_LAUNCHER"; then
    echo "ERROR: Api/stop.sh could not stop the complete deployment." >&2
    exit 1
fi
echo "Saved database and game-server data were preserved."
