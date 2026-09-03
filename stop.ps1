# Stops packaged ReSide services and managed servers while preserving persistent data.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StopLauncher = Join-Path $PSScriptRoot "Api\stop.ps1"
if (-not (Test-Path -LiteralPath $StopLauncher -PathType Leaf)) {
    throw "Api\stop.ps1 is missing. Extract the complete ReSide package before running this launcher."
}

& $StopLauncher
