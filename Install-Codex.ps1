[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Install-Codex.ps1'
& $implementation -ProjectRoot $PSScriptRoot

