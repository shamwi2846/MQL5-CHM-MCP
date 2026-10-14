[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Uninstall-Claude.ps1'
& $implementation -ProjectRoot $PSScriptRoot
