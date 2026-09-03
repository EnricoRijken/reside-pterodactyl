[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageDirectory = @(
    $PSScriptRoot
    (Split-Path -Parent $PSScriptRoot)
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
) | Where-Object { Test-Path -LiteralPath (Join-Path $_ "docker-compose.yml") -PathType Leaf } | Select-Object -First 1
if (-not $PackageDirectory) {
    throw "docker-compose.yml was not found in or above $PSScriptRoot."
}
$ComposePath = Join-Path $PackageDirectory "docker-compose.yml"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is not installed or is not available on PATH."
}

Write-Host "Stopping the API container..." -ForegroundColor Yellow
docker compose --file $ComposePath stop api
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stop the API container (exit code $LASTEXITCODE)."
}

try {
    Write-Host "Dropping and recreating the reside database..." -ForegroundColor Yellow
    docker compose --file $ComposePath exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'reside' AND pid <> pg_backend_pid();"
    if ($LASTEXITCODE -ne 0) { throw "Failed to terminate database connections." }
    docker compose --file $ComposePath exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS reside;"
    if ($LASTEXITCODE -ne 0) { throw "Failed to drop the database." }
    docker compose --file $ComposePath exec --no-TTY db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE reside;"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the database." }
}
finally {
    Write-Host "Starting the API container..." -ForegroundColor Yellow
    docker compose --file $ComposePath start api
}

Write-Host "Database reset complete. The API will apply migrations during startup." -ForegroundColor Green
