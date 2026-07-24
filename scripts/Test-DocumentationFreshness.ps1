[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
$scriptPath = Join-Path $PSScriptRoot 'Compare-OfficialDocumentationHashes.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'Compare-OfficialDocumentationHashes.ps1 is missing.'
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Could not parse Compare-OfficialDocumentationHashes.ps1.' }
foreach ($functionAst in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $functionAst.Extent.Text
}

$buildRoot = Join-Path $projectRoot 'build'
if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $buildRoot | Out-Null
}
$testRoot = Join-Path $buildRoot ('documentation-freshness-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-Freshness {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    Copy-Item -LiteralPath (Join-Path $projectRoot 'corpus.lock.json') -Destination (Join-Path $testRoot 'corpus.lock.json')
    $lock = Read-JsonFile -Path (Join-Path $testRoot 'corpus.lock.json') -Context 'freshness test corpus lock'
    $baseline = @($lock.sources | ForEach-Object {
        [pscustomobject]@{
            Id=[string]$_.id
            FileName=[string]$_.filename
            Sha256=([string]$_.sha256).ToLowerInvariant()
            Bytes=[int64]123456
            HttpLastModified=$null
            HttpEtag=$null
            RetrievedAt='2026-07-23T00:00:00Z'
        }
    })

    $observation = [pscustomobject]@{ DownloadRoot = $null }
    $matchingProvider = {
        param([string]$DownloadRoot, [int]$TimeoutSeconds)
        $observation.DownloadRoot = $DownloadRoot
        [IO.File]::WriteAllText((Join-Path $DownloadRoot 'temporary-download.bin'), 'temporary')
        return $baseline
    }.GetNewClosure()
    $current = Compare-OfficialDocumentationHashes -ProjectRoot $testRoot -TimeoutSeconds 5 -InternalRecordProvider $matchingProvider
    Assert-Freshness ($current.status -ceq 'up-to-date') 'Matching official hashes were not reported as up to date.'
    Assert-Freshness (@($current.sources).Count -eq 3) 'Freshness report did not cover all three official CHMs.'
    Assert-Freshness (-not [string]::IsNullOrWhiteSpace([string]$observation.DownloadRoot) -and -not (Test-Path -LiteralPath $observation.DownloadRoot)) 'Freshness comparison retained downloaded CHM bytes.'
    Assert-Freshness (@(Get-ChildItem -LiteralPath $testRoot -Force).Count -eq 1) 'Read-only freshness comparison changed the project fixture.'

    $changedRecords = @($baseline | ForEach-Object { $_ | Select-Object * })
    $changedRecords[0].Sha256 = ('0' * 64)
    $changedProvider = { param([string]$DownloadRoot, [int]$TimeoutSeconds) return $changedRecords }.GetNewClosure()
    $changed = Compare-OfficialDocumentationHashes -ProjectRoot $testRoot -TimeoutSeconds 5 -InternalRecordProvider $changedProvider
    Assert-Freshness ($changed.status -ceq 'different-revision-available') 'A changed official hash was not reported as documentation drift.'
    Assert-Freshness (@($changed.changed_sources).Count -eq 1 -and [string]$changed.changed_sources[0].id -ceq [string]$baseline[0].Id) 'Freshness drift report did not identify the changed source.'

    $unavailableProvider = { param([string]$DownloadRoot, [int]$TimeoutSeconds) throw 'synthetic network outage' }
    $unavailable = Compare-OfficialDocumentationHashes -ProjectRoot $testRoot -TimeoutSeconds 5 -InternalRecordProvider $unavailableProvider
    Assert-Freshness ($unavailable.status -ceq 'check-unavailable' -and [string]$unavailable.message -match 'synthetic network outage') 'Download failure was not distinguished from documentation drift.'

    $missingProvider = { param([string]$DownloadRoot, [int]$TimeoutSeconds) return @($baseline | Select-Object -First 2) }.GetNewClosure()
    $missing = Compare-OfficialDocumentationHashes -ProjectRoot $testRoot -TimeoutSeconds 5 -InternalRecordProvider $missingProvider
    Assert-Freshness ($missing.status -ceq 'check-unavailable') 'Incomplete source results were accepted.'

    $sourceText = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($forbidden in @('Set-UpdateStatus','Update-ManagedChecksumsIfPresent','Update-Documentation.ps1','git push')) {
        Assert-Freshness (-not $sourceText.Contains($forbidden)) "Read-only freshness checker contains forbidden operation '$forbidden'."
    }
    Write-Host 'Documentation freshness fixtures passed: current, drift, unavailable, exact three-source closure, zero project writes, and temporary cleanup.'
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $testRoot
    }
}
