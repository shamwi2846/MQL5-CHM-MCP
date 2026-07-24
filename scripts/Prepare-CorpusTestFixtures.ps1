[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
if ((Get-Mql5ChmLayoutMode -ProjectRoot $projectRoot) -ne 'development') {
    throw 'Corpus test extraction is permitted only in a complete development checkout.'
}

$buildRoot = Join-Path $projectRoot 'build'
if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $buildRoot -ErrorAction Stop | Out-Null
}
$buildRoot = Resolve-FullPath -Path $buildRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $projectRoot -Path $buildRoot

$fixtureMarkerName = '.mql5-chm-corpus-test-fixture'
$fixtureMarkerValue = 'mql5-chm-corpus-test-fixture-v1'
$targetRoot = Assert-PathWithin -Root $buildRoot -Path (Join-Path $buildRoot 'extracted')
$workRoot = Assert-PathWithin -Root $buildRoot -Path (Join-Path $buildRoot ('corpus-test-work-' + [Guid]::NewGuid().ToString('N')))

try {
    foreach ($directory in @($workRoot,(Join-Path $workRoot 'sources'),(Join-Path $workRoot 'extracted'))) {
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    }

    $records = @(Get-SourceRecordsFromActiveRevision -ProjectRoot $projectRoot)
    if ($records.Count -ne 3) { throw 'Corpus test extraction requires exactly three validated official CHMs.' }
    $sevenZip = Resolve-SevenZipExtractor -Root $projectRoot
    foreach ($record in $records) {
        Copy-FileDurable -Source ([string]$record.Path) -Destination (Join-Path $workRoot "sources\$($record.FileName)") | Out-Null
        $count = Invoke-ChmExtraction -ProjectRoot $projectRoot -WorkingRoot $workRoot -SourceRecord $record -SevenZip $sevenZip -SkipHtmlHelp
        if ([int]$count -ne [int]$record.TopicCount) {
            throw "Corpus test extraction topic count changed for '$($record.FileName)'."
        }
    }

    $preparedRoot = Join-Path $workRoot 'extracted'
    [IO.File]::WriteAllText(
        (Join-Path $preparedRoot $fixtureMarkerName),
        "$fixtureMarkerValue`n",
        (New-Object Text.UTF8Encoding($false))
    )

    if (Test-Path -LiteralPath $targetRoot) {
        Assert-NoReparsePoint -Root $buildRoot -Path $targetRoot
        $markerPath = Join-Path $targetRoot $fixtureMarkerName
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
            (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() -cne $fixtureMarkerValue) {
            throw "Refusing to replace an unowned corpus test extraction: $targetRoot"
        }
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $targetRoot
    }
    [IO.Directory]::Move($preparedRoot, $targetRoot)
    Write-Host "Prepared verified corpus fixtures under: $targetRoot"
} finally {
    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $workRoot
    }
}
