[CmdletBinding()]
param(
    [ValidateRange(5,600)][int]$TimeoutSeconds = 120,
    [ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$implementation = Join-Path $PSScriptRoot 'scripts\Check-DocumentationUpdates.ps1'
& $implementation -ProjectRoot $PSScriptRoot -TimeoutSeconds $TimeoutSeconds -LockTimeoutSeconds $LockTimeoutSeconds
