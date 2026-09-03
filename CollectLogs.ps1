[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$RepositoryVersionFile = Join-Path $RepoRoot "ReSide\Config\DefaultGame.ini"
$PackagedVersionFile = Join-Path $RepoRoot "Version.txt"
$IsRepository = Test-Path -LiteralPath $RepositoryVersionFile -PathType Leaf

function Write-Stage {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "[ OK ] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

trap {
    Write-Host ""
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "No support archive was created. Correct the problem above and try again." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "                 ReSide Log Collector" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "Collects ReSide logs into one support archive." -ForegroundColor DarkGray
Write-Host ""
Write-Stage "Reading ReSide version information..."

if ($IsRepository) {
    $VersionMatch = Get-Content -LiteralPath $RepositoryVersionFile |
        Select-String -Pattern '^\s*ProjectVersion\s*=\s*(.+?)\s*$' |
        Select-Object -First 1
    if (-not $VersionMatch) {
        throw "ProjectVersion was not found in $RepositoryVersionFile"
    }
    $Version = $VersionMatch.Matches[0].Groups[1].Value
}
elseif (Test-Path -LiteralPath $PackagedVersionFile -PathType Leaf) {
    $Version = Get-Content -LiteralPath $PackagedVersionFile -Raw
}
else {
    throw "Version metadata was not found beside the collector. Re-extract the complete ReSide package."
}

$Version = $Version.Trim().Trim('"').Trim("'")
if (-not $Version -or $Version.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "ProjectVersion '$Version' cannot be used in an archive file name."
}

Write-SuccessMessage "Version: $Version"
if ($IsRepository) {
    Write-Stage "Mode: development repository"
}
else {
    Write-Stage "Mode: extracted release package"
}

$Timestamp = Get-Date -Format "yyyyMMddHHmmss"
$ArchiveName = "ReSide-$Version-logs-$Timestamp.zip"
$ArchivePath = Join-Path $RepoRoot $ArchiveName

if (Test-Path -LiteralPath $ArchivePath) {
    throw "Archive already exists: $ArchivePath"
}
Write-Stage "Archive destination: $ArchivePath"

# Every log this collector captures from Docker rather than from disk is written beside the package
# so the archive builder below picks it up, then removed on the way out.
$TemporaryLogFiles = [System.Collections.Generic.List[string]]::new()
$TemporaryDockerLog = $null
$DiagnosticsDirectory = if ($IsRepository -and (Test-Path -LiteralPath (Join-Path $RepoRoot "Logs") -PathType Container)) {
    Join-Path $RepoRoot "Logs"
} elseif (Test-Path -LiteralPath (Join-Path $RepoRoot "Api") -PathType Container) {
    Join-Path $RepoRoot "Api"
} else {
    $RepoRoot
}
$CollectorDiagnosticsLog = Join-Path $DiagnosticsDirectory "collector-diagnostics-$PID-$Timestamp.log"
$TemporaryLogFiles.Add($CollectorDiagnosticsLog)
[System.IO.File]::WriteAllLines($CollectorDiagnosticsLog, @(
    "ReSide log collector diagnostics",
    "Timestamp: $([DateTimeOffset]::Now.ToString('O'))",
    "Version: $Version",
    "Mode: $(if ($IsRepository) { 'development repository' } else { 'extracted release package' })",
    "Platform: $([System.Environment]::OSVersion.VersionString)",
    "Docker command available: $([bool](Get-Command docker -ErrorAction SilentlyContinue))"
))
if (-not $IsRepository) {
    $ComposeFile = Join-Path $RepoRoot "Api\docker-compose.yml"
    $ComposeEnvironmentFile = Join-Path $RepoRoot "Api\.env"
    if ((Test-Path -LiteralPath $ComposeFile -PathType Leaf) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Stage "Capturing Docker Compose logs from the API stack..."
        $TemporaryDockerLog = Join-Path $RepoRoot "Api\docker-compose-collector-$PID-$Timestamp.log"
        $ComposeArguments = @("compose", "--file", $ComposeFile)
        if (Test-Path -LiteralPath $ComposeEnvironmentFile -PathType Leaf) {
            $ComposeArguments += @("--env-file", $ComposeEnvironmentFile)
        }
        $ComposeArguments += @("logs", "--no-color")
        & docker @ComposeArguments *> $TemporaryDockerLog
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Docker Compose logs could not be collected; the Docker error will be included in the archive."
            $TemporaryLogFiles.Add($TemporaryDockerLog)
        }
        else {
            $TemporaryLogFiles.Add($TemporaryDockerLog)
            Write-SuccessMessage "Docker Compose output captured."
        }

        # The worlds an operator actually needs logs for are not Compose services: the API's server
        # manager creates one container per hosted server, so "docker compose logs" never sees them.
        # Collect them by their manager labels instead, including exited ones, whose logs are the
        # whole point of a support archive after a crash.
        Write-Stage "Capturing logs from API-managed game servers..."
        $ManagedFilters = @(
            "--filter", "label=com.reside.managed=true",
            "--filter", "label=com.reside.kind=game-server"
        )
        $DeploymentIdLine = if (Test-Path -LiteralPath $ComposeEnvironmentFile -PathType Leaf) {
            Get-Content -LiteralPath $ComposeEnvironmentFile | Where-Object { $_ -match '^DEPLOYMENT_ID=' } | Select-Object -First 1
        }
        if ($DeploymentIdLine) {
            $DeploymentId = ($DeploymentIdLine -split '=', 2)[1].Trim()
            if ($DeploymentId -match '^[a-z0-9][a-z0-9_.-]*$') {
                $ManagedFilters += @("--filter", "label=com.reside.deployment-id=$DeploymentId")
            }
            else {
                [System.IO.File]::AppendAllText($CollectorDiagnosticsLog, "`nManaged-container query skipped: DEPLOYMENT_ID is not safe to use as a Docker label filter.`n")
                $ManagedFilters = $null
            }
        }
        if ($null -eq $ManagedFilters) {
            $ManagedContainers = @()
        }
        else {
            $ManagedContainers = @(docker ps --all --no-trunc --format "{{.ID}}`t{{.Names}}" @ManagedFilters 2>> $CollectorDiagnosticsLog)
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "API-managed game-server containers could not be listed; the Docker error will be included in the archive."
                $ManagedContainers = @()
            }
        }
        $ManagedContainers = @($ManagedContainers | Where-Object { $_ -and $_.Contains("`t") })
        if ($ManagedContainers.Count -eq 0) {
            Write-Host "[SKIP] " -ForegroundColor Yellow -NoNewline
            Write-Host "No API-managed game-server containers were found."
        }
        foreach ($ManagedContainer in $ManagedContainers) {
            $Fields = $ManagedContainer -split "`t", 2
            $ContainerId = $Fields[0].Trim()
            $ContainerName = $Fields[1].Trim()
            $SafeName = $ContainerName
            foreach ($InvalidCharacter in [System.IO.Path]::GetInvalidFileNameChars()) {
                $SafeName = $SafeName.Replace($InvalidCharacter, '_')
            }
            $ContainerLogPath = Join-Path $RepoRoot "Api\game-server-$SafeName-collector-$PID-$Timestamp.log"
            $TemporaryLogFiles.Add($ContainerLogPath)
            docker logs --timestamps $ContainerId *> $ContainerLogPath
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Logs for game-server container $ContainerName could not be collected; the Docker error will be included."
                continue
            }
            Write-SuccessMessage "Captured game-server logs: $ContainerName"
        }
    }
    elseif (Test-Path -LiteralPath $ComposeFile -PathType Leaf) {
        Write-Host "[SKIP] " -ForegroundColor Yellow -NoNewline
        Write-Host "Docker is not available; collecting log files on disk only."
        [System.IO.File]::AppendAllText($CollectorDiagnosticsLog, "`nDocker diagnostics unavailable: the docker command was not found.`n")
    }
}

if ($IsRepository) {
    $CollectionRoots = @(
        (Join-Path $RepoRoot "Logs"),
        (Join-Path $RepoRoot "ReSide"),
        (Join-Path $RepoRoot "reside-api-rs"),
        (Join-Path $RepoRoot "reside-admin-panel")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
}
else {
    # Only the backend archive ships this collector, so Api/ is always beside it; Server/ appears
    # only in a -IncludeWindowsDedicatedServer package. Client logs are picked up separately from
    # LOCALAPPDATA below, for the common case of hosting on the same machine the client runs on.
    $CollectionRoots = @($RepoRoot)
}

$ExternalClientLogRoot = $null
if (-not $IsRepository -and $env:LOCALAPPDATA) {
    $ExternalClientLogRoot = Join-Path $env:LOCALAPPDATA "ReSide\Saved\Logs"
    if (Test-Path -LiteralPath $ExternalClientLogRoot -PathType Container) {
        $CollectionRoots += $ExternalClientLogRoot
    }
}

Write-Stage "Searching for log files in:"
foreach ($CollectionRoot in $CollectionRoots) {
    Write-Host "       $CollectionRoot" -ForegroundColor DarkGray
}

# These contain source-control metadata or third-party/build caches rather than
# application logs. Runtime/package output directories remain in scope.
$ExcludedDirectoryNames = @(".git", "node_modules", "target", "DerivedDataCache")

function Get-ProjectLogFile {
    param([string[]]$Roots)

    $PendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    foreach ($Root in $Roots) {
        $PendingDirectories.Push($Root)
    }

    while ($PendingDirectories.Count -gt 0) {
        $Directory = $PendingDirectories.Pop()
        foreach ($Item in Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) {
            if ($Item.PSIsContainer) {
                if ($Item.Name -notin $ExcludedDirectoryNames) {
                    $PendingDirectories.Push($Item.FullName)
                }
                continue
            }

            # Include both ordinary *.log files and rotated logs such as *.log.YYYY-MM-DD.
            if ($Item.Name -match '(?i)\.log(?:\.|$)') {
                $Item
            }
        }
    }
}

$LogFiles = @(Get-ProjectLogFile -Roots $CollectionRoots |
    Sort-Object -Property FullName -Unique)
$CollectorDiagnosticsFile = Get-Item -LiteralPath $CollectorDiagnosticsLog
if ($CollectorDiagnosticsFile.FullName -notin $LogFiles.FullName) {
    $LogFiles = @($LogFiles + $CollectorDiagnosticsFile | Sort-Object -Property FullName -Unique)
}

$SourceBytes = ($LogFiles | Measure-Object -Property Length -Sum).Sum
if (-not $SourceBytes) { $SourceBytes = 0 }
Write-SuccessMessage "Found $($LogFiles.Count) log files ($(Format-FileSize -Bytes $SourceBytes))."
Write-Stage "Compressing logs..."

Add-Type -AssemblyName System.IO.Compression

$ArchiveStream = [System.IO.File]::Open(
    $ArchivePath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
)
$Archive = [System.IO.Compression.ZipArchive]::new(
    $ArchiveStream,
    [System.IO.Compression.ZipArchiveMode]::Create
)

$AddedCount = 0
$SkippedCount = 0
try {
    for ($Index = 0; $Index -lt $LogFiles.Count; $Index++) {
        $LogFile = $LogFiles[$Index]
        if ($ExternalClientLogRoot -and $LogFile.FullName.StartsWith($ExternalClientLogRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ClientRelativePath = $LogFile.FullName.Substring($ExternalClientLogRoot.Length).TrimStart('\', '/')
            $RelativePath = "Client/Saved/Logs/$($ClientRelativePath.Replace('\', '/'))"
        }
        else {
            $RelativePath = $LogFile.FullName.Substring($RepoRoot.Length + 1).Replace('\', '/')
        }
        $PercentComplete = [int](100 * $Index / $LogFiles.Count)
        Write-Progress -Activity "Collecting ReSide logs" -Status $RelativePath -PercentComplete $PercentComplete
        Write-Host ("       [{0}/{1}] {2}" -f ($Index + 1), $LogFiles.Count, $RelativePath) -ForegroundColor DarkGray

        $Entry = $Archive.CreateEntry($RelativePath, [System.IO.Compression.CompressionLevel]::Optimal)
        $SourceStream = $null
        $EntryStream = $null
        $EntryAdded = $false
        try {
            # FileShare.ReadWrite permits collection while an application is still logging.
            $SourceStream = [System.IO.File]::Open(
                $LogFile.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            )
            $EntryStream = $Entry.Open()
            $SourceStream.CopyTo($EntryStream)
            $AddedCount++
            $EntryAdded = $true
        }
        catch {
            $SkippedCount++
            Write-Warning "Skipping '$($LogFile.FullName)': $($_.Exception.Message)"
        }
        finally {
            if ($EntryStream) { $EntryStream.Dispose() }
            if ($SourceStream) { $SourceStream.Dispose() }
        }
        if (-not $EntryAdded) {
            $Entry.Delete()
        }
    }
}
catch {
    $Archive.Dispose()
    $ArchiveStream.Dispose()
    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    foreach ($TemporaryLogFile in $TemporaryLogFiles) {
        Remove-Item -LiteralPath $TemporaryLogFile -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    Write-Progress -Activity "Collecting ReSide logs" -Completed
}

$Archive.Dispose()
$ArchiveStream.Dispose()
foreach ($TemporaryLogFile in $TemporaryLogFiles) {
    Remove-Item -LiteralPath $TemporaryLogFile -Force -ErrorAction SilentlyContinue
}

$ArchiveSize = (Get-Item -LiteralPath $ArchivePath).Length
Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGreen
Write-Host " Support archive created successfully" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor DarkGreen
Write-Host "Archive:   " -ForegroundColor Cyan -NoNewline
Write-Host $ArchivePath
Write-Host "Size:      " -ForegroundColor Cyan -NoNewline
Write-Host (Format-FileSize -Bytes $ArchiveSize)
Write-Host "Collected: " -ForegroundColor Cyan -NoNewline
Write-Host "$AddedCount files"
Write-Host "Skipped:   " -ForegroundColor Cyan -NoNewline
if ($SkippedCount -eq 0) {
    Write-Host "0 files" -ForegroundColor Green
}
else {
    Write-Host "$SkippedCount files (review the warnings above)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Send this ZIP with your support request." -ForegroundColor Yellow
