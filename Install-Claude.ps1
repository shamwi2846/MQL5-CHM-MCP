[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Install-Claude.ps1'
& $implementation -ProjectRoot $PSScriptRoot
