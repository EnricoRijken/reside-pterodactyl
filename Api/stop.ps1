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
    throw "docker-compose.yml was not found in or above $PSScriptRoot. Re-extract the complete API release folder."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is not installed or is not available on PATH."
}

$ComposePath = Join-Path $PackageDirectory "docker-compose.yml"
$EnvironmentPath = Join-Path $PackageDirectory ".env"
if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) {
    throw ".env was not found in $PackageDirectory; refusing an unscoped stop."
}
$DeploymentIdLine = Get-Content -LiteralPath $EnvironmentPath | Where-Object { $_ -match '^DEPLOYMENT_ID=' } | Select-Object -First 1
if (-not $DeploymentIdLine) {
    throw "DEPLOYMENT_ID is missing from $EnvironmentPath; refusing to stop an unscoped deployment."
}
$DeploymentId = $DeploymentIdLine.Substring("DEPLOYMENT_ID=".Length).Trim()
if ($DeploymentId -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    throw "DEPLOYMENT_ID in $EnvironmentPath is invalid."
}
$DeploymentNetwork = "reside_${DeploymentId}_backend"

function Get-DockerIds {
    param([Parameter(Mandatory)][string[]] $Arguments)

    # Materialize one trimmed ID per array element; Windows PowerShell otherwise
    # makes zero, one, and many lines behave differently at native call sites.
    [string[]] $Ids = @(docker @Arguments | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed while querying deployment containers (exit code $LASTEXITCODE)."
    }
    return $Ids
}

# Freeze the manager while managed servers are stopped and detached.
Write-Host "Quiescing the ReSide server manager..." -ForegroundColor Cyan
[string[]] $ApiContainers = @(Get-DockerIds @("compose", "--env-file", $EnvironmentPath, "--file", $ComposePath, "ps", "--all", "--quiet", "api"))
$PausedApiContainers = @()
try {
foreach ($ContainerId in $ApiContainers) {
    $Quiesced = $false
    for ($Attempt = 1; $Attempt -le 15; $Attempt++) {
        $State = docker inspect --format '{{.State.Status}} {{.State.Paused}}' $ContainerId
        if ($LASTEXITCODE -ne 0) {
            throw "Docker failed to inspect API container $ContainerId (exit code $LASTEXITCODE)."
        }
        if ($State -eq "running false") {
            docker pause $ContainerId | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $PausedApiContainers += $ContainerId
                $Quiesced = $true
                break
            }
        }
        elseif ($State -eq "running true" -or $State -match '^(created|exited|dead) ') {
            $Quiesced = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $Quiesced) {
        throw "API container $ContainerId could not be quiesced after 15 seconds; managed-server cleanup cannot be made reliable."
    }
}

$ManagedFilterArguments = @(
    "ps", "--all", "--quiet",
    "--filter", "label=com.reside.managed=true",
    "--filter", "label=com.reside.kind=game-server",
    "--filter", "label=com.reside.deployment-id=$DeploymentId"
)
Write-Host "Stopping API-managed game servers..." -ForegroundColor Cyan
$CleanupSucceeded = $false
for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
    [string[]] $ManagedContainers = @(Get-DockerIds $ManagedFilterArguments)
    foreach ($ContainerId in $ManagedContainers) {
        docker stop --time 30 $ContainerId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Docker failed to stop managed game-server container $ContainerId (exit code $LASTEXITCODE)."
        }
        $Networks = docker inspect --format '{{json .NetworkSettings.Networks}}' $ContainerId
        if ($LASTEXITCODE -ne 0) {
            throw "Docker failed to inspect managed game-server container $ContainerId (exit code $LASTEXITCODE)."
        }
        if ($Networks -match ('"' + [regex]::Escape($DeploymentNetwork) + '"')) {
            docker network disconnect $DeploymentNetwork $ContainerId
            if ($LASTEXITCODE -ne 0) {
                throw "Docker failed to disconnect managed game-server container $ContainerId from $DeploymentNetwork (exit code $LASTEXITCODE)."
            }
        }
    }
    [string[]] $RemainingContainers = @($ManagedContainers | Where-Object {
        (docker inspect --format '{{json .NetworkSettings.Networks}}' $_) -match ('"' + [regex]::Escape($DeploymentNetwork) + '"')
    })
    if ($RemainingContainers.Count -eq 0) {
        $CleanupSucceeded = $true
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $CleanupSucceeded) {
    throw "Managed game-server disconnect failed for deployment '$DeploymentId': $($RemainingContainers -join ', '). Core services were not removed."
}
}
finally {
    foreach ($ContainerId in $PausedApiContainers) {
        $Unpaused = $false
        for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
            docker unpause $ContainerId | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $Unpaused = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $Unpaused) {
            Write-Warning "API container $ContainerId could not be unpaused; inspect it before retrying."
        }
    }
}

Write-Host "Stopping the ReSide core services..." -ForegroundColor Cyan
docker compose --env-file $EnvironmentPath --file $ComposePath down
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose failed to stop the services (exit code $LASTEXITCODE)."
}

Write-Host "ReSide services stopped." -ForegroundColor Green
