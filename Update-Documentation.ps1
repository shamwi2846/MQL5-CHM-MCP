[CmdletBinding(DefaultParameterSetName='Stage')]
param(
    [Parameter(Mandatory,ParameterSetName='Stage')][switch]$Stage,
    [Parameter(Mandatory,ParameterSetName='Apply')][switch]$Apply,
    [Parameter(Mandatory,ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
    [Parameter(ParameterSetName='Apply')][switch]$AcceptAssetReduction,
    [Parameter(ParameterSetName='Stage')][ValidateRange(5,600)][int]$TimeoutSeconds = 120,
    [Parameter(ParameterSetName='Stage')][ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
    [Parameter(ParameterSetName='Stage')][ValidateRange(10,300)][int]$HhTimeoutSeconds = 60,
    [ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$implementation = Join-Path $PSScriptRoot 'scripts\Update-Documentation.ps1'
if ($PSCmdlet.ParameterSetName -eq 'Apply') {
    & $implementation -ProjectRoot $PSScriptRoot -Apply -Revision $Revision -AcceptAssetReduction:$AcceptAssetReduction -LockTimeoutSeconds $LockTimeoutSeconds
} else {
    & $implementation -ProjectRoot $PSScriptRoot -Stage -TimeoutSeconds $TimeoutSeconds -ExtractionTimeoutSeconds $ExtractionTimeoutSeconds -HhTimeoutSeconds $HhTimeoutSeconds -LockTimeoutSeconds $LockTimeoutSeconds
}
