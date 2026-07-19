Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'StageInstallRecovery.ps1')

function Wait-ExtractionStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ExpectedHtmlCount = 0,
        [ValidateRange(10,1800)][int]$TimeoutSeconds = 300,
        [ValidateRange(2,20)][int]$StablePolls = 8
    )
    $timer = [Diagnostics.Stopwatch]::StartNew(); $last = ''; $stable = 0
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $html = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.htm','.html') })
        [int64]$bytes = 0; foreach ($file in $html) { $bytes += $file.Length }
        $signature = "$($html.Count):$bytes"
        $countAccepted = $html.Count -gt 0 -and ($ExpectedHtmlCount -le 0 -or $html.Count -eq $ExpectedHtmlCount)
        if ($countAccepted -and $signature -eq $last) { $stable++; if ($stable -ge $StablePolls) { return $html.Count } } else { $stable = 0; $last = $signature }
        Start-Sleep -Milliseconds 250
    }
    $expectation = if ($ExpectedHtmlCount -gt 0) { "exactly $ExpectedHtmlCount" } else { 'a non-zero stable number of' }
    throw "Extraction did not reach $expectation HTML topics within $TimeoutSeconds seconds: $Path"
}

function Resolve-SevenZipExtractor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $candidates = @((Join-Path $Root 'tools\7z.exe'),(Join-Path $Root 'tools\7za.exe'),'C:\Program Files\7-Zip\7z.exe','C:\Program Files\NVIDIA Corporation\NVIDIA App\7z.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $full = Resolve-FullPath -Path $candidate -MustExist -PathType Leaf
            $probe = Invoke-NativeCapture -FilePath $full -Arguments @('i')
            if ($probe.ExitCode -eq 0 -and $probe.Text -match '(?im)^\s*.*Chm\s+chm\b') { return $full }
        }
    }
    return $null
}

function Get-ChmHtmlTopicCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$ChmPath
    )
    $extractor = Resolve-FullPath -Path $SevenZip -MustExist -PathType Leaf
    $archive = Resolve-FullPath -Path $ChmPath -MustExist -PathType Leaf
    $listing = Invoke-NativeCapture -FilePath $extractor -Arguments @('l','-slt',$archive)
    if ($listing.ExitCode -ne 0) { throw "Could not enumerate CHM contents before extraction: $archive. $($listing.Text)" }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $listing.Lines) {
        if ($line -match '^Path = (.+\.(?:htm|html))$') { [void]$paths.Add($Matches[1].Replace('\','/')) }
    }
    if ($paths.Count -le 0) { throw "CHM directory listing contains no HTML topics: $archive" }
    return $paths.Count
}

function Invoke-ChmExtraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingRoot,
        [Parameter(Mandatory)][object]$SourceRecord,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SevenZip,
        [ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
        [ValidateRange(10,300)][int]$HhTimeoutSeconds = 60
    )
    $sourceDirectory = Join-Path $WorkingRoot 'sources'; $extractedDirectory = Join-Path $WorkingRoot 'extracted'
    $destination = Join-Path $extractedDirectory $SourceRecord.Id
    Reset-SafeDirectory -ConfinementRoot $extractedDirectory -Path $destination | Out-Null
    if ([string]::IsNullOrWhiteSpace($SevenZip)) { throw "A CHM-capable 7-Zip executable is required to independently enumerate '$($SourceRecord.FileName)' before extraction." }
    $archivePath = Join-Path $sourceDirectory $SourceRecord.FileName
    $expected = Get-ChmHtmlTopicCount -SevenZip $SevenZip -ChmPath $archivePath
    if ($null -ne $SourceRecord.TopicCount -and $expected -ne [int]$SourceRecord.TopicCount) {
        throw "CHM directory listing for '$($SourceRecord.FileName)' contains $expected HTML topics; expected $($SourceRecord.TopicCount)."
    }
    $hhSucceeded = $false; $hh = 'C:\Windows\hh.exe'
    if (Test-Path -LiteralPath $hh -PathType Leaf) {
        Push-Location -LiteralPath $WorkingRoot
        try { & $hh '-decompile' "extracted\$($SourceRecord.Id)" "sources\$($SourceRecord.FileName)" | Out-Null } finally { Pop-Location }
        try { Wait-ExtractionStable -Path $destination -ExpectedHtmlCount $expected -TimeoutSeconds $HhTimeoutSeconds | Out-Null; $hhSucceeded = $true } catch { Write-Warning "hh.exe extraction was incomplete for '$($SourceRecord.FileName)'; using 7-Zip fallback." }
    }
    if (-not $hhSucceeded) {
        Reset-SafeDirectory -ConfinementRoot $extractedDirectory -Path $destination | Out-Null
        Invoke-NativeChecked -FilePath $SevenZip -Arguments @('x','-y',"-o$destination",(Join-Path $sourceDirectory $SourceRecord.FileName)) -FailureMessage "7-Zip extraction failed for '$($SourceRecord.FileName)'."
        Wait-ExtractionStable -Path $destination -ExpectedHtmlCount $expected -TimeoutSeconds $ExtractionTimeoutSeconds | Out-Null
    }
    return @(Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object { $_.Extension -in @('.htm','.html') }).Count
}

function Get-SourceRecordsFromActiveRevision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $validated = Assert-ManifestAndCorpus -ProjectRoot $ProjectRoot
    $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $source = $validated.Manifest.sources.PSObject.Properties[$definition.Id].Value
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=(Join-Path $validated.Root $definition.FileName)
            Sha256=[string]$source.sha256; Bytes=[int64]$source.bytes; TopicCount=[int]$source.topic_count
            HttpLastModified=$source.http_last_modified; HttpEtag=$source.http_etag; RetrievedAt=[string]$source.retrieved_at
        }
    }
    return $records
}

function Get-SourceRecordsFromRootMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container; $acceptedAt = [DateTime]::UtcNow.ToString('O'); $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $path = Join-Path $root $definition.FileName
        $hash = Assert-FileSha256 -Path $path -Expected $definition.Sha256
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=$path; Sha256=$hash; Bytes=(Get-Item -LiteralPath $path).Length
            TopicCount=$definition.TopicCount; HttpLastModified=$null; HttpEtag=$null; RetrievedAt=$acceptedAt
        }
    }
    return $records
}

function Get-DownloadedSourceRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DownloadRoot, [ValidateRange(5,600)][int]$TimeoutSeconds = 120)
    $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $result = Invoke-OfficialChmDownload -Uri ([uri]$definition.DownloadUri) -Destination (Join-Path $DownloadRoot $definition.FileName) -MinimumBytes $definition.MinimumBytes -MaximumBytes $definition.MaximumBytes -TimeoutSeconds $TimeoutSeconds
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=$result.Path; Sha256=$result.Sha256; Bytes=$result.Bytes
            TopicCount=$null; HttpLastModified=$result.HttpLastModified; HttpEtag=$result.HttpEtag; RetrievedAt=$result.RetrievedAt
        }
    }
    return $records
}

function Get-RevisionFromSourceRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SourceRecords)
    $hashes = [pscustomobject]@{}
    foreach ($record in $SourceRecords) { $hashes | Add-Member -NotePropertyName $record.Id -NotePropertyValue ([string]$record.Sha256) }
    return Get-CorpusRevision -SourceHashes $hashes
}

function New-CorpusLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SourceRecords, [Parameter(Mandatory)][hashtable]$TopicCounts)
    $sources = @(); $total = 0
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $record = @($SourceRecords | Where-Object Id -eq $definition.Id)
        if ($record.Count -ne 1) { throw "Expected one source record for '$($definition.Id)'." }
        $count = [int]$TopicCounts[$definition.Id]; if ($count -le 0) { throw "Topic count is invalid for '$($definition.Id)'." }; $total += $count
        $sources += [ordered]@{
            id=$definition.Id; filename=$definition.FileName; sha256=([string]$record[0].Sha256).ToLowerInvariant(); expected_topics=$count
            bytes=[int64]$record[0].Bytes; http_last_modified=$record[0].HttpLastModified; http_etag=$record[0].HttpEtag; retrieved_at=[string]$record[0].RetrievedAt
        }
    }
    return [ordered]@{ schema_version='1.1'; sources=$sources; expected_total_topics=$total }
}

function Resolve-Indexer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    foreach ($candidate in @((Join-Path $ProjectRoot 'src\indexer.mjs'),(Join-Path $ProjectRoot 'app\indexer.mjs'))) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return Resolve-FullPath -Path $candidate -MustExist -PathType Leaf } }
    throw 'No MQL5 CHM indexer was found.'
}

function Assert-DatabaseInspectionResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inspection, [switch]$RequireAssets)
    if (@($Inspection.integrity).Count -ne 1 -or [string]$Inspection.integrity[0] -ne 'ok') { throw 'SQLite integrity_check did not return ok.' }
    if ([int]$Inspection.topic_count -le 0 -or [int]$Inspection.fts_count -ne [int]$Inspection.section_count) { throw 'SQLite topic/section/FTS counts are inconsistent.' }
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $property = $Inspection.ranking.PSObject.Properties[$query]
        $row = if ($null -eq $property) { $null } else { $property.Value }
        if ($null -eq $row -or [string]$row.source -ne 'mql5' -or [string]$row.title -ne $query) { throw "Exact API ranking acceptance failed for '$query'." }
    }
    if ($RequireAssets) {
        if (-not [bool]$Inspection.has_assets -or [int]$Inspection.asset_count -le 0 -or [int]$Inspection.topic_asset_count -le 0) { throw 'SQLite asset catalog is missing or empty.' }
        if ([int]$Inspection.invalid_asset_count -ne 0 -or [int]$Inspection.invalid_topic_asset_count -ne 0) { throw 'SQLite asset catalog failed relational acceptance checks.' }
        if ([string]$Inspection.metadata.schema_version -cne '3' -or [string]$Inspection.metadata.index_contract -cne $script:IndexContract) { throw 'SQLite asset index contract metadata is invalid.' }
        foreach ($name in @('image_policy_sha256','asset_catalog_sha256','asset_tree_sha256')) { if ([string]$Inspection.metadata.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "SQLite metadata $name is invalid." } }
    }
    return $Inspection
}

function Invoke-DatabaseInspection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NodePath, [Parameter(Mandatory)][string]$DatabasePath, [switch]$RequireAssets)
    $inspector = Resolve-FullPath -Path (Join-Path $PSScriptRoot 'inspect-database.mjs') -MustExist -PathType Leaf
    $database = Resolve-FullPath -Path $DatabasePath -MustExist -PathType Leaf
    $result = Invoke-NativeCapture -FilePath $NodePath -Arguments @('--no-warnings',$inspector,$database)
    if ($result.ExitCode -ne 0) { throw "Database inspection failed. $($result.Text)" }
    try { $inspection = $result.Text | ConvertFrom-Json -ErrorAction Stop } catch { throw "Database inspection returned invalid JSON. $($_.Exception.Message)" }
    return Assert-DatabaseInspectionResult -Inspection $inspection -RequireAssets:$RequireAssets
}

function Get-TopicChangeReport {
    [CmdletBinding()]
    param([AllowNull()][object]$BaseInspection, [Parameter(Mandatory)][object]$CandidateInspection, [int]$MaximumIds = 200)
    $base = @{}; if ($null -ne $BaseInspection) { foreach ($property in $BaseInspection.topics.PSObject.Properties) { $base[$property.Name] = [string]$property.Value } }
    $candidate = @{}; foreach ($property in $CandidateInspection.topics.PSObject.Properties) { $candidate[$property.Name] = [string]$property.Value }
    $added = @($candidate.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
    $removed = @($base.Keys | Where-Object { -not $candidate.ContainsKey($_) } | Sort-Object)
    $changed = @($candidate.Keys | Where-Object { $base.ContainsKey($_) -and $base[$_] -cne $candidate[$_] } | Sort-Object)
    return [ordered]@{
        added_count=$added.Count; removed_count=$removed.Count; changed_count=$changed.Count
        added_topic_ids=@($added | Select-Object -First $MaximumIds); removed_topic_ids=@($removed | Select-Object -First $MaximumIds); changed_topic_ids=@($changed | Select-Object -First $MaximumIds)
        added_truncated=($added.Count -gt $MaximumIds); removed_truncated=($removed.Count -gt $MaximumIds); changed_truncated=($changed.Count -gt $MaximumIds)
    }
}

function Get-AssetChangeReport {
    [CmdletBinding()]
    param([AllowNull()][object]$BaseInspection, [Parameter(Mandatory)][object]$CandidateInspection, [int]$MaximumIds = 200)
    $base = @{}
    if ($null -ne $BaseInspection -and $null -ne $BaseInspection.PSObject.Properties['assets']) {
        foreach ($property in $BaseInspection.assets.PSObject.Properties) { $base[$property.Name] = ($property.Value | ConvertTo-Json -Compress -Depth 20) }
    }
    $candidate = @{}
    foreach ($property in $CandidateInspection.assets.PSObject.Properties) { $candidate[$property.Name] = ($property.Value | ConvertTo-Json -Compress -Depth 20) }
    $added = @($candidate.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
    $removed = @($base.Keys | Where-Object { -not $candidate.ContainsKey($_) } | Sort-Object)
    $changed = @($candidate.Keys | Where-Object { $base.ContainsKey($_) -and $base[$_] -cne $candidate[$_] } | Sort-Object)
    $emptySummary = [pscustomobject]@{ cataloged_count=0; exposed_count=0; excluded_count=0; occurrence_count=0; exposed_occurrence_count=0; total_bytes=0 }
    $baseSummary = if ($null -ne $BaseInspection -and $null -ne $BaseInspection.PSObject.Properties['asset_summary']) { $BaseInspection.asset_summary } else { $emptySummary }
    $candidateSummary = $CandidateInspection.asset_summary
    $baseCataloged = [int]$baseSummary.cataloged_count; $candidateCataloged = [int]$candidateSummary.cataloged_count
    $baseExposed = [int]$baseSummary.exposed_count; $candidateExposed = [int]$candidateSummary.exposed_count
    $baseOccurrences = [int]$baseSummary.occurrence_count; $candidateOccurrences = [int]$candidateSummary.occurrence_count
    $baseExposedOccurrences = [int]$baseSummary.exposed_occurrence_count; $candidateExposedOccurrences = [int]$candidateSummary.exposed_occurrence_count
    return [ordered]@{
        added_count=$added.Count; removed_count=$removed.Count; changed_count=$changed.Count
        added_asset_ids=@($added | Select-Object -First $MaximumIds); removed_asset_ids=@($removed | Select-Object -First $MaximumIds); changed_asset_ids=@($changed | Select-Object -First $MaximumIds)
        added_truncated=($added.Count -gt $MaximumIds); removed_truncated=($removed.Count -gt $MaximumIds); changed_truncated=($changed.Count -gt $MaximumIds)
        base_cataloged_count=$baseCataloged; candidate_cataloged_count=$candidateCataloged; cataloged_delta=($candidateCataloged-$baseCataloged)
        base_exposed_count=$baseExposed; candidate_exposed_count=$candidateExposed; exposed_delta=($candidateExposed-$baseExposed)
        candidate_excluded_count=[int]$candidateSummary.excluded_count
        base_occurrence_count=$baseOccurrences; candidate_occurrence_count=$candidateOccurrences; occurrence_delta=($candidateOccurrences-$baseOccurrences)
        base_exposed_occurrence_count=$baseExposedOccurrences; candidate_exposed_occurrence_count=$candidateExposedOccurrences; exposed_occurrence_delta=($candidateExposedOccurrences-$baseExposedOccurrences)
        candidate_total_bytes=[int64]$candidateSummary.total_bytes
        unsupported_count=0; oversized_count=0; unresolved_count=0; unclassified_count=0
        reduction_requires_review=($removed.Count -gt 0 -or $candidateExposed -lt $baseExposed -or $candidateOccurrences -lt $baseOccurrences -or $candidateExposedOccurrences -lt $baseExposedOccurrences)
    }
}

function Assert-AssetChangeReportMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Reported,
        [Parameter(Mandatory)][object]$Recomputed,
        [switch]$AcceptAssetReduction
    )
    $reportedJson = $Reported | ConvertTo-Json -Compress -Depth 30
    $recomputedJson = $Recomputed | ConvertTo-Json -Compress -Depth 30
    if ($reportedJson -cne $recomputedJson) { throw 'The staged asset-change report no longer matches the verified base and candidate indexes.' }
    if ([bool]$Recomputed.reduction_requires_review -and -not $AcceptAssetReduction) {
        throw 'The candidate reduces cataloged/exposed image or exposed-occurrence coverage. Review the stage report and retry with -AcceptAssetReduction.'
    }
    return $Recomputed
}

function Assert-StagedReportMatchesVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [AllowNull()][object]$BaseRevision,
        [Parameter(Mandatory)][object]$CandidateRevision,
        [AllowNull()][object]$BaseInspection,
        [Parameter(Mandatory)][object]$CandidateInspection,
        [switch]$AcceptAssetReduction
    )
    $topicChanges = if ($null -eq $BaseRevision) {
        Get-TopicChangeReport -BaseInspection $null -CandidateInspection $CandidateInspection
    } else {
        Assert-NoRevisionTopicLoss -BaseRevision $BaseRevision -CandidateRevision $CandidateRevision -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection -Context 'activation'
    }
    if (($Report.changes | ConvertTo-Json -Compress -Depth 30) -cne ($topicChanges | ConvertTo-Json -Compress -Depth 30)) {
        throw 'The staged topic-change report no longer matches the verified base and candidate indexes.'
    }
    $assetChanges = Get-AssetChangeReport -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection
    Assert-AssetChangeReportMatches -Reported $Report.asset_changes -Recomputed $assetChanges -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
    $sourceCounts = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $baseCount = if ($null -eq $BaseRevision) { 0 } else { [int]$BaseRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count }
        $candidateCount = [int]$CandidateRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        $sourceCounts[$definition.Id] = [ordered]@{ base=$baseCount; candidate=$candidateCount; delta=($candidateCount-$baseCount) }
    }
    if (($Report.source_topic_counts | ConvertTo-Json -Compress -Depth 20) -cne ($sourceCounts | ConvertTo-Json -Compress -Depth 20)) {
        throw 'The staged per-source topic counts no longer match the verified revisions.'
    }
    $rankings = [ordered]@{}
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $row = $CandidateInspection.ranking.PSObject.Properties[$query].Value
        $rankings[$query] = [ordered]@{ title=[string]$row.title; source=[string]$row.source }
    }
    if (($Report.required_rankings | ConvertTo-Json -Compress -Depth 20) -cne ($rankings | ConvertTo-Json -Compress -Depth 20)) {
        throw 'The staged representative-ranking report no longer matches the verified index.'
    }
    return [pscustomobject]@{ TopicChanges=$topicChanges; AssetChanges=$assetChanges; SourceTopicCounts=$sourceCounts; RequiredRankings=$rankings }
}

function Assert-NoRevisionTopicLoss {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BaseRevision,
        [Parameter(Mandatory)][object]$CandidateRevision,
        [Parameter(Mandatory)][object]$BaseInspection,
        [Parameter(Mandatory)][object]$CandidateInspection,
        [string]$Context = 'candidate revision'
    )
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $baseCount = [int]$BaseRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        $candidateCount = [int]$CandidateRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        if ($candidateCount -lt $baseCount) { throw "Refusing $Context`: '$($definition.Id)' loses topics ($baseCount -> $candidateCount)." }
    }
    $changes = Get-TopicChangeReport -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection
    if ([int]$changes.removed_count -ne 0) { throw "Refusing $Context`: candidate removes $($changes.removed_count) stable topic IDs." }
    if ([string]$BaseRevision.CorpusRevision -ceq [string]$CandidateRevision.CorpusRevision -and
        ([int]$changes.added_count -ne 0 -or [int]$changes.changed_count -ne 0)) {
        throw "Refusing $Context`: identical CHM bytes changed the stable topic set or content hashes."
    }
    return $changes
}

function New-RevisionCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object[]]$SourceRecords,
        [Parameter(Mandatory)][string]$WorkingRoot,
        [ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
        [ValidateRange(10,300)][int]$HhTimeoutSeconds = 60
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $work = Reset-SafeDirectory -ConfinementRoot (Split-Path -Parent $WorkingRoot) -Path $WorkingRoot
    $sourceRoot = New-Item -ItemType Directory -Path (Join-Path $work 'sources'); $extractedRoot = New-Item -ItemType Directory -Path (Join-Path $work 'extracted')
    foreach ($record in $SourceRecords) { Copy-Item -LiteralPath (Resolve-FullPath -Path $record.Path -MustExist -PathType Leaf) -Destination (Join-Path $sourceRoot.FullName $record.FileName) }
    $sevenZip = Resolve-SevenZipExtractor -Root $root; $counts = @{}
    foreach ($record in $SourceRecords) { $counts[$record.Id] = Invoke-ChmExtraction -ProjectRoot $root -WorkingRoot $work -SourceRecord $record -SevenZip $sevenZip -ExtractionTimeoutSeconds $ExtractionTimeoutSeconds -HhTimeoutSeconds $HhTimeoutSeconds }
    $lock = New-CorpusLock -SourceRecords $SourceRecords -TopicCounts $counts
    $lockPath = Join-Path $work 'corpus.lock.json'; Write-JsonAtomic -Path $lockPath -Value $lock -ConfinementRoot $work
    $corpusRevision = Get-RevisionFromSourceRecords -SourceRecords $SourceRecords
    $candidateRoot = New-Item -ItemType Directory -Path (Join-Path $work 'revision')
    foreach ($record in $SourceRecords) { Copy-Item -LiteralPath (Join-Path $sourceRoot.FullName $record.FileName) -Destination (Join-Path $candidateRoot.FullName $record.FileName) }
    $node = Resolve-NodeExecutable -ProjectRoot $root; $indexer = Resolve-Indexer -ProjectRoot $root
    Invoke-NativeChecked -FilePath $node -Arguments @($indexer,'--root',$root,'--workspace-root',$work,'--source-directory',$sourceRoot.FullName,'--extracted-directory',$extractedRoot.FullName,'--output-directory',$candidateRoot.FullName,'--corpus-lock',$lockPath) -FailureMessage 'MQL5 CHM indexing failed.'
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $candidateRoot.FullName 'corpus.lock.json')
    $candidateManifest = Read-JsonFile -Path (Join-Path $candidateRoot.FullName 'manifest.json') -Context 'candidate manifest'
    $indexRevision = [string](Get-RequiredJsonProperty $candidateManifest 'index_revision' 'candidate manifest')
    if ($indexRevision -cnotmatch '^[0-9a-f]{64}$') { throw 'Candidate manifest index_revision is invalid.' }
    $validated = Assert-Revision -ProjectRoot $root -Revision $indexRevision -RevisionRoot $candidateRoot.FullName -RevisionConfinementRoot $work -IdentityMode Index -RequireCurrent
    if ([string]$validated.CorpusRevision -cne $corpusRevision) { throw 'Candidate manifest corpus revision does not match the source records.' }
    $inspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $validated.DatabasePath -RequireAssets
    if ([string]$inspection.metadata.corpus_sha256 -cne $corpusRevision -or [string]$inspection.metadata.image_policy_sha256 -cne [string]$validated.Manifest.assets.policy_sha256 -or [string]$inspection.metadata.asset_catalog_sha256 -cne [string]$validated.Manifest.assets.catalog_sha256 -or [string]$inspection.metadata.asset_tree_sha256 -cne [string]$validated.Manifest.assets.tree_sha256) { throw 'Candidate database asset metadata does not match its manifest.' }
    if ([int]$inspection.asset_count -ne [int]$validated.Manifest.assets.cataloged_count -or [int]$inspection.topic_asset_count -ne [int]$validated.Manifest.assets.occurrence_count) { throw 'Candidate database asset counts do not match its manifest.' }
    return [pscustomobject]@{ Revision=$indexRevision; IndexRevision=$indexRevision; CorpusRevision=$corpusRevision; Root=$candidateRoot.FullName; Manifest=$validated.Manifest; Inspection=$inspection; TopicCounts=$counts; WorkRoot=$work }
}

function Install-RevisionCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][object]$Candidate)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $revisionsRoot = Join-Path $root 'revisions'; if (-not (Test-Path -LiteralPath $revisionsRoot -PathType Container)) { New-Item -ItemType Directory -Path $revisionsRoot | Out-Null }
    $revisionsRoot = Resolve-FullPath -Path $revisionsRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $revisionsRoot
    $destination = Get-RevisionDirectory -ProjectRoot $root -Revision ([string]$Candidate.Revision)
    if (Test-Path -LiteralPath $destination) { Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -IdentityMode Index -RequireCurrent | Out-Null; return $destination }
    $candidateWork = Resolve-FullPath -Path ([string]$Candidate.WorkRoot) -MustExist -PathType Container
    $candidateSource = Resolve-FullPath -Path ([string]$Candidate.Root) -MustExist -PathType Container
    Assert-PathWithin -Root $candidateWork -Path $candidateSource | Out-Null
    Assert-NoReparsePoint -Root $candidateWork -Path $candidateSource
    $sourceReparse = @(Get-ChildItem -LiteralPath $candidateSource -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($sourceReparse.Count -gt 0) { throw "Candidate revision contains a reparse point: $($sourceReparse[0].FullName)" }
    $temporary = Assert-PathWithin -Root $revisionsRoot -Path (Join-Path $revisionsRoot ('.revision-install-' + [Guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $temporary -ErrorAction Stop | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $candidateSource -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $temporary -Recurse -Force -ErrorAction Stop
        }
        Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -RevisionRoot $temporary -RevisionConfinementRoot $revisionsRoot -IdentityMode Index -RequireCurrent | Out-Null
        [IO.Directory]::Move($temporary, $destination)
        Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -IdentityMode Index -RequireCurrent | Out-Null
        return $destination
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Container) { Remove-SafeDirectory -ConfinementRoot $revisionsRoot -Path $temporary }
    }
}
