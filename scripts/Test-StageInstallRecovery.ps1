[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

function Assert-StageFixture {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-StageFixtureReport {
    param(
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$CorpusRevision,
        [Parameter(Mandatory)][string]$BaseRevision,
        [Parameter(Mandatory)][string]$BaseCorpusRevision
    )
    $sourceCounts = [ordered]@{
        mql5=[ordered]@{base=4134;candidate=4134;delta=0}
        mql5book=[ordered]@{base=581;candidate=581;delta=0}
        neuronetworksbook=[ordered]@{base=112;candidate=112;delta=0}
    }
    $changes = [ordered]@{
        added_count=0;removed_count=0;changed_count=0
        added_topic_ids=@();removed_topic_ids=@();changed_topic_ids=@()
        added_truncated=$false;removed_truncated=$false;changed_truncated=$false
    }
    $assetChanges = [ordered]@{
        added_count=0;removed_count=0;changed_count=0
        added_asset_ids=@();removed_asset_ids=@();changed_asset_ids=@()
        added_truncated=$false;removed_truncated=$false;changed_truncated=$false
        base_cataloged_count=0;candidate_cataloged_count=0;cataloged_delta=0
        base_exposed_count=0;candidate_exposed_count=0;exposed_delta=0;candidate_excluded_count=0
        base_occurrence_count=0;candidate_occurrence_count=0;occurrence_delta=0
        base_exposed_occurrence_count=0;candidate_exposed_occurrence_count=0;exposed_occurrence_delta=0
        candidate_total_bytes=0
        unsupported_count=0;oversized_count=0;unresolved_count=0;unclassified_count=0
        reduction_requires_review=$false
    }
    $rankings = [ordered]@{}
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $rankings[$query] = [ordered]@{title=$query;source='mql5'}
    }
    return New-StagedRevisionReportValue -Revision $Revision -CorpusRevision $CorpusRevision `
        -BaseRevision $BaseRevision -BaseCorpusRevision $BaseCorpusRevision `
        -SourceTopicCounts $sourceCounts -Changes $changes -AssetChanges $assetChanges `
        -RequiredRankings $rankings -StagedAt '2026-07-18T12:00:00.0000000Z'
}

function New-StageFixtureCandidate {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Revision, [Parameter(Mandatory)][string]$CorpusRevision)
    $work = Join-Path $Root ('work-' + $Revision.Substring(0, 4))
    $candidateRoot = Join-Path $work 'revision'
    New-Item -ItemType Directory -Path $candidateRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $candidateRoot 'manifest.json'), 'fixture manifest', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $candidateRoot 'mql5-docs.sqlite'), 'fixture database', (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Revision=$Revision;IndexRevision=$Revision;CorpusRevision=$CorpusRevision
        Root=$candidateRoot;WorkRoot=$work
    }
}

function New-StageFixtureManifest {
    param(
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$CorpusRevision,
        [int]$SchemaVersion = 3
    )
    $emptyHash = ('e' * 64)
    $sources = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $sources[$definition.Id] = [ordered]@{filename=$definition.FileName;sha256=('a' * 64);bytes=1;topic_count=$definition.TopicCount;section_count=$definition.TopicCount}
    }
    $bySource = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) { $bySource[$definition.Id] = [ordered]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0} }
    return [pscustomobject][ordered]@{
        schema_version=$SchemaVersion;index_revision=$Revision;corpus_revision=$CorpusRevision;corpus_sha256=$CorpusRevision;index_contract=$script:IndexContract
        database=[ordered]@{filename='mql5-docs.sqlite';sha256=$Revision;bytes=16};sources=[pscustomobject]$sources
        total_topic_count=4827;total_section_count=4827;topic_link_count=0;resolved_topic_link_count=0;unresolved_topic_link_count=0
        assets=[ordered]@{directory='assets';cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0;catalog_sha256=$emptyHash;tree_sha256=$emptyHash;policy_sha256=$emptyHash;by_source=[pscustomobject]$bySource}
    }
}

function New-LegacyStageRevisionFixture {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Seed)
    $sourceHashes = [pscustomobject]@{}
    $sourceObjects = [ordered]@{}
    $lockSources = @()
    $timestamp = '2026-07-18T00:00:00Z'
    $holding = Join-Path $Root ('.legacy-holding-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $holding -Force | Out-Null
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $chmPath = Join-Path $holding $definition.FileName
        [IO.File]::WriteAllText($chmPath, "$Seed-$($definition.Id)")
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $chmPath).Hash.ToLowerInvariant()
        $sourceHashes | Add-Member -NotePropertyName $definition.Id -NotePropertyValue $hash
        $sourceObjects[$definition.Id] = [ordered]@{
            filename=$definition.FileName;sha256=$hash;bytes=(Get-Item $chmPath).Length
            http_last_modified=$null;http_etag=$null;retrieved_at=$timestamp
            topic_count=$definition.TopicCount;section_count=$definition.TopicCount
        }
        $lockSources += [ordered]@{
            id=$definition.Id;filename=$definition.FileName;sha256=$hash;expected_topics=$definition.TopicCount
            bytes=(Get-Item $chmPath).Length;http_last_modified=$null;http_etag=$null;retrieved_at=$timestamp
        }
    }
    $corpus = Get-CorpusRevision -SourceHashes $sourceHashes
    $revisionRoot = Join-Path $Root "revisions\$corpus"
    New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
    foreach ($definition in Get-Mql5CorpusDefinition) {
        Move-Item -LiteralPath (Join-Path $holding $definition.FileName) -Destination (Join-Path $revisionRoot $definition.FileName)
    }
    Remove-Item -LiteralPath $holding -Force
    $databasePath = Join-Path $revisionRoot 'mql5-docs.sqlite'
    [IO.File]::WriteAllText($databasePath, "database-$Seed")
    $databaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $databasePath).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schema_version=2;database=[ordered]@{filename='mql5-docs.sqlite';sha256=$databaseHash;bytes=(Get-Item $databasePath).Length}
        sources=$sourceObjects;total_topic_count=4827;total_section_count=4827
        topic_link_count=0;resolved_topic_link_count=0;unresolved_topic_link_count=0
        corpus_sha256=$corpus;indexed_at=$timestamp;build_timestamp=$timestamp
    }
    Write-JsonAtomic -Path (Join-Path $revisionRoot 'manifest.json') -Value $manifest -ConfinementRoot $revisionRoot
    Write-JsonAtomic -Path (Join-Path $revisionRoot 'corpus.lock.json') -Value ([ordered]@{schema_version='1.1';sources=$lockSources;expected_total_topics=4827}) -ConfinementRoot $revisionRoot
    return [pscustomobject]@{Corpus=$corpus;Index=$databaseHash;Root=$revisionRoot}
}

function New-CurrentStageRevisionTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Seed,
        [Parameter(Mandatory)][string]$Timestamp,
        [string]$DatabaseSeed = $Seed,
        [string]$IndexContract = $script:IndexContract
    )
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'assets') -Force | Out-Null
    $sourceHashes = [pscustomobject]@{}
    $sources = [ordered]@{}
    $lockSources = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $chm = Join-Path $Root $definition.FileName
        [IO.File]::WriteAllText($chm, "$Seed-$($definition.Id)")
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $chm).Hash.ToLowerInvariant()
        $sourceHashes | Add-Member -NotePropertyName $definition.Id -NotePropertyValue $hash
        $sources[$definition.Id] = [ordered]@{filename=$definition.FileName;sha256=$hash;bytes=(Get-Item $chm).Length;http_last_modified=$null;http_etag=$null;retrieved_at=$Timestamp;topic_count=$definition.TopicCount;section_count=$definition.TopicCount}
        $lockSources += [ordered]@{id=$definition.Id;filename=$definition.FileName;sha256=$hash;expected_topics=$definition.TopicCount;bytes=(Get-Item $chm).Length;http_last_modified=$null;http_etag=$null;retrieved_at=$Timestamp}
    }
    $corpus = Get-CorpusRevision -SourceHashes $sourceHashes
    $databasePath = Join-Path $Root 'mql5-docs.sqlite'
    [IO.File]::WriteAllText($databasePath, "$DatabaseSeed-database")
    $index = (Get-FileHash -Algorithm SHA256 -LiteralPath $databasePath).Hash.ToLowerInvariant()
    $emptyTree = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    $bySource = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) { $bySource[$definition.Id] = [ordered]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0} }
    $manifest = [ordered]@{
        schema_version=3;index_contract=$IndexContract;index_revision=$index;corpus_revision=$corpus
        database=[ordered]@{filename='mql5-docs.sqlite';sha256=$index;bytes=(Get-Item $databasePath).Length}
        sources=$sources;total_topic_count=4827;total_section_count=4827;topic_link_count=0;resolved_topic_link_count=0;unresolved_topic_link_count=0
        corpus_sha256=$corpus;indexed_at=$Timestamp;build_timestamp=$Timestamp
        assets=[ordered]@{directory='assets';cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0;catalog_sha256=$emptyTree;tree_sha256=$emptyTree;policy_sha256=$emptyTree;by_source=$bySource}
    }
    Write-JsonAtomic -Path (Join-Path $Root 'manifest.json') -Value $manifest -ConfinementRoot $Root
    Write-JsonAtomic -Path (Join-Path $Root 'corpus.lock.json') -Value ([ordered]@{schema_version='1.1';sources=$lockSources;expected_total_topics=4827}) -ConfinementRoot $Root
    return [pscustomobject]@{Index=$index;Corpus=$corpus;Root=$Root;Manifest=$manifest}
}

$tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
$fixture = Join-Path $tempBase ('mql5-chm-stage-recovery-' + [Guid]::NewGuid().ToString('N'))
$legacyCandidateWork = Join-Path $tempBase ('mql5-chm-legacy-stage-candidate-' + [Guid]::NewGuid().ToString('N'))
$sameIndexCandidateWork = Join-Path $tempBase ('mql5-chm-same-index-candidate-' + [Guid]::NewGuid().ToString('N'))
$supportedBaseWork = Join-Path $tempBase ('mql5-chm-supported-base-' + [Guid]::NewGuid().ToString('N'))
$supportedCandidateWork = Join-Path $tempBase ('mql5-chm-supported-candidate-' + [Guid]::NewGuid().ToString('N'))
$originalAssertRevision = (Get-Item Function:\Assert-Revision).ScriptBlock
$originalUpdateChecksums = (Get-Item Function:\Update-ManagedChecksumsIfPresent).ScriptBlock
$originalRecoveryBoundary = (Get-Item Function:\Assert-RevisionStageRecoveryChecksumBoundary).ScriptBlock
$originalResolveNode = (Get-Item Function:\Resolve-NodeExecutable).ScriptBlock
$originalInspectDatabase = (Get-Item Function:\Invoke-DatabaseInspection).ScriptBlock
$originalValidatedRevisionFiles = (Get-Item Function:\Get-ValidatedRevisionChecksumFiles).ScriptBlock
$script:checksumCalls = 0
$script:checksumFailureMode = 'none'
$script:semanticFixtureMode = 'normal'
$script:legacyDevelopmentMode = $false

try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'maintenance') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'revisions') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'data') -Force | Out-Null

    # The recovery exception is narrower than ordinary package verification:
    # every pre-existing immutable checksum must still match, and the only new
    # immutable files may be beneath the one journaled revision directory.
    $boundaryFixture = Join-Path $fixture 'boundary'
    $boundaryRevision = ('7' * 64)
    New-Item -ItemType Directory -Path (Join-Path $boundaryFixture 'data') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $boundaryFixture "revisions\$boundaryRevision") -Force | Out-Null
    $boundaryActiveRevision = ('5' * 64)
    Set-ActiveRevisionPointer -ProjectRoot $boundaryFixture -ActiveRevision $boundaryActiveRevision -PreviousRevision $null -SchemaVersion 2 -ActivatedAt '2026-07-18T10:00:00.0000000Z' | Out-Null
    [IO.File]::WriteAllText((Join-Path $boundaryFixture 'trusted-script.ps1'), 'trusted script')
    [IO.File]::WriteAllText((Join-Path $boundaryFixture "revisions\$boundaryRevision\candidate.bin"), 'pending candidate')
    $boundaryOldReport = New-StageFixtureReport -Revision $boundaryRevision -CorpusRevision ('c' * 64) -BaseRevision $boundaryActiveRevision -BaseCorpusRevision ('4' * 64)
    $boundaryOldReport.staged_at = '2026-07-18T10:01:00.0000000Z'
    $boundaryReportPath = Join-Path $boundaryFixture "revisions\$boundaryRevision\stage-report.json"
    Write-StagedRevisionReportValue -RevisionRoot (Split-Path -Parent $boundaryReportPath) -StageReport $boundaryOldReport | Out-Null
    $boundaryOldReportFileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $boundaryReportPath).Hash.ToLowerInvariant()
    $boundaryNewReport = New-StageFixtureReport -Revision $boundaryRevision -CorpusRevision ('c' * 64) -BaseRevision $boundaryActiveRevision -BaseCorpusRevision ('4' * 64)
    $boundaryNewReport.staged_at = '2026-07-18T10:02:00.0000000Z'
    $boundaryJournal = [pscustomobject]@{
        index_revision=$boundaryRevision;destination_existed=$true
        base_index_revision=$boundaryActiveRevision;allow_legacy_active=$false
        prior_stage_report_file_sha256=$boundaryOldReportFileSha
        stage_report_file_sha256=(Get-StagedRevisionReportFileSha256 -StageReport $boundaryNewReport)
    }
    $boundaryRequired = @(
        '.mql5-chm-package-root','runtime/node.exe','runtime/LICENSE','app/server.mjs','app/indexer.mjs',
        'config/mql5-image-policy.json','config/mql5-query-expansions.json','maintenance/.update.lock',
        'Install-Codex.ps1','Rebuild-Index.ps1','Uninstall-Codex.ps1','Package-Portable.ps1','Check-DocumentationUpdates.ps1','Update-Documentation.ps1','Rollback-Documentation.ps1','README.md','SPEC.md',
        'scripts/build.mjs','scripts/Generate-BundledNotices.mjs','scripts/inspect-database.mjs','scripts/Common.ps1','scripts/IndexMaintenance.ps1','scripts/SevenZipRuntime.ps1','scripts/StageInstallRecovery.ps1','scripts/Smoke-Test-McpServer.mjs','scripts/Compare-OfficialDocumentationHashes.ps1','scripts/Test-DocumentationFreshness.ps1','scripts/Test-PowerShellSyntax.ps1','scripts/Invoke-PowerShellTestSuite.ps1','scripts/Install-Codex.ps1','scripts/Rebuild-Index.ps1','scripts/Uninstall-Codex.ps1','scripts/Package-Portable.ps1','scripts/Check-DocumentationUpdates.ps1','scripts/Update-Documentation.ps1','scripts/Rollback-Documentation.ps1','scripts\Test-Maintenance.ps1','scripts\Test-StageInstallRecovery.ps1',
        'licenses/7ZIP-LICENSE.txt','licenses/BUNDLED-NODE-NOTICES.txt','licenses/bundled-node-dependencies.json','licenses/bundled-node-notice-overrides.json','licenses/overrides/boolbase-1.0.0.txt','licenses/CHEERIO-LICENSE.txt','licenses/ESBUILD-LICENSE.txt','licenses/ICONV-LITE-LICENSE.txt','licenses/JPEG-JS-LICENSE.txt','licenses/MCP-SDK-LICENSE.txt','licenses/NODE-LICENSE.txt','licenses/THIRD-PARTY-NOTICES.md','licenses/ZOD-LICENSE.txt','tools/7z.exe','tools/7z.dll','tools/7zip.provenance.json'
    )
    foreach ($relative in $boundaryRequired) {
        $path = Join-Path $boundaryFixture $relative.Replace('/','\'); $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($relative -eq '.mql5-chm-package-root') { [IO.File]::WriteAllText($path, "mql5-chm-portable-package-v1`n", (New-Object Text.UTF8Encoding($false))) }
        elseif ($relative -eq 'maintenance/.update.lock') { [IO.File]::WriteAllBytes($path, (New-Object byte[] 0)) }
        else { [IO.File]::WriteAllText($path, "fixture-$relative") }
    }
    $boundaryLines = @('data/active.json','trusted-script.ps1',"revisions/$boundaryRevision/stage-report.json") + $boundaryRequired | ForEach-Object {
        $path = Join-Path $boundaryFixture $_.Replace('/','\')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()) *$_"
    }
    [IO.File]::WriteAllLines((Join-Path $boundaryFixture 'checksums.sha256'), $boundaryLines, (New-Object Text.UTF8Encoding($false)))
    try {
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode='Index',[switch]$AllowLegacy) return @() }
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $boundaryFixture -Journal $boundaryJournal | Out-Null
    } finally { Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles }

    # Existing-destination interruption: the new journaled report bytes were
    # published, but checksums still bind the exact old report. This one
    # journal-bound old->new mismatch must be recoverable; any third value must
    # remain rejected.
    Write-StagedRevisionReportValue -RevisionRoot (Split-Path -Parent $boundaryReportPath) -StageReport $boundaryNewReport | Out-Null
    try {
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode='Index',[switch]$AllowLegacy) return @() }
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $boundaryFixture -Journal $boundaryJournal | Out-Null
    } finally { Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles }
    [IO.File]::WriteAllText($boundaryReportPath, 'neither old nor journaled new report')
    $thirdReportRejected = $false
    try {
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode='Index',[switch]$AllowLegacy) return @() }
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $boundaryFixture -Journal $boundaryJournal | Out-Null
    } catch { $thirdReportRejected = $true } finally { Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles }
    Assert-StageFixture -Condition $thirdReportRejected -Message 'Stage recovery accepted a report checksum outside the exact journal-bound old-to-new transition.'
    Write-StagedRevisionReportValue -RevisionRoot (Split-Path -Parent $boundaryReportPath) -StageReport $boundaryOldReport | Out-Null
    [IO.File]::WriteAllText((Join-Path $boundaryFixture 'trusted-script.ps1'), 'tampered script')
    $boundaryTamperRejected = $false
    try {
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode='Index',[switch]$AllowLegacy) return @() }
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $boundaryFixture -Journal $boundaryJournal | Out-Null
    } catch { $boundaryTamperRejected = $true } finally { Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles }
    Assert-StageFixture -Condition $boundaryTamperRejected -Message 'Stage recovery accepted a changed pre-existing immutable checksum.'
    [IO.File]::WriteAllText((Join-Path $boundaryFixture 'trusted-script.ps1'), 'trusted script')
    [IO.File]::WriteAllText((Join-Path $boundaryFixture 'unlisted-outside-candidate.txt'), 'untrusted extra')
    $boundaryExtraRejected = $false
    try {
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode='Index',[switch]$AllowLegacy) return @() }
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $boundaryFixture -Journal $boundaryJournal | Out-Null
    } catch { $boundaryExtraRejected = $true } finally { Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles }
    Assert-StageFixture -Condition $boundaryExtraRejected -Message 'Stage recovery accepted an unlisted immutable file outside the pending candidate.'
    Remove-Item -LiteralPath (Join-Path $boundaryFixture 'unlisted-outside-candidate.txt') -Force

    # Index identity deliberately excludes retrieval/build timestamps. Build
    # two fully validated current trees from identical bytes, retain the older
    # installed immutable tree, and bind recovery to that exact winner.
    $sameIndexRoot = Join-Path $fixture 'same index different manifest'
    foreach ($directory in @('data','maintenance','revisions','scripts','src','config','node_modules\esbuild')) { New-Item -ItemType Directory -Path (Join-Path $sameIndexRoot $directory) -Force | Out-Null }
    foreach ($relative in @('scripts\build.mjs','package.json','src\server.mjs','src\indexer.mjs','config\mql5-query-expansions.json','config\mql5-image-policy.json','scripts\inspect-database.mjs','node_modules\esbuild\package.json')) { [IO.File]::WriteAllText((Join-Path $sameIndexRoot $relative), "same-index-fixture-$relative") }
    $sameIndexCandidateTree = New-CurrentStageRevisionTree -Root (Join-Path $sameIndexCandidateWork 'revision') -Seed 'same-index' -Timestamp '2026-07-18T10:42:00.0000000Z'
    $sameIndexDestination = Join-Path $sameIndexRoot "revisions\$($sameIndexCandidateTree.Index)"
    $sameIndexInstalledTree = New-CurrentStageRevisionTree -Root $sameIndexDestination -Seed 'same-index' -Timestamp '2026-07-18T10:41:00.0000000Z'
    Assert-StageFixture -Condition ([string]$sameIndexInstalledTree.Index -ceq [string]$sameIndexCandidateTree.Index -and [string]$sameIndexInstalledTree.Corpus -ceq [string]$sameIndexCandidateTree.Corpus) -Message 'Same-index fixture did not produce identical database and corpus identities.'
    $candidateTreeDigest = Get-StagedCandidateTreeSha256 -Root $sameIndexCandidateTree.Root -ConfinementRoot $sameIndexCandidateWork
    $installedTreeDigest = Get-StagedCandidateTreeSha256 -Root $sameIndexInstalledTree.Root -ConfinementRoot $sameIndexRoot
    Assert-StageFixture -Condition ($candidateTreeDigest -cne $installedTreeDigest) -Message 'Same-index fixture manifests did not differ as required by the regression.'
    $sameIndexCandidate = [pscustomobject]@{Revision=$sameIndexCandidateTree.Index;IndexRevision=$sameIndexCandidateTree.Index;CorpusRevision=$sameIndexCandidateTree.Corpus;Root=$sameIndexCandidateTree.Root;WorkRoot=$sameIndexCandidateWork}
    $initialTemplate = New-StageFixtureReport -Revision $sameIndexCandidateTree.Index -CorpusRevision $sameIndexCandidateTree.Corpus -BaseRevision ('a'*64) -BaseCorpusRevision ('b'*64)
    $initialSourceCounts = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) { $initialSourceCounts[$definition.Id] = [ordered]@{base=0;candidate=$definition.TopicCount;delta=$definition.TopicCount} }
    $sameIndexReport = New-StagedRevisionReportValue -Revision $sameIndexCandidateTree.Index -CorpusRevision $sameIndexCandidateTree.Corpus -BaseRevision $null -BaseCorpusRevision $null -SourceTopicCounts $initialSourceCounts -Changes $initialTemplate.changes -AssetChanges $initialTemplate.asset_changes -RequiredRankings $initialTemplate.required_rankings -StagedAt '2026-07-18T10:43:00.0000000Z'
    $installedManifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sameIndexDestination 'manifest.json')).Hash.ToLowerInvariant()
    Start-RevisionStageInstall -ProjectRoot $sameIndexRoot -Operation rebuild -Candidate $sameIndexCandidate -StageReport $sameIndexReport -AllowLegacyActive:$false | Out-Null
    $sameIndexJournal = Get-RevisionStageJournal -ProjectRoot $sameIndexRoot
    Assert-StageFixture -Condition ([bool]$sameIndexJournal.destination_existed -and [string]$sameIndexJournal.candidate_tree_sha256 -ceq $installedTreeDigest) -Message 'Same-index re-stage journal did not bind recovery to the retained installed tree.'
    Install-RevisionCandidate -ProjectRoot $sameIndexRoot -Candidate $sameIndexCandidate | Out-Null
    try {
        function Resolve-NodeExecutable { param([string]$ProjectRoot,[switch]$RequireBundled) return 'fixture-node.exe' }
        function Invoke-DatabaseInspection {
            param([string]$NodePath,[string]$DatabasePath,[switch]$RequireAssets)
            $rankings=[pscustomobject]@{};foreach($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')){$rankings|Add-Member -NotePropertyName $query -NotePropertyValue ([pscustomobject]@{title=$query;source='mql5'})}
            return [pscustomobject]@{topics=[pscustomobject]@{};assets=[pscustomobject]@{};asset_summary=[pscustomobject]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0};ranking=$rankings;metadata=[pscustomobject]@{corpus_sha256=$sameIndexCandidateTree.Corpus;index_contract=$script:IndexContract;image_policy_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';asset_catalog_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';asset_tree_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'};asset_count=0;topic_asset_count=0}
        }
        $sameIndexRecovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $sameIndexRoot
    } finally {
        Set-Item Function:\Resolve-NodeExecutable -Value $originalResolveNode
        Set-Item Function:\Invoke-DatabaseInspection -Value $originalInspectDatabase
    }
    Assert-StageFixture -Condition ([string]$sameIndexRecovered.State -ceq 'completed' -and (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sameIndexDestination 'manifest.json')).Hash.ToLowerInvariant() -ceq $installedManifestSha) -Message 'Same-index re-stage did not retain and recover against the original immutable destination manifest.'

    # A portable schema-2 active revision is rollback-supported, but only the
    # exact active base named by a durable stage journal may relax the current-
    # schema requirement. Exercise the real checksum boundary and then the
    # recovery path with a published candidate from that legacy base.
    $legacyPortableRoot = Join-Path $fixture 'portable legacy base'
    foreach ($directory in @('data','maintenance','revisions')) { New-Item -ItemType Directory -Path (Join-Path $legacyPortableRoot $directory) -Force | Out-Null }
    $legacyPortable = New-LegacyStageRevisionFixture -Root $legacyPortableRoot -Seed 'portable-legacy-stage'
    $legacyPortableIndexed = Install-LegacyRevisionIndexIdentity -ProjectRoot $legacyPortableRoot -LegacyCorpusRevision $legacyPortable.Corpus
    Set-ActiveRevisionPointer -ProjectRoot $legacyPortableRoot -ActiveRevision $legacyPortable.Index -PreviousRevision $null -SchemaVersion 2 -ActivatedAt '2026-07-18T10:30:00.0000000Z' | Out-Null
    foreach ($relative in $boundaryRequired) {
        $path = Join-Path $legacyPortableRoot $relative.Replace('/','\')
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($relative -eq '.mql5-chm-package-root') { [IO.File]::WriteAllText($path, "mql5-chm-portable-package-v1`n", (New-Object Text.UTF8Encoding($false))) }
        elseif ($relative -eq 'maintenance/.update.lock') { [IO.File]::WriteAllBytes($path, (New-Object byte[] 0)) }
        else { [IO.File]::WriteAllText($path, "legacy-fixture-$relative") }
    }
    $legacyChecksumLines = @(Get-ChildItem -LiteralPath $legacyPortableRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($legacyPortableRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()) *$relative"
    })
    [IO.File]::WriteAllLines((Join-Path $legacyPortableRoot 'checksums.sha256'), $legacyChecksumLines, (New-Object Text.UTF8Encoding($false)))

    $legacyCandidateRevision = ('2' * 64)
    $legacyCandidateCorpus = ('1' * 64)
    $legacyCandidateRoot = Join-Path $legacyCandidateWork 'revision'
    New-Item -ItemType Directory -Path $legacyCandidateRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyCandidateRoot 'manifest.json'), 'fixture manifest')
    [IO.File]::WriteAllText((Join-Path $legacyCandidateRoot 'mql5-docs.sqlite'), 'fixture database')
    $legacyCandidate = [pscustomobject]@{Revision=$legacyCandidateRevision;IndexRevision=$legacyCandidateRevision;CorpusRevision=$legacyCandidateCorpus;Root=$legacyCandidateRoot;WorkRoot=$legacyCandidateWork}
    $legacyReport = New-StageFixtureReport -Revision $legacyCandidateRevision -CorpusRevision $legacyCandidateCorpus -BaseRevision $legacyPortable.Index -BaseCorpusRevision $legacyPortable.Corpus
    $script:legacyPortableChecksumCalls = 0
    try {
        function Assert-Revision {
            param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$RevisionConfinementRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent)
            if ($Revision -ceq $legacyCandidateRevision) {
                $validatedRoot = if ([string]::IsNullOrWhiteSpace($RevisionRoot)) { Join-Path $ProjectRoot "revisions\$Revision" } else { $RevisionRoot }
                return [pscustomobject]@{Root=$validatedRoot;Revision=$Revision;IndexRevision=$Revision;CorpusRevision=$legacyCandidateCorpus;ManifestSchemaVersion=3;Manifest=(New-StageFixtureManifest -Revision $Revision -CorpusRevision $legacyCandidateCorpus);DatabasePath=(Join-Path $validatedRoot 'mql5-docs.sqlite')}
            }
            return & $originalAssertRevision -ProjectRoot $ProjectRoot -Revision $Revision -RevisionRoot $RevisionRoot -RevisionConfinementRoot $RevisionConfinementRoot -IdentityMode $IdentityMode -RequireCurrent:$RequireCurrent
        }
        function Resolve-NodeExecutable { param([string]$ProjectRoot,[switch]$RequireBundled) return 'fixture-node.exe' }
        function Invoke-DatabaseInspection {
            param([string]$NodePath,[string]$DatabasePath,[switch]$RequireAssets)
            $rankings=[pscustomobject]@{};foreach($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')){$rankings|Add-Member -NotePropertyName $query -NotePropertyValue ([pscustomobject]@{title=$query;source='mql5'})}
            return [pscustomobject]@{topics=[pscustomobject]@{};assets=[pscustomobject]@{};asset_summary=[pscustomobject]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0};ranking=$rankings;metadata=[pscustomobject]@{corpus_sha256=$legacyCandidateCorpus;index_contract=$script:IndexContract;image_policy_sha256=('e'*64);asset_catalog_sha256=('e'*64);asset_tree_sha256=('e'*64)};asset_count=0;topic_asset_count=0}
        }
        function Update-ManagedChecksumsIfPresent { param([string]$ProjectRoot,[string[]]$ChangedRelativePaths=@(),[switch]$AllowLegacyActive) $script:legacyPortableChecksumCalls++ }

        Start-RevisionStageInstall -ProjectRoot $legacyPortableRoot -Operation rebuild -Candidate $legacyCandidate -StageReport $legacyReport -AllowLegacyActive | Out-Null
        Install-RevisionCandidate -ProjectRoot $legacyPortableRoot -Candidate $legacyCandidate | Out-Null
        $legacyJournal = Get-RevisionStageJournal -ProjectRoot $legacyPortableRoot
        Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $legacyPortableRoot -Journal $legacyJournal | Out-Null
        $legacyPermissionRemoved = ConvertFrom-Json -InputObject ($legacyJournal | ConvertTo-Json -Depth 20)
        $legacyPermissionRemoved.allow_legacy_active = $false
        $legacyWithoutPermissionRejected = $false
        try { Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $legacyPortableRoot -Journal $legacyPermissionRemoved | Out-Null } catch { $legacyWithoutPermissionRejected = $true }
        Assert-StageFixture -Condition $legacyWithoutPermissionRejected -Message 'Portable recovery accepted a legacy active base without its exact journal permission.'
        $legacyWrongBase = ConvertFrom-Json -InputObject ($legacyJournal | ConvertTo-Json -Depth 20)
        $legacyWrongBase.base_index_revision = ('0' * 64)
        $legacyWrongBaseRejected = $false
        try { Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $legacyPortableRoot -Journal $legacyWrongBase | Out-Null } catch { $legacyWrongBaseRejected = $true }
        Assert-StageFixture -Condition $legacyWrongBaseRejected -Message 'Portable recovery allowed legacy-active permission for a base other than the exact active revision.'
        $legacyRecovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $legacyPortableRoot
        Assert-StageFixture -Condition ([string]$legacyRecovered.State -ceq 'completed' -and $script:legacyPortableChecksumCalls -eq 1 -and -not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $legacyPortableRoot))) -Message 'Portable schema-2 active-base staging did not recover through the real checksum boundary.'
    } finally {
        Set-Item Function:\Assert-Revision -Value $originalAssertRevision
        Set-Item Function:\Update-ManagedChecksumsIfPresent -Value $originalUpdateChecksums
        Set-Item Function:\Resolve-NodeExecutable -Value $originalResolveNode
        Set-Item Function:\Invoke-DatabaseInspection -Value $originalInspectDatabase
        Remove-Variable -Name legacyPortableChecksumCalls -Scope Script -ErrorAction SilentlyContinue
    }

    # A schema-3 revision on a supported rollback-only index contract is also a
    # supported noncurrent base. Reuse the real portable checksum boundary and
    # complete a v1->current-contract recovery, with permission bound to the
    # exact active index rather than merely to manifest schema 2.
    $oldContract = @($script:SupportedIndexContracts | Where-Object { $_ -cne $script:IndexContract } | Select-Object -First 1)
    Assert-StageFixture -Condition ($oldContract.Count -eq 1) -Message 'Supported-contract recovery fixture could not identify a rollback-only index contract.'
    $supportedBaseTree = New-CurrentStageRevisionTree -Root (Join-Path $supportedBaseWork 'revision') -Seed 'supported-contract-corpus' -DatabaseSeed 'supported-contract-v1' -Timestamp '2026-07-18T10:50:00.0000000Z' -IndexContract ([string]$oldContract[0])
    $supportedBaseDestination = Join-Path $legacyPortableRoot "revisions\$($supportedBaseTree.Index)"
    Copy-Item -LiteralPath $supportedBaseTree.Root -Destination $supportedBaseDestination -Recurse -Force
    $supportedCandidateTree = New-CurrentStageRevisionTree -Root (Join-Path $supportedCandidateWork 'revision') -Seed 'supported-contract-corpus' -DatabaseSeed 'supported-contract-current' -Timestamp '2026-07-18T10:51:00.0000000Z'
    Assert-StageFixture -Condition ([string]$supportedBaseTree.Corpus -ceq [string]$supportedCandidateTree.Corpus -and [string]$supportedBaseTree.Index -cne [string]$supportedCandidateTree.Index) -Message 'Supported-contract fixture did not retain one corpus while changing index contract identity.'
    Set-ActiveRevisionPointer -ProjectRoot $legacyPortableRoot -ActiveRevision $supportedBaseTree.Index -PreviousRevision $legacyPortable.Index -SchemaVersion 2 -ActivatedAt '2026-07-18T10:52:00.0000000Z' | Out-Null
    $supportedChecksumLines = @(Get-ChildItem -LiteralPath $legacyPortableRoot -Recurse -File -Force | Where-Object {
        $relative = $_.FullName.Substring($legacyPortableRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        @('checksums.sha256','maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -notcontains $relative
    } | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($legacyPortableRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()) *$relative"
    })
    [IO.File]::WriteAllLines((Join-Path $legacyPortableRoot 'checksums.sha256'), $supportedChecksumLines, (New-Object Text.UTF8Encoding($false)))
    $supportedCandidate = [pscustomobject]@{Revision=$supportedCandidateTree.Index;IndexRevision=$supportedCandidateTree.Index;CorpusRevision=$supportedCandidateTree.Corpus;Root=$supportedCandidateTree.Root;WorkRoot=$supportedCandidateWork}
    $supportedReport = New-StageFixtureReport -Revision $supportedCandidateTree.Index -CorpusRevision $supportedCandidateTree.Corpus -BaseRevision $supportedBaseTree.Index -BaseCorpusRevision $supportedBaseTree.Corpus
    Start-RevisionStageInstall -ProjectRoot $legacyPortableRoot -Operation rebuild -Candidate $supportedCandidate -StageReport $supportedReport -AllowLegacyActive | Out-Null
    Install-RevisionCandidate -ProjectRoot $legacyPortableRoot -Candidate $supportedCandidate | Out-Null
    $supportedJournal = Get-RevisionStageJournal -ProjectRoot $legacyPortableRoot
    Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $legacyPortableRoot -Journal $supportedJournal | Out-Null
    $supportedPermissionRemoved = ConvertFrom-Json -InputObject ($supportedJournal | ConvertTo-Json -Depth 20)
    $supportedPermissionRemoved.allow_legacy_active = $false
    $supportedWithoutPermissionRejected = $false
    try { Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $legacyPortableRoot -Journal $supportedPermissionRemoved | Out-Null } catch { $supportedWithoutPermissionRejected = $true }
    Assert-StageFixture -Condition $supportedWithoutPermissionRejected -Message 'Portable recovery treated a rollback-only schema-3 contract as current without exact journal permission.'
    $script:supportedContractChecksumCalls = 0
    try {
        function Resolve-NodeExecutable { param([string]$ProjectRoot,[switch]$RequireBundled) return 'fixture-node.exe' }
        function Invoke-DatabaseInspection {
            param([string]$NodePath,[string]$DatabasePath,[switch]$RequireAssets)
            $rankings=[pscustomobject]@{};foreach($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')){$rankings|Add-Member -NotePropertyName $query -NotePropertyValue ([pscustomobject]@{title=$query;source='mql5'})}
            return [pscustomobject]@{topics=[pscustomobject]@{};assets=[pscustomobject]@{};asset_summary=[pscustomobject]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0};ranking=$rankings;metadata=[pscustomobject]@{corpus_sha256=$supportedCandidateTree.Corpus;index_contract=$script:IndexContract;image_policy_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';asset_catalog_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';asset_tree_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'};asset_count=0;topic_asset_count=0}
        }
        function Update-ManagedChecksumsIfPresent { param([string]$ProjectRoot,[string[]]$ChangedRelativePaths=@(),[switch]$AllowLegacyActive) $script:supportedContractChecksumCalls++ }
        $supportedContractRecovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $legacyPortableRoot
    } finally {
        Set-Item Function:\Update-ManagedChecksumsIfPresent -Value $originalUpdateChecksums
        Set-Item Function:\Resolve-NodeExecutable -Value $originalResolveNode
        Set-Item Function:\Invoke-DatabaseInspection -Value $originalInspectDatabase
    }
    Assert-StageFixture -Condition ([string]$supportedContractRecovered.State -ceq 'completed' -and $script:supportedContractChecksumCalls -eq 1) -Message 'Portable recovery could not complete from an exact supported rollback-only schema-3 contract base.'
    Remove-Variable -Name supportedContractChecksumCalls -Scope Script -ErrorAction SilentlyContinue

    function Assert-Revision {
        param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$RevisionConfinementRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent)
        $validatedRoot = if ([string]::IsNullOrWhiteSpace($RevisionRoot)) { Join-Path $ProjectRoot "revisions\$Revision" } else { $RevisionRoot }
        if ($script:legacyDevelopmentMode -and $Revision -ceq ('a' * 64) -and [string]::IsNullOrWhiteSpace($RevisionRoot) -and -not (Test-Path -LiteralPath $validatedRoot -PathType Container)) {
            # Construct the pre-fix restart state: the durable journal already
            # names the database/index identity while the schema-1 pointer and
            # only physical revision directory are still corpus-keyed.
            $validatedRoot = Join-Path $ProjectRoot ('revisions\' + ('b' * 64))
        }
        if (-not (Test-Path -LiteralPath $validatedRoot -PathType Container)) { throw "Mock revision is missing: $validatedRoot" }
        $isLegacyCorpusBase = $script:legacyDevelopmentMode -and $Revision -ceq ('b' * 64)
        $isBase = $Revision -ceq ('a' * 64) -or $isLegacyCorpusBase
        $corpus = if ($isBase) { ('b' * 64) } else { ('c' * 64) }
        $manifestSchema = if($script:legacyDevelopmentMode -and $isBase){2}else{3}
        $mockIndexRevision = if($isLegacyCorpusBase){('a'*64)}else{$Revision}
        [pscustomobject]@{
            Root=$validatedRoot;Revision=$Revision;IndexRevision=$mockIndexRevision;CorpusRevision=$corpus
            ManifestSchemaVersion=$manifestSchema;Manifest=(New-StageFixtureManifest -Revision $mockIndexRevision -CorpusRevision $corpus -SchemaVersion $manifestSchema)
            DatabasePath=if($isBase){'fixture-base.sqlite'}elseif($Revision -ceq ('6' * 64)){'fixture-reduction-candidate.sqlite'}else{'fixture-candidate.sqlite'}
        }
    }
    function Assert-RevisionStageRecoveryChecksumBoundary { param([string]$ProjectRoot,[object]$Journal) return $true }
    function Resolve-NodeExecutable { param([string]$ProjectRoot,[switch]$RequireBundled) return 'fixture-node.exe' }
    function Invoke-DatabaseInspection {
        param([string]$NodePath,[string]$DatabasePath,[switch]$RequireAssets)
        $rankings=[pscustomobject]@{}
        foreach($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')){$rankings|Add-Member -NotePropertyName $query -NotePropertyValue ([pscustomobject]@{title=$query;source='mql5'})}
        $hasBaseAsset = $script:semanticFixtureMode -eq 'reduction' -and $DatabasePath -eq 'fixture-base.sqlite'
        $assets = if ($hasBaseAsset) { [pscustomobject]@{'mql5:asset:aaaaaaaaaaaaaaaaaaaaaaaa'=[pscustomobject]@{sha256=('a'*64);exposure='exposed';occurrence_count=1}} } else { [pscustomobject]@{} }
        $summary = if ($hasBaseAsset) {
            [pscustomobject]@{cataloged_count=1;exposed_count=1;excluded_count=0;occurrence_count=1;exposed_occurrence_count=1;total_bytes=4}
        } else {
            [pscustomobject]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0}
        }
        return [pscustomobject]@{
            topics=[pscustomobject]@{};assets=$assets
            asset_summary=$summary
            ranking=$rankings
            metadata=[pscustomobject]@{corpus_sha256=('c'*64);index_contract=$script:IndexContract;image_policy_sha256=('e'*64);asset_catalog_sha256=('e'*64);asset_tree_sha256=('e'*64)}
            asset_count=0;topic_asset_count=0
        }
    }
    function Update-ManagedChecksumsIfPresent {
        param([string]$ProjectRoot,[string[]]$ChangedRelativePaths=@(),[switch]$AllowLegacyActive)
        $script:checksumCalls++
        if ($script:checksumFailureMode -eq 'before-replace') { throw 'Injected failure before checksum replacement.' }
        if ($script:checksumFailureMode -eq 'after-replace') {
            [IO.File]::WriteAllText((Join-Path $ProjectRoot 'checksum-replaced.marker'), 'replaced')
            throw 'Injected failure after checksum replacement.'
        }
        [IO.File]::WriteAllText((Join-Path $ProjectRoot 'checksum-replaced.marker'), 'replaced')
    }

    $baseRevision = ('a' * 64)
    $baseCorpus = ('b' * 64)
    $candidateRevision = ('d' * 64)
    $candidateCorpus = ('c' * 64)
    New-Item -ItemType Directory -Path (Join-Path $fixture "revisions\$baseRevision") -Force | Out-Null
    Write-JsonAtomic -Path (Join-Path $fixture "revisions\$baseRevision\manifest.json") -Value (New-StageFixtureManifest -Revision $baseRevision -CorpusRevision $baseCorpus) -ConfinementRoot $fixture
    Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $baseRevision -PreviousRevision $null -SchemaVersion 2 -ActivatedAt '2026-07-18T11:00:00.0000000Z' | Out-Null

    $reportWritingRevision=('e'*64)
    $reportWritingRoot=Join-Path $fixture "revisions\$reportWritingRevision"
    New-Item -ItemType Directory -Path $reportWritingRoot|Out-Null
    Write-JsonAtomic -Path (Join-Path $reportWritingRoot 'manifest.json') -Value (New-StageFixtureManifest -Revision $reportWritingRevision -CorpusRevision $candidateCorpus) -ConfinementRoot $fixture
    $reportWritingManifestHash=(Get-FileHash -LiteralPath (Join-Path $reportWritingRoot 'manifest.json') -Algorithm SHA256).Hash
    $reportWritingPath=Join-Path $reportWritingRoot '.stage-report.json.replace.writing-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    [IO.File]::WriteAllText($reportWritingPath,'{"partial":',(New-Object Text.UTF8Encoding($false)))
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-StageFixture -Condition ((Test-Path -LiteralPath $reportWritingRoot -PathType Container) -and (Get-FileHash -LiteralPath (Join-Path $reportWritingRoot 'manifest.json') -Algorithm SHA256).Hash -ceq $reportWritingManifestHash -and -not (Test-Path -LiteralPath $reportWritingPath) -and -not (Test-Path -LiteralPath (Join-Path $reportWritingRoot 'stage-report.json'))) -Message 'Interrupted first stage-report write damaged its revision or was not reclaimed before publication.'
    Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path $reportWritingRoot

    # Red/green interruption point 1: the intent was durable but publication
    # never happened. Recovery must cancel only that exact pending intent.
    $candidate = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision -CorpusRevision $candidateCorpus
    $report = New-StageFixtureReport -Revision $candidateRevision -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    $transitionTarget = ('7' * 64)
    New-Item -ItemType Directory -Path (Join-Path $fixture "revisions\$transitionTarget") -Force | Out-Null
    Start-RevisionTransition -ProjectRoot $fixture -Operation apply -FromRevision $baseRevision -ToRevision $transitionTarget | Out-Null
    $overlappingStageRejected = $false
    try { Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $candidate -StageReport $report -AllowLegacyActive:$false | Out-Null } catch { $overlappingStageRejected = $true }
    Assert-StageFixture -Condition ($overlappingStageRejected -and -not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture))) -Message 'Direct stage-install caller overlapped a pending revision transition.'
    $pendingTransitionFixture = Get-RevisionTransition -ProjectRoot $fixture
    Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $pendingTransitionFixture
    Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path (Join-Path $fixture "revisions\$transitionTarget")
    $nonBooleanReport = ConvertFrom-Json -InputObject ($report | ConvertTo-Json -Depth 20)
    $nonBooleanReport.validation_passed = 'true'
    $nonBooleanReportRejected = $false
    try { Assert-StagedRevisionReportValue -StageReport $nonBooleanReport -ExpectedRevision $candidateRevision | Out-Null } catch { $nonBooleanReportRejected = $true }
    Assert-StageFixture -Condition $nonBooleanReportRejected -Message 'Current stage-report validation accepted a truthy non-Boolean validation_passed value.'

    $windowsPowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $crossHostReportPath = Join-Path $fixture 'cross-host-report.json'
    [IO.File]::WriteAllText($crossHostReportPath, (($report | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $crossHostDigestHelper = Join-Path $fixture 'cross-host-digest.ps1'
    [IO.File]::WriteAllText($crossHostDigestHelper, @'
param([string]$ScriptsRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
. (Join-Path $ScriptsRoot 'IndexMaintenance.ps1')
$report=Read-JsonFile -Path $ReportPath -Context 'cross-host report'
[Console]::Out.Write((Get-CanonicalJsonValueSha256 -Value $report))
'@, (New-Object Text.UTF8Encoding($false)))
    $ps5Digest = Invoke-NativeCapture -FilePath $windowsPowerShell.Source -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$crossHostDigestHelper,$PSScriptRoot,$crossHostReportPath)
    Assert-StageFixture -Condition ($ps5Digest.ExitCode -eq 0 -and $ps5Digest.Text.Trim() -ceq (Get-CanonicalJsonValueSha256 -Value $report)) -Message "PowerShell 5.1 and PowerShell 7 produced different canonical stage-report digests. $($ps5Digest.Text)"

    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $candidate -StageReport $report -AllowLegacyActive:$false | Out-Null
    $booleanJournal = Get-RevisionStageJournal -ProjectRoot $fixture
    $nonBooleanJournal = ConvertFrom-Json -InputObject ($booleanJournal | ConvertTo-Json -Depth 20)
    $nonBooleanJournal.stage_report.validation_passed = 'true'
    $nonBooleanJournal.stage_report_canonical_sha256 = Get-CanonicalJsonValueSha256 -Value $nonBooleanJournal.stage_report
    $nonBooleanJournal.stage_report_file_sha256 = Get-StagedRevisionReportFileSha256 -StageReport $nonBooleanJournal.stage_report
    Write-JsonAtomic -Path (Get-RevisionStageJournalPath -ProjectRoot $fixture) -Value $nonBooleanJournal -ConfinementRoot $fixture
    $nonBooleanJournalRejected = $false
    try { Get-RevisionStageJournal -ProjectRoot $fixture | Out-Null } catch { $nonBooleanJournalRejected = $true }
    Assert-StageFixture -Condition $nonBooleanJournalRejected -Message 'Revision-stage journal validation accepted a truthy non-Boolean validation_passed value.'
    Write-JsonAtomic -Path (Get-RevisionStageJournalPath -ProjectRoot $fixture) -Value $booleanJournal -ConfinementRoot $fixture
    $journalPathForDebris = Get-RevisionStageJournalPath -ProjectRoot $fixture
    $journalBackup = Join-Path (Split-Path -Parent $journalPathForDebris) ('.revision-stage.json.replace.backup-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::Move($journalPathForDebris, $journalBackup)
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-StageFixture -Condition ((Test-Path -LiteralPath $journalPathForDebris -PathType Leaf) -and -not (Test-Path -LiteralPath $journalBackup)) -Message 'Target-specific revision-stage journal debris was not restored and validated.'
    $cancelled = Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture
    Assert-StageFixture -Condition ([string]$cancelled.State -ceq 'cancelled') -Message 'A pre-publication stage intent was not cancelled safely.'
    Assert-StageFixture -Condition (-not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture))) -Message 'Cancelled stage intent journal remained on disk.'
    Assert-StageFixture -Condition ($script:checksumCalls -eq 0) -Message 'Pre-publication cancellation attempted checksum reconciliation.'

    # Interruption point 2: atomic directory publication completed, but the
    # report did not. Recovery must reproduce the exact journaled report.
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $candidate -StageReport $report -AllowLegacyActive:$false | Out-Null
    $installedRoot = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate
    Assert-StageFixture -Condition (-not (Test-Path -LiteralPath (Join-Path $installedRoot 'stage-report.json'))) -Message 'Fixture unexpectedly published a stage report before the report boundary.'
    $recovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture
    Assert-StageFixture -Condition ([string]$recovered.State -ceq 'completed') -Message 'Post-publication recovery did not complete.'
    $recoveredReport = Assert-StagedRevisionReport -Path (Join-Path $installedRoot 'stage-report.json') -ExpectedRevision $candidateRevision
    Assert-StageFixture -Condition ([string]$recoveredReport.staged_at -ceq '2026-07-18T12:00:00.0000000Z') -Message 'Recovery regenerated a different stage report instead of the journaled report.'
    Assert-StageFixture -Condition ($script:checksumCalls -eq 1) -Message 'Post-publication recovery did not reconcile checksums exactly once.'

    # Interruption point 3: the report exists but checksum replacement has not
    # happened. Failure must retain the journal, and a retry must be idempotent.
    $candidateRevision2 = ('e' * 64)
    $candidate2 = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision2 -CorpusRevision $candidateCorpus
    $report2 = New-StageFixtureReport -Revision $candidateRevision2 -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation documentation-update -Candidate $candidate2 -StageReport $report2 -AllowLegacyActive:$false | Out-Null
    $installedRoot2 = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate2
    $crossHostWriteHelper = Join-Path $fixture 'cross-host-write.ps1'
    [IO.File]::WriteAllText($crossHostWriteHelper, @'
param([string]$ScriptsRoot,[string]$ProjectRoot,[string]$RevisionRoot)
$ErrorActionPreference='Stop'
. (Join-Path $ScriptsRoot 'IndexMaintenance.ps1')
$journal=Get-RevisionStageJournal -ProjectRoot $ProjectRoot
Write-StagedRevisionReportValue -RevisionRoot $RevisionRoot -StageReport $journal.stage_report | Out-Null
'@, (New-Object Text.UTF8Encoding($false)))
    $ps5Write = Invoke-NativeCapture -FilePath $windowsPowerShell.Source -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$crossHostWriteHelper,$PSScriptRoot,$fixture,$installedRoot2)
    Assert-StageFixture -Condition ($ps5Write.ExitCode -eq 0) -Message "Windows PowerShell could not write the journaled stage report for PowerShell 7 recovery. $($ps5Write.Text)"
    $script:checksumFailureMode = 'before-replace'
    $failedBeforeReplace = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $failedBeforeReplace = $true }
    Assert-StageFixture -Condition ($failedBeforeReplace -and (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture) -PathType Leaf)) -Message 'Failure before checksum replacement did not retain a retry journal.'
    $script:checksumFailureMode = 'none'
    Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null
    Assert-StageFixture -Condition (-not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture))) -Message 'Retry after pre-replacement failure did not clear the journal.'

    # Interruption point 4: checksum replacement completed before the process
    # died. Repeating reconciliation must be harmless and clear the journal.
    $candidateRevision3 = ('f' * 64)
    $candidate3 = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision3 -CorpusRevision $candidateCorpus
    $report3 = New-StageFixtureReport -Revision $candidateRevision3 -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $candidate3 -StageReport $report3 -AllowLegacyActive:$false | Out-Null
    Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate3 | Out-Null
    $script:checksumFailureMode = 'after-replace'
    $failedAfterReplace = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $failedAfterReplace = $true }
    Assert-StageFixture -Condition ($failedAfterReplace -and (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture) -PathType Leaf)) -Message 'Failure after checksum replacement did not retain a retry journal.'
    $script:checksumFailureMode = 'none'
    Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null
    Assert-StageFixture -Condition (-not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture))) -Message 'Retry after post-replacement failure did not clear the journal.'

    # Re-staging an identical already-installed revision refreshes only its
    # mutable stage report. If checksum replacement then fails, the next
    # process must accept exactly the journal-bound old->new report transition.
    $existingRevision = ('4' * 64)
    $existingCandidate = New-StageFixtureCandidate -Root $fixture -Revision $existingRevision -CorpusRevision $candidateCorpus
    $existingOldReport = New-StageFixtureReport -Revision $existingRevision -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    $existingOldReport.staged_at = '2026-07-18T12:10:00.0000000Z'
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $existingCandidate -StageReport $existingOldReport -AllowLegacyActive:$false | Out-Null
    $existingRoot = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $existingCandidate
    Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null
    $oldExistingFileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $existingRoot 'stage-report.json')).Hash.ToLowerInvariant()

    $existingCandidateAgain = New-StageFixtureCandidate -Root $fixture -Revision $existingRevision -CorpusRevision $candidateCorpus
    $existingNewReport = New-StageFixtureReport -Revision $existingRevision -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    $existingNewReport.staged_at = '2026-07-18T12:11:00.0000000Z'
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $existingCandidateAgain -StageReport $existingNewReport -AllowLegacyActive:$false | Out-Null
    Install-RevisionCandidate -ProjectRoot $fixture -Candidate $existingCandidateAgain | Out-Null
    $existingJournal = Get-RevisionStageJournal -ProjectRoot $fixture
    Assert-StageFixture -Condition ([string]$existingJournal.prior_stage_report_file_sha256 -ceq $oldExistingFileSha) -Message 'Existing-destination journal did not bind the exact prior report bytes.'
    $script:checksumFailureMode = 'before-replace'
    $existingRefreshInterrupted = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $existingRefreshInterrupted = $true }
    $newExistingFileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $existingRoot 'stage-report.json')).Hash.ToLowerInvariant()
    Assert-StageFixture -Condition ($existingRefreshInterrupted -and $newExistingFileSha -ceq [string]$existingJournal.stage_report_file_sha256 -and (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture) -PathType Leaf)) -Message 'Existing-destination interruption did not retain the exact journaled new report for retry.'
    $script:checksumFailureMode = 'none'
    $existingRefreshRecovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture
    Assert-StageFixture -Condition ([string]$existingRefreshRecovered.State -ceq 'completed' -and -not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture))) -Message 'Existing-destination report refresh could not recover after checksum failure.'

    # Semantic verification is deliberately before report replacement. A
    # forged restage must leave the old, already-proven report byte-for-byte.
    $semanticRevision = ('3' * 64)
    $semanticCandidate = New-StageFixtureCandidate -Root $fixture -Revision $semanticRevision -CorpusRevision $candidateCorpus
    $semanticOldReport = New-StageFixtureReport -Revision $semanticRevision -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation documentation-update -Candidate $semanticCandidate -StageReport $semanticOldReport -AllowLegacyActive:$false | Out-Null
    $semanticRoot = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $semanticCandidate
    Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null
    $semanticOldFileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $semanticRoot 'stage-report.json')).Hash.ToLowerInvariant()
    $semanticCandidateAgain = New-StageFixtureCandidate -Root $fixture -Revision $semanticRevision -CorpusRevision $candidateCorpus
    $semanticForgedReport = New-StageFixtureReport -Revision $semanticRevision -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    $semanticForgedReport.staged_at = '2026-07-18T12:12:00.0000000Z'
    $semanticForgedReport.required_rankings.OnTick.title = 'ForgedOnTick'
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation documentation-update -Candidate $semanticCandidateAgain -StageReport $semanticForgedReport -AllowLegacyActive:$false | Out-Null
    Install-RevisionCandidate -ProjectRoot $fixture -Candidate $semanticCandidateAgain | Out-Null
    $semanticRejectedBeforeMutation = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $semanticRejectedBeforeMutation = $true }
    $semanticAfterFileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $semanticRoot 'stage-report.json')).Hash.ToLowerInvariant()
    Assert-StageFixture -Condition ($semanticRejectedBeforeMutation -and $semanticAfterFileSha -ceq $semanticOldFileSha) -Message 'Semantic rejection occurred only after mutating the prior checksummed stage report.'
    Clear-RevisionStageJournal -ProjectRoot $fixture -ExpectedJournal (Get-RevisionStageJournal -ProjectRoot $fixture)

    # Only the exact tree proven before publication may pass recovery.
    $candidateRevision4 = ('9' * 64)
    $candidate4 = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision4 -CorpusRevision $candidateCorpus
    $report4 = New-StageFixtureReport -Revision $candidateRevision4 -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation rebuild -Candidate $candidate4 -StageReport $report4 -AllowLegacyActive:$false | Out-Null
    $installedRoot4 = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate4
    [IO.File]::WriteAllText((Join-Path $installedRoot4 'manifest.json'), 'tampered after validation')
    $tamperRejected = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $tamperRejected = $true }
    Assert-StageFixture -Condition ($tamperRejected -and (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $fixture) -PathType Leaf)) -Message 'Recovery blessed a candidate tree that differed from its journaled digest.'

    # A self-consistent rewrite of the mutable journal is insufficient. Even
    # when its report hash is recomputed, semantic verification against the
    # active base and inspected candidate must reject forged ranking evidence.
    Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path $installedRoot4
    Clear-RevisionStageJournal -ProjectRoot $fixture -ExpectedJournal (Get-RevisionStageJournal -ProjectRoot $fixture)
    $candidateRevision5 = ('8' * 64)
    $candidate5 = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision5 -CorpusRevision $candidateCorpus
    $report5 = New-StageFixtureReport -Revision $candidateRevision5 -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation documentation-update -Candidate $candidate5 -StageReport $report5 -AllowLegacyActive:$false | Out-Null
    Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate5 | Out-Null
    $forgedJournal = Get-RevisionStageJournal -ProjectRoot $fixture
    $forgedJournal.stage_report.required_rankings.OnTick.title = 'ForgedOnTick'
    $forgedJournal.stage_report_canonical_sha256 = Get-CanonicalJsonValueSha256 -Value $forgedJournal.stage_report
    $forgedJournal.stage_report_file_sha256 = Get-StagedRevisionReportFileSha256 -StageReport $forgedJournal.stage_report
    Write-JsonAtomic -Path (Get-RevisionStageJournalPath -ProjectRoot $fixture) -Value $forgedJournal -ConfinementRoot $fixture
    $callsBeforeForgedReport = $script:checksumCalls
    $forgedReportRejected = $false
    try { Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture | Out-Null } catch { $forgedReportRejected = $true }
    Assert-StageFixture -Condition ($forgedReportRejected -and $script:checksumCalls -eq $callsBeforeForgedReport) -Message 'Recovery blessed a forged but self-hashed stage report without semantic ranking verification.'

    # Asset reduction is review-gated at activation, not staging. Recovery must
    # verify that the reduction report is exact while preserving the inactive
    # candidate for later explicit -AcceptAssetReduction review.
    Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path (Join-Path $fixture "revisions\$candidateRevision5")
    Clear-RevisionStageJournal -ProjectRoot $fixture -ExpectedJournal (Get-RevisionStageJournal -ProjectRoot $fixture)
    $script:semanticFixtureMode = 'reduction'
    $candidateRevision6 = ('6' * 64)
    $candidate6 = New-StageFixtureCandidate -Root $fixture -Revision $candidateRevision6 -CorpusRevision $candidateCorpus
    $report6 = New-StageFixtureReport -Revision $candidateRevision6 -CorpusRevision $candidateCorpus -BaseRevision $baseRevision -BaseCorpusRevision $baseCorpus
    $reductionBaseInspection = Invoke-DatabaseInspection -NodePath 'fixture' -DatabasePath 'fixture-base.sqlite'
    $reductionCandidateInspection = Invoke-DatabaseInspection -NodePath 'fixture' -DatabasePath 'fixture-reduction-candidate.sqlite'
    $reductionAssetJson = (Get-AssetChangeReport -BaseInspection $reductionBaseInspection -CandidateInspection $reductionCandidateInspection) | ConvertTo-Json -Depth 20
    $report6.asset_changes = ConvertFrom-Json -InputObject $reductionAssetJson
    Assert-StageFixture -Condition ([bool]$report6.asset_changes.reduction_requires_review) -Message 'Reduction recovery fixture did not describe a review-gated asset reduction.'
    Start-RevisionStageInstall -ProjectRoot $fixture -Operation documentation-update -Candidate $candidate6 -StageReport $report6 -AllowLegacyActive:$false | Out-Null
    Install-RevisionCandidate -ProjectRoot $fixture -Candidate $candidate6 | Out-Null
    $reductionRecovery = Repair-InterruptedRevisionStageInstall -ProjectRoot $fixture
    Assert-StageFixture -Condition ([string]$reductionRecovery.State -ceq 'completed') -Message 'A valid inactive reduction report became unrecoverable before activation review.'
    $script:semanticFixtureMode = 'normal'

    # Exact old development restart state: the candidate and journal already
    # exist, but the active pointer is still schema 1 (corpus identity). The
    # Stage entrypoint's early conversion must bind it to the journal's index
    # base before recovery, without needing a portable checksum file.
    $developmentRecoveryRoot = Join-Path $fixture 'development schema1 restart'
    foreach ($directory in @('data','maintenance','revisions','scripts','src','config','node_modules\esbuild')) { New-Item -ItemType Directory -Path (Join-Path $developmentRecoveryRoot $directory) -Force | Out-Null }
    foreach ($relative in @('scripts\build.mjs','package.json','src\server.mjs','src\indexer.mjs','config\mql5-query-expansions.json','config\mql5-image-policy.json','scripts\inspect-database.mjs','node_modules\esbuild\package.json')) {
        [IO.File]::WriteAllText((Join-Path $developmentRecoveryRoot $relative), "development-fixture-$relative")
    }
    $legacyCorpusRevision = ('b' * 64)
    $legacyIndexRevision = ('a' * 64)
    New-Item -ItemType Directory -Path (Join-Path $developmentRecoveryRoot "revisions\$legacyCorpusRevision") -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $developmentRecoveryRoot "revisions\$legacyCorpusRevision\legacy.bin"), 'legacy development base')
    Set-ActiveRevisionPointer -ProjectRoot $developmentRecoveryRoot -ActiveRevision $legacyCorpusRevision -PreviousRevision $null -SchemaVersion 1 -ActivatedAt '2026-07-18T12:30:00.0000000Z' | Out-Null
    $script:legacyDevelopmentMode = $true
    $developmentCandidateRevision = ('0' * 64)
    $developmentCandidate = New-StageFixtureCandidate -Root $developmentRecoveryRoot -Revision $developmentCandidateRevision -CorpusRevision $candidateCorpus
    $developmentReport = New-StageFixtureReport -Revision $developmentCandidateRevision -CorpusRevision $candidateCorpus -BaseRevision $legacyIndexRevision -BaseCorpusRevision $legacyCorpusRevision
    Start-RevisionStageInstall -ProjectRoot $developmentRecoveryRoot -Operation rebuild -Candidate $developmentCandidate -StageReport $developmentReport -AllowLegacyActive | Out-Null
    Install-RevisionCandidate -ProjectRoot $developmentRecoveryRoot -Candidate $developmentCandidate | Out-Null
    $preRestartPointer = Get-ActiveRevisionPointer -ProjectRoot $developmentRecoveryRoot
    Assert-StageFixture -Condition ([int]$preRestartPointer.schema_version -eq 1 -and (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $developmentRecoveryRoot) -PathType Leaf)) -Message 'Development restart fixture did not preserve the old schema-1 pointer with its published-candidate journal.'
    Convert-DevelopmentLegacyActivePointerForStageRecovery -ProjectRoot $developmentRecoveryRoot | Out-Null
    $developmentRecovered = Repair-InterruptedRevisionStageInstall -ProjectRoot $developmentRecoveryRoot
    $postRestartPointer = Get-ActiveRevisionPointer -ProjectRoot $developmentRecoveryRoot
    Assert-StageFixture -Condition ([string]$developmentRecovered.State -ceq 'completed' -and [int]$postRestartPointer.schema_version -eq 2 -and [string]$postRestartPointer.active_revision -ceq $legacyIndexRevision -and -not (Test-Path -LiteralPath (Get-RevisionStageJournalPath -ProjectRoot $developmentRecoveryRoot))) -Message 'Published candidate recovery failed after converting its old development schema-1 pointer.'
    $script:legacyDevelopmentMode = $false

    # The portable package loads the recovery helper through IndexMaintenance
    # from paths containing spaces, with no source-tree-relative assumptions.
    $portableLoadRoot = Join-Path $fixture 'portable path with spaces'
    New-Item -ItemType Directory -Path (Join-Path $portableLoadRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $portableLoadRoot 'maintenance') -Force | Out-Null
    foreach ($name in @('Common.ps1','SevenZipRuntime.ps1','IndexMaintenance.ps1','StageInstallRecovery.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $portableLoadRoot "scripts\$name") }
    $portableLoadHelper = Join-Path $fixture 'portable-load.ps1'
    [IO.File]::WriteAllText($portableLoadHelper, @'
param([string]$PortableRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PortableRoot 'scripts\IndexMaintenance.ps1')
$result=Repair-InterruptedRevisionStageInstall -ProjectRoot $PortableRoot
if([string]$result.State -cne 'none'){throw 'Unexpected portable recovery state.'}
'@, (New-Object Text.UTF8Encoding($false)))
    $portableLoad = Invoke-NativeCapture -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$portableLoadHelper,$portableLoadRoot)
    Assert-StageFixture -Condition ($portableLoad.ExitCode -eq 0) -Message "Portable path could not load the stage recovery helper through IndexMaintenance. $($portableLoad.Text)"

    $rebuildText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Rebuild-Index.ps1') -Raw
    $updateText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Update-Documentation.ps1') -Raw
    foreach ($entry in @([pscustomobject]@{Name='Rebuild-Index.ps1';Text=$rebuildText},[pscustomobject]@{Name='Update-Documentation.ps1';Text=$updateText})) {
        $repairArtifactsOffset = $entry.Text.IndexOf('Repair-InterruptedMaintenanceArtifacts')
        $developmentMigrationOffset = $entry.Text.IndexOf('Convert-DevelopmentLegacyActivePointerForStageRecovery')
        $stageRecoveryOffset = $entry.Text.IndexOf('Repair-InterruptedRevisionStageInstall')
        Assert-StageFixture -Condition ($repairArtifactsOffset -ge 0 -and $developmentMigrationOffset -gt $repairArtifactsOffset -and $stageRecoveryOffset -gt $developmentMigrationOffset) -Message "$($entry.Name) does not convert a development schema-1 Stage pointer after artifact repair and before stage-journal recovery."
        Assert-StageFixture -Condition ($entry.Text.Contains("ParameterSetName -eq 'Stage'")) -Message "$($entry.Name) does not limit the early development pointer conversion to Stage operations."
        Assert-StageFixture -Condition ($entry.Text.Contains('Repair-InterruptedRevisionStageInstall')) -Message "$($entry.Name) does not recover a pending stage install before package preflight."
        Assert-StageFixture -Condition ($entry.Text.Contains('Start-RevisionStageInstall')) -Message "$($entry.Name) does not journal the validated candidate before publication."
        Assert-StageFixture -Condition ($entry.Text.Contains('Complete-RevisionStageInstall')) -Message "$($entry.Name) does not finish report/checksum reconciliation after publication."
    }

    Write-Host 'Stage-install recovery fixtures passed: pre-publication cancellation, post-publication report recovery, before/after checksum replacement retries, existing-destination old-to-new retry, pre-mutation semantic refusal, portable legacy-base recovery, schema-1 development restart recovery, both staging flows, exact-tree tamper refusal, forged-report semantic rejection, inactive reduction preservation, PS5/PS7 canonical digests, target-specific debris repair, and portable path loading.'
} finally {
    Set-Item Function:\Assert-Revision -Value $originalAssertRevision
    Set-Item Function:\Update-ManagedChecksumsIfPresent -Value $originalUpdateChecksums
    Set-Item Function:\Assert-RevisionStageRecoveryChecksumBoundary -Value $originalRecoveryBoundary
    Set-Item Function:\Resolve-NodeExecutable -Value $originalResolveNode
    Set-Item Function:\Invoke-DatabaseInspection -Value $originalInspectDatabase
    Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalValidatedRevisionFiles
    Remove-Variable -Name checksumCalls -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name checksumFailureMode -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name semanticFixtureMode -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name legacyDevelopmentMode -Scope Script -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $fixture }
    if (Test-Path -LiteralPath $legacyCandidateWork -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $legacyCandidateWork }
    if (Test-Path -LiteralPath $sameIndexCandidateWork -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $sameIndexCandidateWork }
    if (Test-Path -LiteralPath $supportedBaseWork -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $supportedBaseWork }
    if (Test-Path -LiteralPath $supportedCandidateWork -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $supportedCandidateWork }
}
