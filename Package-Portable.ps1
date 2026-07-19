[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string]$ReleaseName = 'mql5-chm-mcp-windows-x64',

    [string]$OutputDirectory,

    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$CandidateRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Package-Portable.ps1'
$arguments = @{ ProjectRoot=$PSScriptRoot; ReleaseName=$ReleaseName; OutputDirectory=$OutputDirectory }
if (-not [string]::IsNullOrWhiteSpace($CandidateRevision)) { $arguments.CandidateRevision=$CandidateRevision }
& $implementation @arguments
