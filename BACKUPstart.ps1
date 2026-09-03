# Starts the packaged ReSide core services and opens the admin panel on Windows.
[CmdletBinding()]
param(
    [switch]$ConfigureFirewallOnly,
    [int]$FirewallGamePortMin,
    [int]$FirewallGamePortMax
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-DockerReady {
    docker info *> $null
    return $LASTEXITCODE -eq 0
}

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

function Get-DotEnvValue {
    param([string]$EnvironmentPath, [string]$Name, [string]$Default)
    if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) { return $Default }
    $Line = Get-Content -LiteralPath $EnvironmentPath | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $Line) { return $Default }
    $Value = ($Line -split '=', 2)[1].Trim()
    if (-not $Value) { return $Default }
    return $Value
}

function Set-DotEnvValue {
    param([string]$EnvironmentPath, [string]$Name, [string]$Value)
    $Lines = [System.IO.File]::ReadAllLines($EnvironmentPath)
    $Replacement = "$Name=$Value"
    $Found = $false
    $Updated = foreach ($Line in $Lines) {
        if ($Line -match "^$([regex]::Escape($Name))=") {
            if (-not $Found) { $Replacement; $Found = $true }
        } else {
            $Line
        }
    }
    if (-not $Found) { $Updated = @($Updated) + $Replacement }
    [System.IO.File]::WriteAllLines($EnvironmentPath, $Updated)
}

function Get-HostingConfigValue {
    param([string]$ConfigPath, [string]$Name, [string]$Default)
    $Line = [System.IO.File]::ReadAllLines($ConfigPath) |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } |
        Select-Object -First 1
    if (-not $Line) { return $Default }
    $Value = ($Line -split '=', 2)[1].Trim()
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) {
        return $Value.Substring(1, $Value.Length - 2).Replace('\"', '"').Replace('\\', '\')
    }
    return $Value
}

function Set-HostingConfigValue {
    param([string]$ConfigPath, [string]$Name, [object]$Value, [switch]$StringValue)
    $RenderedValue = if ($StringValue) { '"' + ([string]$Value).Replace('\', '\\').Replace('"', '\"') + '"' } else { [string]$Value }
    $Replacement = "$Name = $RenderedValue"
    $Found = $false
    $Updated = foreach ($Line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        if ($Line -match "^\s*$([regex]::Escape($Name))\s*=") {
            if (-not $Found) { $Replacement; $Found = $true }
        } else { $Line }
    }
    if (-not $Found) { throw "$Name is missing from $ConfigPath. Restore config.toml from the package." }
    [System.IO.File]::WriteAllLines($ConfigPath, $Updated)
}

function Sync-HostingConfig {
    param([string]$ConfigPath, [string]$EnvironmentPath)
    $Mode = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "hosting_mode" -Default ""
    $Address = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Default ""
    $PortMin = [int](Get-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_min" -Default "0")
    $PortMax = [int](Get-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_max" -Default "0")
    $PublicApiUrl = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "public_api_url" -Default ""
    if ($Mode -notin @("lan", "public", "private", "custom")) { throw "hosting_mode in config.toml must be lan, public, private, or custom." }
    if ($Mode -eq "lan" -and $Address -in @("AUTO_DETECT", "127.0.0.1", "localhost")) {
        $Address = Get-AdvertisedIPv4Address
        if (-not $Address) { throw "No LAN IPv4 address was detected. Set advertised_address in config.toml manually." }
        Set-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Value $Address -StringValue
    }
    if (-not $Address -or $Address -in @("AUTO_DETECT", "127.0.0.1", "localhost")) { throw "advertised_address in config.toml must be a reachable IP address or DNS name." }
    if ($Address -match '^[a-z]+://' -or $Address -match '[/\\]') { throw "advertised_address in config.toml must not include a scheme, port, or path." }
    if ($PortMin -lt 1 -or $PortMax -gt 65535 -or $PortMin -gt $PortMax) { throw "game ports in config.toml must be between 1 and 65535, with the minimum first." }
    Set-DotEnvValue -EnvironmentPath $EnvironmentPath -Name "SERVER_MANAGER_HOSTING_MODE" -Value $Mode
    Set-DotEnvValue -EnvironmentPath $EnvironmentPath -Name "SERVER_MANAGER_ADVERTISED_ADDRESS" -Value $Address
    Set-DotEnvValue -EnvironmentPath $EnvironmentPath -Name "SERVER_MANAGER_PORT_MIN" -Value $PortMin
    Set-DotEnvValue -EnvironmentPath $EnvironmentPath -Name "SERVER_MANAGER_PORT_MAX" -Value $PortMax
    Set-DotEnvValue -EnvironmentPath $EnvironmentPath -Name "SERVER_MANAGER_PUBLIC_API_URL" -Value $PublicApiUrl
}

function Read-HostAddress {
    param([string]$Prompt)
    do {
        $Value = (Read-Host $Prompt).Trim()
        if ($Value -match '^[a-z]+://' -or $Value -match '[/\\]') {
            Write-Host "  Enter only an IP address or DNS name, without http://, a port, or a path." -ForegroundColor Yellow
            $Value = ""
        }
    } until ($Value)
    return $Value
}

function Invoke-HostingSetup {
    param([string]$ConfigPath)
    Write-Host "[1/4] Choose who can join" -ForegroundColor Cyan
    Write-Host "  1. Local network (LAN)" -ForegroundColor White
    Write-Host "  2. Public internet" -ForegroundColor White
    Write-Host "  3. Private network or VPN" -ForegroundColor White
    Write-Host "  4. Custom setup" -ForegroundColor White
    Write-Host ""
    do { $Choice = (Read-Host "Select 1-4 [1]").Trim(); if (-not $Choice) { $Choice = "1" } } until ($Choice -in @("1", "2", "3", "4"))

    switch ($Choice) {
        "1" {
            $Address = Get-AdvertisedIPv4Address
            if (-not $Address) { throw "No LAN IPv4 address was detected. Choose Custom setup and enter an address manually." }
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Value $Address -StringValue
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "hosting_mode" -Value "lan" -StringValue
            Write-Host "  LAN hosting selected: $Address" -ForegroundColor Green
            Write-Host "  This address applies to every existing and future managed world." -ForegroundColor DarkGray
            Write-Host "  Players on this network can discover ReSide automatically." -ForegroundColor DarkGray
        }
        "2" {
            $Address = Read-HostAddress -Prompt "Public IP or DNS name"
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Value $Address -StringValue
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "hosting_mode" -Value "public" -StringValue
            Write-Host "  Public hosting selected: $Address" -ForegroundColor Green
            Write-Host "  This address applies to every existing and future managed world." -ForegroundColor DarkGray
            Write-Host "  Your router must forward TCP 3000 and the game-server UDP ports to this computer." -ForegroundColor Yellow
        }
        "3" {
            $Address = Read-HostAddress -Prompt "This computer's VPN IP or DNS name"
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Value $Address -StringValue
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "hosting_mode" -Value "private" -StringValue
            Write-Host "  Private/VPN hosting selected: $Address" -ForegroundColor Green
            Write-Host "  This address applies to every existing and future managed world." -ForegroundColor DarkGray
            Write-Host "  Every player must join the same VPN." -ForegroundColor DarkGray
        }
        "4" {
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "hosting_mode" -Value "custom" -StringValue
            $CurrentAddress = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Default "AUTO_DETECT"
            $Address = (Read-Host "Advertised IP or DNS name [$CurrentAddress]").Trim()
            if (-not $Address -and $CurrentAddress -in @("AUTO_DETECT", "127.0.0.1", "localhost")) {
                $Address = Read-HostAddress -Prompt "Advertised IP or DNS name"
            }
            if ($Address) {
                if ($Address -match '^[a-z]+://' -or $Address -match '[/\\]') { throw "Advertised address must be an IP address or DNS name without a scheme, port, or path." }
                Set-HostingConfigValue -ConfigPath $ConfigPath -Name "advertised_address" -Value $Address -StringValue
            }
            $CurrentMin = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_min" -Default "7777"
            $CurrentMax = Get-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_max" -Default "7877"
            $PortMin = (Read-Host "First game UDP port [$CurrentMin]").Trim()
            $PortMax = (Read-Host "Last game UDP port [$CurrentMax]").Trim()
            $SelectedMin = if ($PortMin) { [int]$PortMin } else { [int]$CurrentMin }
            $SelectedMax = if ($PortMax) { [int]$PortMax } else { [int]$CurrentMax }
            if ($SelectedMin -lt 1 -or $SelectedMax -gt 65535 -or $SelectedMin -gt $SelectedMax) { throw "Game ports must be between 1 and 65535, and the first port cannot exceed the last port." }
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_min" -Value $SelectedMin
            Set-HostingConfigValue -ConfigPath $ConfigPath -Name "game_port_max" -Value $SelectedMax
            Write-Host "  Custom settings saved in config.toml for every managed world." -ForegroundColor Green
        }
    }
}

function Add-ReSideFirewallRules {
    param([int]$GamePortMin, [int]$GamePortMax)
    $Rules = @(
        @{ Name = "ReSide Backend Gateway TCP 3000"; Protocol = "TCP"; Port = "3000" },
        @{ Name = "ReSide Backend Discovery UDP 3002"; Protocol = "UDP"; Port = "3002" },
        @{ Name = "ReSide Managed Game Servers UDP $GamePortMin-$GamePortMax"; Protocol = "UDP"; Port = "$GamePortMin-$GamePortMax" }
    )
    $MissingRules = @($Rules | Where-Object {
        -not (Get-NetFirewallRule -DisplayName $_.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq "True" -and $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" } |
            Select-Object -First 1)
    })
    if ($MissingRules.Count -eq 0) {
        Write-Host "  Existing ReSide firewall rules are ready." -ForegroundColor Green
        return
    }

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "  Windows will ask permission to configure the hosting firewall." -ForegroundColor Yellow
        $Process = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-ConfigureFirewallOnly",
            "-FirewallGamePortMin", $GamePortMin,
            "-FirewallGamePortMax", $GamePortMax
        )
        if ($Process.ExitCode -ne 0) {
            Write-Warning "Windows Firewall setup did not complete. Allow inbound TCP 3000, UDP 3002, and UDP $GamePortMin-$GamePortMax on trusted LAN profiles manually."
        }
        return
    }
    try {
        foreach ($Rule in $Rules) {
            $ExistingRule = Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -eq "True" -and $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" } |
                Select-Object -First 1
            if (-not $ExistingRule) {
                Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue |
                    Remove-NetFirewallRule -ErrorAction Stop
                # -ErrorAction Stop because this cmdlet reports an unelevated failure without
                # terminating, which let the success message below print for rules that were never
                # added. An operator who believes the firewall is open stops looking there.
                New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -Action Allow `
                    -Protocol $Rule.Protocol -LocalPort $Rule.Port -Profile Domain, Private -ErrorAction Stop | Out-Null
                Write-Host "  Added firewall rule: $($Rule.Name)" -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Warning "Could not configure Windows Firewall rules without elevation. Allow inbound TCP 3000, UDP 3002, and UDP $GamePortMin-$GamePortMax on trusted LAN profiles manually. Startup will continue."
    }
}

if ($ConfigureFirewallOnly) {
    Add-ReSideFirewallRules -GamePortMin $FirewallGamePortMin -GamePortMax $FirewallGamePortMax
    exit 0
}

Clear-Host
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "  ReSide Server Hosting" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host ""
$ApiLauncher = Join-Path $PSScriptRoot "Api\run.ps1"
$ApiEnvironmentPath = Join-Path $PSScriptRoot "Api\.env"
$HostingConfigPath = Join-Path $PSScriptRoot "config.toml"
if (-not (Test-Path -LiteralPath $ApiLauncher -PathType Leaf)) {
    throw "Api\run.ps1 is missing. Extract the complete ReSide backend package before running this launcher."
}
if (-not (Test-Path -LiteralPath $ApiEnvironmentPath -PathType Leaf)) {
    throw "Api\.env is missing. Extract the complete ReSide backend package before running this launcher."
}
if (-not (Test-Path -LiteralPath $HostingConfigPath -PathType Leaf)) {
    throw "config.toml is missing. Extract the complete ReSide backend package before running this launcher."
}
if ([Console]::IsInputRedirected) {
    Write-Host "[1/4] Using the saved hosting settings (non-interactive start)" -ForegroundColor Cyan
} else {
    Invoke-HostingSetup -ConfigPath $HostingConfigPath
}
Sync-HostingConfig -ConfigPath $HostingConfigPath -EnvironmentPath $ApiEnvironmentPath
Write-Host ""
Write-Host "[2/4] Checking Docker" -ForegroundColor Cyan
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker Desktop is not installed. Install it from https://www.docker.com/products/docker-desktop/, start it once, and try again."
}

if (-not (Test-DockerReady)) {
    $DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $DockerDesktop -PathType Leaf) {
        Write-Host "  Starting Docker Desktop. This can take a minute..." -ForegroundColor Yellow
        Start-Process -FilePath $DockerDesktop | Out-Null
        $Deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $DockerReady = Test-DockerReady
        } until ($DockerReady -or (Get-Date) -ge $Deadline)
    }
    if (-not (Test-DockerReady)) {
        throw "Docker Desktop is installed but is not ready. Open Docker Desktop, wait until it is running, and try again."
    }
}
Write-Host "  Docker is ready." -ForegroundColor Green

# Api\run.ps1 detects and writes SERVER_MANAGER_ADVERTISED_ADDRESS itself, so a deployment started
# from that script directly cannot silently advertise loopback. Only the host-level firewall work,
# which needs elevation, stays here.
$GamePortMin = [int](Get-HostingConfigValue -ConfigPath $HostingConfigPath -Name "game_port_min" -Default "7777")
$GamePortMax = [int](Get-HostingConfigValue -ConfigPath $HostingConfigPath -Name "game_port_max" -Default "7877")
Write-Host ""
Write-Host "[3/4] Configuring network access" -ForegroundColor Cyan
Add-ReSideFirewallRules -GamePortMin $GamePortMin -GamePortMax $GamePortMax
$PublicProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq "Public" })
if ($PublicProfiles.Count -gt 0) {
    Write-Host ""
    Write-Host "  ! Windows network profile: Public" -ForegroundColor Yellow
    Write-Host "    ReSide's trusted-LAN firewall rules do not apply to Public networks." -ForegroundColor Yellow
    Write-Host "    For a trusted home network, change its Windows profile to Private." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "[4/4] Starting ReSide services" -ForegroundColor Cyan
& $ApiLauncher -HostFirewallConfigured -RootLauncher
$EnvironmentPath = Join-Path $PSScriptRoot "Api\.env"
$AdminApiTokenLine = Get-Content -LiteralPath $EnvironmentPath | Where-Object { $_ -match '^ADMIN_API_TOKEN=' } | Select-Object -First 1
$AdminApiToken = if ($AdminApiTokenLine) { ($AdminApiTokenLine -split '=', 2)[1].Trim() } else { "" }
if (-not $AdminApiToken) {
    throw "ADMIN_API_TOKEN is missing from $EnvironmentPath."
}
$AdminPanelUrl = "http://localhost:3000/admin/"
$AutomaticSignIn = $false
try {
    $Bootstrap = Invoke-RestMethod -Method Post `
        -Uri "http://127.0.0.1:3001/api/server-instances/bootstrap-code" `
        -Headers @{ Authorization = "Bearer $AdminApiToken" } `
        -TimeoutSec 10
    if (-not $Bootstrap.bootstrapCode) { throw "The API returned an empty bootstrap code." }
    $EncodedBootstrapCode = [uri]::EscapeDataString([string]$Bootstrap.bootstrapCode)
    $AdminPanelUrl = "http://localhost:3000/admin/#bootstrapCode=$EncodedBootstrapCode"
    $AutomaticSignIn = $true
}
catch {
    Write-Host ""
    Write-Host "  ! Automatic admin sign-in could not be prepared." -ForegroundColor Yellow
    Write-Host "    The panel will open normally; use ADMIN_API_TOKEN from Api\.env." -ForegroundColor Yellow
}
$LanAddress = Get-AdvertisedIPv4Address
$HostingAddress = Get-HostingConfigValue -ConfigPath $HostingConfigPath -Name "advertised_address" -Default "unknown"
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ReSide is ready" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
if ($AutomaticSignIn) {
    Write-Host "  Admin panel sign-in: automatic (one-time link)" -ForegroundColor Green
} else {
    Write-Host "  Admin panel sign-in: manual token from Api\.env" -ForegroundColor Yellow
}
Write-Host "  Local admin: http://localhost:3000/admin/" -ForegroundColor Green
Write-Host "  Hosting address: $HostingAddress" -ForegroundColor Green
if ($LanAddress) {
    Write-Host "  LAN admin:   http://${LanAddress}:3000/admin/" -ForegroundColor Green
    Write-Host "  LAN API:     http://${LanAddress}:3000/api" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Admin access is session-only. Use LAN HTTP URLs only on a trusted network or VPN." -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor DarkGreen
try { Start-Process $AdminPanelUrl | Out-Null }
catch { Write-Host "  Open http://localhost:3000/admin/ in a browser." -ForegroundColor Yellow }
