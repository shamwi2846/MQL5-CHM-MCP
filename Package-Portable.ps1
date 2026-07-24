[CmdletBinding(DefaultParameterSetName='Active')]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string]$ReleaseName = 'mql5-chm-mcp-windows-x64',

    [string]$OutputDirectory,

    [Parameter(Mandatory,ParameterSetName='Candidate')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$CandidateRevision,

    [Parameter(ParameterSetName='Candidate')]
    [switch]$AcceptAssetReduction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Package-Portable.ps1'
$arguments = @{ ProjectRoot=$PSScriptRoot; ReleaseName=$ReleaseName; OutputDirectory=$OutputDirectory }
if (-not [string]::IsNullOrWhiteSpace($CandidateRevision)) { $arguments.CandidateRevision=$CandidateRevision }
if ($AcceptAssetReduction) { $arguments.AcceptAssetReduction=$true }
& $implementation @arguments
