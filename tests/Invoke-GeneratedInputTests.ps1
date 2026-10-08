#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('fast','extended')][string]$Tier='fast')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$prior=$env:MQL5_GENERATED_TIER
try {
    $env:MQL5_GENERATED_TIER=$Tier
    & node --test --test-concurrency=1 (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\generated-inputs.test.mjs')
    if ($LASTEXITCODE -ne 0) {throw 'Generated raster tests failed; retain reported failure evidence.'}
    $json=Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\Test-GeneratedJson.ps1'
    & pwsh -NoProfile -NonInteractive -File $json -Tier $Tier
    if ($LASTEXITCODE -ne 0) {throw 'Generated JSON tests failed under PowerShell 7.'}
    # This affects only the child environment and is restored below.
    $modulePath=$env:PSModulePath
    try {$env:PSModulePath="$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:WINDIR\System32\WindowsPowerShell\v1.0\Modules";& powershell.exe -NoProfile -NonInteractive -File $json -Tier $Tier}
    finally {$env:PSModulePath=$modulePath}
    if ($LASTEXITCODE -ne 0) {throw 'Generated JSON tests failed under PowerShell 5.1.'}
} finally {$env:MQL5_GENERATED_TIER=$prior}
