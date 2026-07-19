[CmdletBinding(DefaultParameterSetName='Stage')]
param(
    [Parameter(ParameterSetName='Stage')]
    [switch]$Stage,

    [Parameter(Mandatory,ParameterSetName='Apply')]
    [switch]$Apply,

    [Parameter(Mandatory,ParameterSetName='Apply')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$Revision,

    [Parameter(ParameterSetName='Apply')]
    [switch]$AcceptAssetReduction,

    [ValidateRange(10, 1800)]
    [int]$ExtractionTimeoutSeconds = 300,

    [ValidateRange(10, 300)]
    [int]$HhTimeoutSeconds = 60,

    [ValidateRange(1, 3600)]
    [int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'scripts\Rebuild-Index.ps1'
$arguments = @{ ProjectRoot=$PSScriptRoot; LockTimeoutSeconds=$LockTimeoutSeconds }
if ($PSCmdlet.ParameterSetName -eq 'Apply') { $arguments.Apply=$true; $arguments.Revision=$Revision; $arguments.AcceptAssetReduction=$AcceptAssetReduction }
else { $arguments.Stage=$true; $arguments.ExtractionTimeoutSeconds=$ExtractionTimeoutSeconds; $arguments.HhTimeoutSeconds=$HhTimeoutSeconds }
& $implementation @arguments
