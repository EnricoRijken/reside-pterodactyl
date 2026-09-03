#!/bin/bash
set -euo pipefail

cd /mnt/server

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends git ca-certificates

if [ -d .git ]; then
  git fetch --depth 1 origin main
  git reset --hard origin/main
else
  git clone --depth 1 --branch main https://github.com/EnricoRijken/reside-pterodactyl.git .
fi

chmod +x start.sh stop.sh start.ps1 stop.ps1 start.bat stop.bat       CollectLogs.sh CollectLogs.ps1 CollectLogs.bat       Api/run.sh Api/stop.sh Api/reset-database.sh       scripts/entrypoint.sh

mkdir -p logs
