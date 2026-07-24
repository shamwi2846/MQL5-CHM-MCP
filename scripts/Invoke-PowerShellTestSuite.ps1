[CmdletBinding()]
param(
    [ValidateSet('Maintenance','Release')]
    [string]$Suite = 'Maintenance'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maintenance = @(
    'Test-CodexRegistration.ps1',
    'Test-FileSetTransaction.ps1',
    'Test-GlobalMutex.ps1',
    'Test-IndexMaintenanceRepairs.ps1',
    'Test-DocumentationFreshness.ps1',
    'Test-Maintenance.ps1',
    'Test-StageInstallRecovery.ps1'
)
$releaseOnly = @(
    'Test-PackagingRepairs.ps1',
    'Test-SevenZipRuntime.ps1'
)
$tests = if ($Suite -ceq 'Release') { @($maintenance + $releaseOnly) } else { $maintenance }

foreach ($testName in $tests) {
    $testPath = Join-Path $PSScriptRoot $testName
    Write-Host "Running $testName under PowerShell $($PSVersionTable.PSVersion)..."
    if ($Suite -ceq 'Maintenance' -and $testName -ceq 'Test-Maintenance.ps1') {
        & $testPath -SkipInstalledCorpusValidation
    } else {
        & $testPath
    }
}
Write-Host "$Suite PowerShell suite passed under PowerShell $($PSVersionTable.PSVersion)."
