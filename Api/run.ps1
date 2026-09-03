[CmdletBinding()]
param(
    # Set by the package-root start launcher, which configures the host firewall itself. Running this
    # script directly leaves those rules unset, so the operator is told so rather than finding out
    # when a remote client cannot connect.
    [switch]$HostFirewallConfigured,
    [switch]$RootLauncher
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AdvertisedIPv4Address {
    $Route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne "0.0.0.0" } | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
    if ($Route) {
        return Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $Route.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.AddressState -eq "Preferred" } |
            Select-Object -ExpandProperty IPAddress -First 1
    }
    return Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress -First 1
}

function Set-DefaultAdvertisedAddress {
    # This lives here rather than in the package-root launcher because Compose reads the value from
    # .env at "up" time. A deployment started straight from this script would otherwise advertise the
    # packaged 127.0.0.1 default, and every game server it creates would be unreachable off-host with
    # nothing in the output saying so.
    param([Parameter(Mandatory)][string]$EnvironmentPath)
    if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) { return }
    $Lines = [System.IO.File]::ReadAllLines($EnvironmentPath)
    $Existing = $Lines | Where-Object { $_ -match '^SERVER_MANAGER_ADVERTISED_ADDRESS=' } | Select-Object -First 1
    $Value = if ($Existing) { ($Existing -split '=', 2)[1].Trim() } else { "" }
    if ($Value -and $Value -notin @("AUTO_DETECT", "127.0.0.1", "localhost")) {
        Write-Host "  Game-server address: $Value (configured)" -ForegroundColor Green
        return
    }
    $Detected = Get-AdvertisedIPv4Address
    if (-not $Detected) {
        Write-Warning "No non-loopback IPv4 address was detected; configure SERVER_MANAGER_ADVERTISED_ADDRESS in $EnvironmentPath before creating servers."
        return
    }
    $Replacement = "SERVER_MANAGER_ADVERTISED_ADDRESS=$Detected"
    if ($Existing) { $Lines = $Lines | ForEach-Object { if ($_ -match '^SERVER_MANAGER_ADVERTISED_ADDRESS=') { $Replacement } else { $_ } } }
    else { $Lines += $Replacement }
    $ModeReplacement = "SERVER_MANAGER_HOSTING_MODE=lan"
    if ($Lines | Where-Object { $_ -match '^SERVER_MANAGER_HOSTING_MODE=' } | Select-Object -First 1) {
        $Lines = $Lines | ForEach-Object { if ($_ -match '^SERVER_MANAGER_HOSTING_MODE=') { $ModeReplacement } else { $_ } }
    } else { $Lines += $ModeReplacement }
    [System.IO.File]::WriteAllLines($EnvironmentPath, $Lines)
    Write-Host "  Game-server address: $Detected (LAN detected)" -ForegroundColor Green
    Write-Host "  Public hosting can be configured later from the admin panel." -ForegroundColor DarkGray
}

$PackageDirectory = @(
    $PSScriptRoot
    (Split-Path -Parent $PSScriptRoot)
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
) | Where-Object { Test-Path -LiteralPath (Join-Path $_ "docker-compose.yml") -PathType Leaf } | Select-Object -First 1
if (-not $PackageDirectory) {
    throw "docker-compose.yml was not found in or above $PSScriptRoot. Re-extract the complete API release folder."
}
$ComposePath = Join-Path $PackageDirectory "docker-compose.yml"
$EnvironmentPath = Join-Path $PackageDirectory ".env"
$ImageArchivePath = Join-Path $PackageDirectory "reside-images.tar"

if (-not (Test-Path -LiteralPath $ImageArchivePath -PathType Leaf)) {
    throw "reside-images.tar was not found in $PackageDirectory. Re-extract the complete API release folder."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is not installed or is not available on PATH."
}

Write-Host "  - Loading packaged images..." -ForegroundColor Cyan
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$DockerLoadOutput = @(& docker load --input $ImageArchivePath 2>&1)
$DockerLoadExitCode = $LASTEXITCODE
$ErrorActionPreference = $PreviousErrorActionPreference
if ($DockerLoadExitCode -ne 0) {
    $DockerLoadOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    throw "Docker failed to load the release images (exit code $DockerLoadExitCode)."
}
Write-Host "    Images ready." -ForegroundColor Green

Set-DefaultAdvertisedAddress -EnvironmentPath $EnvironmentPath
if (-not $HostFirewallConfigured) {
    Write-Host "Host firewall rules were not configured. Run the package-root start launcher instead of this script to open TCP 3000, UDP 3002, and the managed game-server UDP range, or add those rules by hand before remote clients connect." -ForegroundColor Yellow
}

Write-Host "  - Starting core services..." -ForegroundColor Cyan
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$ComposeOutput = @(& docker compose --env-file $EnvironmentPath --file $ComposePath up --detach --no-build 2>&1)
$ComposeExitCode = $LASTEXITCODE
$ErrorActionPreference = $PreviousErrorActionPreference
if ($ComposeExitCode -ne 0) {
    $ComposeOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    throw "Docker Compose failed to start the services (exit code $ComposeExitCode)."
}
Write-Host "    Containers started." -ForegroundColor Green

Write-Host "  - Waiting for the API..." -ForegroundColor Cyan
$ApiReady = $false
$Deadline = (Get-Date).AddMinutes(2)
do {
    try {
        $Response = Invoke-WebRequest -Uri "http://127.0.0.1:3001/api/" -UseBasicParsing -TimeoutSec 3
        $ApiReady = $Response.StatusCode -eq 200
    }
    catch {
        Start-Sleep -Seconds 2
    }
} until ($ApiReady -or (Get-Date) -ge $Deadline)
if (-not $ApiReady) {
    throw "The core services started, but the API did not become ready. Run Docker Compose logs or the packaged log collector for details."
}
Write-Host "    API is ready." -ForegroundColor Green

Write-Host "  - Reconciling managed game servers..." -ForegroundColor Cyan
$AdminTokenLine = [System.IO.File]::ReadAllLines($EnvironmentPath) | Where-Object { $_ -match '^ADMIN_API_TOKEN=' } | Select-Object -First 1
$AdminToken = if ($AdminTokenLine) { ($AdminTokenLine -split '=', 2)[1].Trim() } else { "" }
if (-not $AdminToken) {
    throw "ADMIN_API_TOKEN is missing from $EnvironmentPath; managed game servers were not reconciled."
}
try {
    $ReconcileResponse = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:3001/api/server-instances/reconcile" -Headers @{ Authorization = "Bearer $AdminToken" } -TimeoutSec 600
}
catch {
    throw "The API is ready, but managed game-server reconciliation failed: $($_.Exception.Message)"
}
if ($ReconcileResponse.failures -ne 0) {
    Write-Host ($ReconcileResponse | ConvertTo-Json -Depth 8) -ForegroundColor Red
    throw "Managed game-server reconciliation reported $($ReconcileResponse.failures) failure(s). No Saved volumes were removed."
}
Write-Host "    Inspected $($ReconcileResponse.inspected); recreated $($ReconcileResponse.recreated)." -ForegroundColor Green

$AdminPanelUrl = "http://localhost:3000/admin/"
if (-not $RootLauncher) {
    Write-Host ""
    Write-Host "  Admin panel: $AdminPanelUrl" -ForegroundColor Green
    Write-Host "  API docs:    http://localhost:3000/docs/" -ForegroundColor Green
    Write-Host "  Admin token: open $EnvironmentPath and use ADMIN_API_TOKEN." -ForegroundColor Yellow
    try { Start-Process $AdminPanelUrl | Out-Null }
    catch { Write-Host "Open the admin panel URL in a browser." -ForegroundColor Yellow }
}
