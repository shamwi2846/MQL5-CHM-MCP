[CmdletBinding()]
param([ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$implementation = Join-Path $PSScriptRoot 'scripts\Rollback-Documentation.ps1'
& $implementation -ProjectRoot $PSScriptRoot -LockTimeoutSeconds $LockTimeoutSeconds
