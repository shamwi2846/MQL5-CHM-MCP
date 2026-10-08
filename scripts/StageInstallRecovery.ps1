Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RevisionStageJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    return Assert-PathWithin -Root $root -Path (Join-Path $root 'maintenance\revision-stage.json')
}

function Get-CanonicalJsonValueSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    # Compact JSON avoids the host-specific pretty-print indentation difference
    # between Windows PowerShell 5.1 and PowerShell 7. Property order is fixed
    # by the stage-report contract and preserved by Read-JsonFile.
    $json = $Value | ConvertTo-Json -Compress -Depth 20
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-StagedRevisionReportFileBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$StageReport)
    $json = $StageReport | ConvertTo-Json -Compress -Depth 20
    return ,([Text.Encoding]::UTF8.GetBytes($json + "`r`n"))
}

function Get-StagedRevisionReportFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$StageReport)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash((Get-StagedRevisionReportFileBytes -StageReport $StageReport)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-StagedCandidateTreeSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfinementRoot
    )
    $confinement = Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    $treeRoot = Assert-PathWithin -Root $confinement -Path (Resolve-FullPath -Path $Root -MustExist -PathType Container)
    Assert-NoReparsePoint -Root $confinement -Path $treeRoot
    $reparseItems = @(Get-ChildItem -LiteralPath $treeRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Staged candidate tree contains a reparse point: $($reparseItems[0].FullName)" }

    $entries = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    $caseFolded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $treeRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($treeRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($relative -ieq 'stage-report.json') { continue }
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or -not $caseFolded.Add($relative)) {
            throw "Staged candidate tree contains an unsafe or case-colliding path: $relative"
        }
        $entries.Add($relative, [pscustomobject]@{
            Path=$relative
            Sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            Bytes=[int64]$file.Length
        })
    }
    if ($entries.Count -eq 0) { throw 'Staged candidate tree is empty.' }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in $entries.Values) {
            $record = "$($entry.Path)$([char]0)$($entry.Sha256)$([char]0)$($entry.Bytes)$([char]0)"
            $bytes = [Text.Encoding]::UTF8.GetBytes($record)
            [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Assert-SameIndexRevisionReuse {
    <# Index identity is the SQLite SHA-256, while retrieval/build timestamps
       intentionally live outside that identity. Permit an already-installed
       revision to win only when both trees validate as current and every
       semantic manifest field (including full asset-policy/tree closure) is
       identical. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$CandidateRevision,
        [Parameter(Mandatory)][object]$ExistingRevision
    )
    if ([int]$CandidateRevision.ManifestSchemaVersion -ne $script:ManifestSchemaVersion -or
        [int]$ExistingRevision.ManifestSchemaVersion -ne $script:ManifestSchemaVersion -or
        [string]$CandidateRevision.IndexRevision -cne [string]$ExistingRevision.IndexRevision -or
        [string]$CandidateRevision.CorpusRevision -cne [string]$ExistingRevision.CorpusRevision) {
        throw 'Existing staged destination is not the same current index/corpus revision as the validated candidate.'
    }
    $candidateManifest = $CandidateRevision.Manifest
    $existingManifest = $ExistingRevision.Manifest
    $candidateSources = [ordered]@{}
    $existingSources = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $candidateSource = $candidateManifest.sources.PSObject.Properties[$definition.Id].Value
        $existingSource = $existingManifest.sources.PSObject.Properties[$definition.Id].Value
        $candidateSources[$definition.Id] = [ordered]@{
            filename=[string]$candidateSource.filename;sha256=[string]$candidateSource.sha256;bytes=[int64]$candidateSource.bytes
            topic_count=[int]$candidateSource.topic_count;section_count=[int]$candidateSource.section_count
        }
        $existingSources[$definition.Id] = [ordered]@{
            filename=[string]$existingSource.filename;sha256=[string]$existingSource.sha256;bytes=[int64]$existingSource.bytes
            topic_count=[int]$existingSource.topic_count;section_count=[int]$existingSource.section_count
        }
    }
    $candidateSemantic = [ordered]@{
        schema_version=[int]$candidateManifest.schema_version
        index_revision=[string]$candidateManifest.index_revision;corpus_revision=[string]$candidateManifest.corpus_revision
        corpus_sha256=[string]$candidateManifest.corpus_sha256;index_contract=[string]$candidateManifest.index_contract
        database=$candidateManifest.database;sources=$candidateSources
        total_topic_count=[int]$candidateManifest.total_topic_count;total_section_count=[int]$candidateManifest.total_section_count
        topic_link_count=[int]$candidateManifest.topic_link_count;resolved_topic_link_count=[int]$candidateManifest.resolved_topic_link_count;unresolved_topic_link_count=[int]$candidateManifest.unresolved_topic_link_count
        assets=$candidateManifest.assets
    }
    $existingSemantic = [ordered]@{
        schema_version=[int]$existingManifest.schema_version
        index_revision=[string]$existingManifest.index_revision;corpus_revision=[string]$existingManifest.corpus_revision
        corpus_sha256=[string]$existingManifest.corpus_sha256;index_contract=[string]$existingManifest.index_contract
        database=$existingManifest.database;sources=$existingSources
        total_topic_count=[int]$existingManifest.total_topic_count;total_section_count=[int]$existingManifest.total_section_count
        topic_link_count=[int]$existingManifest.topic_link_count;resolved_topic_link_count=[int]$existingManifest.resolved_topic_link_count;unresolved_topic_link_count=[int]$existingManifest.unresolved_topic_link_count
        assets=$existingManifest.assets
    }
    if (($candidateSemantic | ConvertTo-Json -Compress -Depth 30) -cne ($existingSemantic | ConvertTo-Json -Compress -Depth 30)) {
        throw 'Existing staged destination differs from the candidate in identity-bearing or semantic revision metadata.'
    }
    return $true
}

function New-StagedRevisionReportValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CorpusRevision,
        [AllowNull()][AllowEmptyString()][ValidateScript({ [string]::IsNullOrEmpty([string]$_) -or $_ -match '^[0-9a-f]{64}$' })][string]$BaseRevision,
        [AllowNull()][AllowEmptyString()][ValidateScript({ [string]::IsNullOrEmpty([string]$_) -or $_ -match '^[0-9a-f]{64}$' })][string]$BaseCorpusRevision,
        [Parameter(Mandatory)][object]$SourceTopicCounts,
        [Parameter(Mandatory)][object]$Changes,
        [Parameter(Mandatory)][object]$AssetChanges,
        [Parameter(Mandatory)][object]$RequiredRankings,
        [string]$StagedAt = ([DateTime]::UtcNow.ToString('O'))
    )
    if ([string]::IsNullOrEmpty($BaseRevision) -ne [string]::IsNullOrEmpty($BaseCorpusRevision)) { throw 'Stage report base index and corpus revisions must both be set or both be null.' }
    if (-not [string]::IsNullOrEmpty($BaseRevision) -and $Revision -ceq $BaseRevision) { throw 'A staged revision must differ from its validation base.' }
    Assert-UtcIsoTimestamp -Value $StagedAt -Context 'stage report staged_at' | Out-Null
    $value = [ordered]@{
        schema_version=3;index_revision=$Revision;corpus_revision=$CorpusRevision
        base_index_revision=if ([string]::IsNullOrEmpty($BaseRevision)) { $null } else { $BaseRevision }
        base_corpus_revision=if ([string]::IsNullOrEmpty($BaseCorpusRevision)) { $null } else { $BaseCorpusRevision }
        staged_at=$StagedAt;validation_passed=$true
        source_topic_counts=$SourceTopicCounts;changes=$Changes;asset_changes=$AssetChanges;required_rankings=$RequiredRankings
    }
    $json = $value | ConvertTo-Json -Depth 20
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $json -DateKind String }
    return ConvertFrom-Json -InputObject $json
}

function Assert-StagedRevisionReportValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$StageReport,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRevision
    )
    Assert-ExactJsonProperties -Object $StageReport -Names @('schema_version','index_revision','corpus_revision','base_index_revision','base_corpus_revision','staged_at','validation_passed','source_topic_counts','changes','asset_changes','required_rankings') -Context 'stage report'
    Assert-StagedRevisionReportTypes -Report $StageReport
    if ([int]$StageReport.schema_version -ne 3 -or [string]$StageReport.index_revision -cne $ExpectedRevision -or $StageReport.validation_passed -isnot [bool] -or -not [bool]$StageReport.validation_passed) { throw 'Stage report is not approved for this index revision.' }
    if ([string]$StageReport.corpus_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Stage report corpus_revision is invalid.' }
    if (($null -eq $StageReport.base_index_revision) -ne ($null -eq $StageReport.base_corpus_revision)) { throw 'Stage report base revisions must both be set or both be null.' }
    foreach ($name in @('base_index_revision','base_corpus_revision')) {
        if ($null -ne $StageReport.PSObject.Properties[$name].Value -and [string]$StageReport.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Stage report $name is invalid." }
    }
    Assert-ExactJsonProperties -Object $StageReport.asset_changes -Names @('added_count','removed_count','changed_count','added_asset_ids','removed_asset_ids','changed_asset_ids','added_truncated','removed_truncated','changed_truncated','base_cataloged_count','candidate_cataloged_count','cataloged_delta','base_exposed_count','candidate_exposed_count','exposed_delta','candidate_excluded_count','base_occurrence_count','candidate_occurrence_count','occurrence_delta','base_exposed_occurrence_count','candidate_exposed_occurrence_count','exposed_occurrence_delta','candidate_total_bytes','unsupported_count','oversized_count','unresolved_count','unclassified_count','reduction_requires_review') -Context 'stage report asset_changes'
    foreach ($name in @('added_count','removed_count','changed_count','base_cataloged_count','candidate_cataloged_count','base_exposed_count','candidate_exposed_count','candidate_excluded_count','base_occurrence_count','candidate_occurrence_count','base_exposed_occurrence_count','candidate_exposed_occurrence_count','candidate_total_bytes','unsupported_count','oversized_count','unresolved_count','unclassified_count')) {
        if ([int64]$StageReport.asset_changes.PSObject.Properties[$name].Value -lt 0) { throw "Stage report asset_changes.$name must not be negative." }
    }
    foreach ($name in @('unsupported_count','oversized_count','unresolved_count','unclassified_count')) {
        if ([int]$StageReport.asset_changes.PSObject.Properties[$name].Value -ne 0) { throw "Stage report contains unresolved asset validation failures: $name." }
    }
    Assert-UtcIsoTimestamp -Value ([string]$StageReport.staged_at) -Context 'stage report staged_at'
    return $StageReport
}

function Write-StagedRevisionReportValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RevisionRoot,
        [Parameter(Mandatory)][object]$StageReport
    )
    $revisionRootFull = Resolve-FullPath -Path $RevisionRoot -MustExist -PathType Container
    $revision = [string]$StageReport.index_revision
    Assert-StagedRevisionReportValue -StageReport $StageReport -ExpectedRevision $revision | Out-Null
    $reportPath = Join-Path $revisionRootFull 'stage-report.json'
    $transactionId = [Guid]::NewGuid().ToString('N')
    $writing = Assert-PathWithin -Root $revisionRootFull -Path (Join-Path $revisionRootFull ('.stage-report.json.replace.writing-' + $transactionId))
    $temporary = Assert-PathWithin -Root $revisionRootFull -Path (Join-Path $revisionRootFull ('.stage-report.json.replace.tmp-' + $transactionId))
    $backup = Assert-PathWithin -Root $revisionRootFull -Path (Join-Path $revisionRootFull ('.stage-report.json.replace.backup-' + $transactionId))
    $prepared = $false
    try {
        $bytes = Get-StagedRevisionReportFileBytes -StageReport $StageReport
        $stream = New-Object IO.FileStream($writing, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($writing, $temporary)
        $prepared = $true
        Publish-PreparedAtomicFile -TemporaryPath $temporary -TargetPath $reportPath -BackupPath $backup
    } catch {
        if (-not $prepared) {
            foreach ($incomplete in @($writing,$temporary)) {
                if (Test-Path -LiteralPath $incomplete -PathType Leaf) { Remove-Item -LiteralPath $incomplete -Force -ErrorAction Stop }
            }
        }
        throw
    }
    return Assert-StagedRevisionReport -Path $reportPath -ExpectedRevision $revision
}

function Get-RevisionStageJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$AllowMissing)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $path = Get-RevisionStageJournalPath -ProjectRoot $root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "Revision stage journal is missing: $path"
    }
    Assert-NoReparsePoint -Root $root -Path $path
    if ((Get-Item -LiteralPath $path).Length -gt 2097152) { throw 'Revision stage journal is unexpectedly large.' }
    $journal = Read-JsonFile -Path $path -Context 'revision stage journal' -RequireObject
    Assert-ExactJsonProperties -Object $journal -Names @('schema_version','operation','index_revision','corpus_revision','base_index_revision','base_corpus_revision','candidate_tree_sha256','json_digest_contract','stage_report_canonical_sha256','stage_report_file_sha256','destination_existed','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256','allow_legacy_active','started_at','stage_report') -Context 'revision stage journal'
    Assert-RevisionStageJournalTypes -Journal $journal
    if ([int]$journal.schema_version -ne 1) { throw 'Revision stage journal schema_version must be 1.' }
    if (@('rebuild','documentation-update') -cnotcontains [string]$journal.operation) { throw 'Revision stage journal operation is invalid.' }
    if ([string]$journal.json_digest_contract -cne 'powershell-json-compress-depth20-v1') { throw 'Revision stage journal JSON digest contract is invalid.' }
    foreach ($name in @('index_revision','corpus_revision','candidate_tree_sha256','stage_report_canonical_sha256','stage_report_file_sha256')) {
        if ([string]$journal.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Revision stage journal $name is invalid." }
    }
    if (($null -eq $journal.base_index_revision) -ne ($null -eq $journal.base_corpus_revision)) { throw 'Revision stage journal base revisions must both be set or both be null.' }
    foreach ($name in @('base_index_revision','base_corpus_revision','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256')) {
        if ($null -ne $journal.PSObject.Properties[$name].Value -and [string]$journal.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Revision stage journal $name is invalid." }
    }
    if ($journal.destination_existed -isnot [bool] -or $journal.allow_legacy_active -isnot [bool]) { throw 'Revision stage journal Boolean fields are invalid.' }
    if (($null -eq $journal.prior_stage_report_canonical_sha256) -ne ($null -eq $journal.prior_stage_report_file_sha256)) { throw 'Revision stage journal prior report digests must both be set or both be null.' }
    if (-not [bool]$journal.destination_existed -and $null -ne $journal.prior_stage_report_canonical_sha256) { throw 'A new stage destination cannot declare a prior stage report.' }
    Assert-UtcIsoTimestamp -Value ([string]$journal.started_at) -Context 'revision stage journal started_at'
    Assert-StagedRevisionReportValue -StageReport $journal.stage_report -ExpectedRevision ([string]$journal.index_revision) | Out-Null
    if ([string]$journal.stage_report.corpus_revision -cne [string]$journal.corpus_revision -or
        [string]$journal.stage_report.base_index_revision -cne [string]$journal.base_index_revision -or
        [string]$journal.stage_report.base_corpus_revision -cne [string]$journal.base_corpus_revision) {
        throw 'Revision stage journal does not bind the staged report to the same candidate and base revisions.'
    }
    if ((Get-CanonicalJsonValueSha256 -Value $journal.stage_report) -cne [string]$journal.stage_report_canonical_sha256) { throw 'Revision stage journal report digest is invalid.' }
    if ((Get-StagedRevisionReportFileSha256 -StageReport $journal.stage_report) -cne [string]$journal.stage_report_file_sha256) { throw 'Revision stage journal report file digest is invalid.' }
    return $journal
}

function Clear-RevisionStageJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][object]$ExpectedJournal)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $current = Get-RevisionStageJournal -ProjectRoot $root
    if (($current | ConvertTo-Json -Compress -Depth 20) -cne ($ExpectedJournal | ConvertTo-Json -Compress -Depth 20)) { throw 'Revision stage journal changed before it could be cleared.' }
    $path = Get-RevisionStageJournalPath -ProjectRoot $root
    Assert-NoReparsePoint -Root $root -Path $path
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Assert-RevisionStageRecoveryChecksumBoundary {
    <# Verify the existing portable trust boundary before any bundled/native
       process is used during stage recovery. The only unlisted immutable files
       permitted are the exact pending revision tree; its full validation and
       semantic acceptance happen before those paths are added to checksums. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$Journal
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $Revision = [string]$Journal.index_revision
    if ($Revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Stage recovery checksum boundary received an invalid revision identity.' }
    $layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
    if ($layoutMode -eq 'development') { return $true }
    if ($layoutMode -ne 'portable') { throw 'Stage recovery requires a complete development tree or a verified portable checksum boundary.' }

    Assert-NoReparsePoint -Root $root -Path $root
    $checksumPath = Resolve-FullPath -Path (Join-Path $root 'checksums.sha256') -MustExist -PathType Leaf
    Assert-NoReparsePoint -Root $root -Path $checksumPath
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $mutable = @('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json')
    foreach ($line in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { throw "Malformed checksum line during stage recovery: $line" }
        $relative = $Matches[2].Trim().Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or $relative -ieq 'checksums.sha256') { throw "Unsafe checksum entry during stage recovery: $relative" }
        if ($mutable -contains $relative) { throw "Mutable maintenance file must not be checksummed during stage recovery: $relative" }
        if ($seen.ContainsKey($relative)) { throw "Duplicate checksum entry during stage recovery: $relative" }
        $path = Assert-PathWithin -Root $root -Path (Join-Path $root $relative.Replace('/','\'))
        Assert-NoReparsePoint -Root $root -Path $path
        $expectedHash = $Matches[1].ToLowerInvariant()
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($actualHash -cne $expectedHash) {
            $reportRelative = "revisions/$Revision/stage-report.json"
            $journaledReportTransition = (
                $relative -ieq $reportRelative -and [bool]$Journal.destination_existed -and
                [string]$Journal.prior_stage_report_file_sha256 -ceq $expectedHash -and
                [string]$Journal.stage_report_file_sha256 -ceq $actualHash
            )
            if (-not $journaledReportTransition) { throw "SHA-256 mismatch for '$relative' during stage recovery." }
        }
        $seen.Add($relative, $expectedHash)
    }
    if ($seen.Count -eq 0 -or -not $seen.ContainsKey('data/active.json')) { throw 'Portable checksum boundary is empty or does not bind the active pointer.' }

    $required = @(Get-PortablePackageRequiredStaticPaths)
    foreach ($relative in $required) { if (-not $seen.ContainsKey($relative)) { throw "Portable checksum boundary is missing required stage-recovery entry '$relative'." } }
    $packageMarker = (Get-Content -LiteralPath (Join-Path $root '.mql5-chm-package-root') -Raw -Encoding UTF8).Trim()
    if ($packageMarker -cne 'mql5-chm-portable-package-v1') { throw 'Portable package ownership marker is invalid during stage recovery.' }

    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$pointer.schema_version -ne 2) { throw 'Stage recovery requires an index-identity active pointer.' }
    $allowLegacyActive = [bool]$Journal.allow_legacy_active
    if ($allowLegacyActive) {
        if ($null -eq $Journal.base_index_revision -or [string]$Journal.base_index_revision -cne [string]$pointer.active_revision) {
            throw 'Stage recovery noncurrent-active permission is not bound to the exact active base revision.'
        }
        $supportedActive = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index
        $supportedActiveIsNoncurrent = (
            [int]$supportedActive.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion -or
            ([int]$supportedActive.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and [string]$supportedActive.Manifest.index_contract -cne $script:IndexContract)
        )
        if (-not $supportedActiveIsNoncurrent) {
            throw 'Stage recovery noncurrent-active permission may only validate an exact supported but noncurrent base schema or index contract.'
        }
    }
    foreach ($pointerRevision in @([string]$pointer.active_revision,[string]$pointer.previous_revision) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        $allowLegacyRevision = $pointerRevision -ne [string]$pointer.active_revision -or $allowLegacyActive
        foreach ($file in Get-ValidatedRevisionChecksumFiles -ProjectRoot $root -Revision $pointerRevision -AllowLegacy:$allowLegacyRevision) {
            $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
            if (-not $seen.ContainsKey($relative)) { throw "Portable checksum boundary is missing verified pointer revision entry '$relative'." }
        }
    }

    $candidatePrefix = "revisions/$Revision/"
    $reparseItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Portable stage recovery found a reparse point: $($reparseItems[0].FullName)" }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($relative -ieq 'checksums.sha256' -or $mutable -contains $relative -or $seen.ContainsKey($relative)) { continue }
        if (-not $relative.StartsWith($candidatePrefix, [StringComparison]::Ordinal)) { throw "Untrusted immutable file exists outside the pending revision during stage recovery: $relative" }
    }
    return $true
}

function Assert-RevisionStageSemanticAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][object]$CandidateRevision
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $base = $null
    $baseInspection = $null
    if ($null -ne $Journal.base_index_revision) {
        $base = Assert-Revision -ProjectRoot $root -Revision ([string]$Journal.base_index_revision) -IdentityMode Index
        if ([string]$base.CorpusRevision -cne [string]$Journal.base_corpus_revision) { throw 'Stage recovery base corpus revision does not match its journal.' }
        $baseIsSupportedNoncurrent = (
            [int]$base.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion -or
            ([int]$base.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and [string]$base.Manifest.index_contract -cne $script:IndexContract)
        )
        if ([bool]$Journal.allow_legacy_active -ne $baseIsSupportedNoncurrent) { throw 'Stage recovery noncurrent-base policy does not match the validated base schema and index contract.' }
    } elseif ([bool]$Journal.allow_legacy_active) {
        throw 'Initial stage recovery cannot enable legacy-active checksum handling.'
    }
    if ([string]$Journal.operation -eq 'documentation-update' -and $null -eq $base) { throw 'Documentation-update staging requires a validated active base.' }

    # The checksum-boundary check above verifies the bundled runtime and
    # inspector before this native process is started.
    $node = Resolve-NodeExecutable -ProjectRoot $root
    if ($null -ne $base) { $baseInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $base.DatabasePath }
    $candidateInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $CandidateRevision.DatabasePath -RequireAssets
    $candidateAssets = $CandidateRevision.Manifest.assets
    if ([string]$candidateInspection.metadata.corpus_sha256 -cne [string]$CandidateRevision.CorpusRevision -or
        [string]$candidateInspection.metadata.index_contract -cne [string]$CandidateRevision.Manifest.index_contract -or
        [string]$candidateInspection.metadata.image_policy_sha256 -cne [string]$candidateAssets.policy_sha256 -or
        [string]$candidateInspection.metadata.asset_catalog_sha256 -cne [string]$candidateAssets.catalog_sha256 -or
        [string]$candidateInspection.metadata.asset_tree_sha256 -cne [string]$candidateAssets.tree_sha256 -or
        [int]$candidateInspection.asset_count -ne [int]$candidateAssets.cataloged_count -or
        [int]$candidateInspection.topic_asset_count -ne [int]$candidateAssets.occurrence_count) {
        throw 'Stage recovery candidate database metadata does not match its fully validated manifest and asset closure.'
    }
    Assert-StagedReportMatchesVerification -Report $Journal.stage_report -BaseRevision $base -CandidateRevision $CandidateRevision -BaseInspection $baseInspection -CandidateInspection $candidateInspection -AcceptAssetReduction | Out-Null
    return [pscustomobject]@{Base=$base;Candidate=$CandidateRevision;BaseInspection=$baseInspection;CandidateInspection=$candidateInspection}
}

function Start-RevisionStageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('rebuild','documentation-update')][string]$Operation,
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$StageReport,
        [switch]$AllowLegacyActive
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $maintenanceRoot = Join-Path $root 'maintenance'
    if (-not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) { New-Item -ItemType Directory -Path $maintenanceRoot -Force | Out-Null }
    Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    if ($null -ne (Get-RevisionStageJournal -ProjectRoot $root -AllowMissing)) { throw 'A revision stage install is already incomplete; recover it before starting another.' }

    $revision = [string]$Candidate.IndexRevision
    if ([string]::IsNullOrWhiteSpace($revision)) { $revision = [string]$Candidate.Revision }
    $corpusRevision = [string]$Candidate.CorpusRevision
    if ($revision -cnotmatch '^[0-9a-f]{64}$' -or $corpusRevision -cnotmatch '^[0-9a-f]{64}$') { throw 'Staged candidate identities are invalid.' }
    Assert-StagedRevisionReportValue -StageReport $StageReport -ExpectedRevision $revision | Out-Null
    if ([string]$StageReport.corpus_revision -cne $corpusRevision) { throw 'Stage report corpus revision does not match the candidate.' }
    if ($null -eq $StageReport.base_index_revision) {
        if ([bool]$AllowLegacyActive) { throw 'Initial staging cannot enable supported-noncurrent active handling.' }
    } else {
        $stageBase = Assert-Revision -ProjectRoot $root -Revision ([string]$StageReport.base_index_revision) -IdentityMode Index
        if ([string]$stageBase.CorpusRevision -cne [string]$StageReport.base_corpus_revision) { throw 'Stage report base corpus revision does not match its validated base.' }
        $stageBaseIsSupportedNoncurrent = (
            [int]$stageBase.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion -or
            ([int]$stageBase.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and [string]$stageBase.Manifest.index_contract -cne $script:IndexContract)
        )
        if ([bool]$AllowLegacyActive -ne $stageBaseIsSupportedNoncurrent) { throw 'Staging noncurrent-base policy does not match the validated base schema and index contract.' }
    }

    $candidateWork = Resolve-FullPath -Path ([string]$Candidate.WorkRoot) -MustExist -PathType Container
    $candidateRoot = Resolve-FullPath -Path ([string]$Candidate.Root) -MustExist -PathType Container
    Assert-PathWithin -Root $candidateWork -Path $candidateRoot | Out-Null
    $candidateValidated = Assert-Revision -ProjectRoot $root -Revision $revision -RevisionRoot $candidateRoot -RevisionConfinementRoot $candidateWork -IdentityMode Index -RequireCurrent
    if (Test-Path -LiteralPath (Join-Path $candidateRoot 'stage-report.json')) { throw 'The unpublished candidate unexpectedly contains a stage report.' }
    $candidateTree = Get-StagedCandidateTreeSha256 -Root $candidateRoot -ConfinementRoot $candidateWork
    $publicationTree = $candidateTree

    $destination = Get-RevisionDirectory -ProjectRoot $root -Revision $revision
    $destinationExisted = Test-Path -LiteralPath $destination -PathType Container
    $priorReportHash = $null
    if ($destinationExisted) {
        $existing = Assert-Revision -ProjectRoot $root -Revision $revision -IdentityMode Index -RequireCurrent
        if ([string]$existing.CorpusRevision -cne $corpusRevision) { throw 'Existing staged destination has a conflicting corpus revision.' }
        $existingTree = Get-StagedCandidateTreeSha256 -Root $destination -ConfinementRoot $root
        Assert-SameIndexRevisionReuse -CandidateRevision $candidateValidated -ExistingRevision $existing | Out-Null
        # Retain the immutable winner already installed under this index ID and
        # bind recovery to its fully validated bytes. Freshness-only manifest or
        # corpus-lock differences in the disposable build are not published.
        $publicationTree = $existingTree
        $priorReportPath = Join-Path $destination 'stage-report.json'
        if (Test-Path -LiteralPath $priorReportPath -PathType Leaf) {
            $priorReport = Assert-StagedRevisionReport -Path $priorReportPath -ExpectedRevision $revision
            $priorReportHash = Get-CanonicalJsonValueSha256 -Value $priorReport
        }
    }

    $journal = [ordered]@{
        schema_version=1;operation=$Operation;index_revision=$revision;corpus_revision=$corpusRevision
        base_index_revision=$StageReport.base_index_revision;base_corpus_revision=$StageReport.base_corpus_revision
        candidate_tree_sha256=$publicationTree;json_digest_contract='powershell-json-compress-depth20-v1'
        stage_report_canonical_sha256=(Get-CanonicalJsonValueSha256 -Value $StageReport)
        stage_report_file_sha256=(Get-StagedRevisionReportFileSha256 -StageReport $StageReport)
        destination_existed=[bool]$destinationExisted;prior_stage_report_canonical_sha256=$priorReportHash
        prior_stage_report_file_sha256=if ($null -eq $priorReportHash) { $null } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $priorReportPath).Hash.ToLowerInvariant() }
        allow_legacy_active=[bool]$AllowLegacyActive;started_at=[DateTime]::UtcNow.ToString('O');stage_report=$StageReport
    }
    $path = Get-RevisionStageJournalPath -ProjectRoot $root
    Write-JsonAtomic -Path $path -Value $journal -ConfinementRoot $root
    return Get-RevisionStageJournal -ProjectRoot $root
}

function Repair-InterruptedRevisionStageInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $journal = Get-RevisionStageJournal -ProjectRoot $root -AllowMissing
    if ($null -eq $journal) { return [pscustomobject]@{State='none';Revision=$null;Operation=$null} }
    $revision = [string]$journal.index_revision
    $destination = Get-RevisionDirectory -ProjectRoot $root -Revision $revision
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        if ([bool]$journal.destination_existed) { throw 'A pre-existing staged destination disappeared during an incomplete stage install.' }
        Clear-RevisionStageJournal -ProjectRoot $root -ExpectedJournal $journal
        return [pscustomobject]@{State='cancelled';Revision=$revision;Operation=[string]$journal.operation}
    }

    Assert-RevisionStageRecoveryChecksumBoundary -ProjectRoot $root -Journal $journal | Out-Null

    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root -AllowMissing
    if ($null -eq $journal.base_index_revision) {
        if ($null -ne $pointer) { throw 'The active revision changed during an initial stage install.' }
    } elseif ($null -eq $pointer -or [int]$pointer.schema_version -ne 2 -or [string]$pointer.active_revision -cne [string]$journal.base_index_revision) {
        throw 'The active base revision changed during the incomplete stage install.'
    }

    $validated = Assert-Revision -ProjectRoot $root -Revision $revision -IdentityMode Index -RequireCurrent
    if ([string]$validated.CorpusRevision -cne [string]$journal.corpus_revision) { throw 'Published stage candidate corpus does not match its journal.' }
    $treeDigest = Get-StagedCandidateTreeSha256 -Root $destination -ConfinementRoot $root
    if ($treeDigest -cne [string]$journal.candidate_tree_sha256) { throw 'Published stage candidate tree does not match its pre-publication journal.' }

    # Semantic acceptance must finish before an existing checksummed report is
    # replaced. A forged or stale report therefore leaves the proven old report
    # bytes untouched.
    Assert-RevisionStageSemanticAcceptance -ProjectRoot $root -Journal $journal -CandidateRevision $validated | Out-Null

    $reportPath = Join-Path $destination 'stage-report.json'
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $existingReport = Assert-StagedRevisionReport -Path $reportPath -ExpectedRevision $revision
        $existingHash = Get-CanonicalJsonValueSha256 -Value $existingReport
        $existingFileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant()
        $isJournaledReport = $existingHash -ceq [string]$journal.stage_report_canonical_sha256 -and $existingFileHash -ceq [string]$journal.stage_report_file_sha256
        if (-not $isJournaledReport) {
            $isProvenPriorReport = (
                [bool]$journal.destination_existed -and
                $null -ne $journal.prior_stage_report_canonical_sha256 -and
                $existingHash -ceq [string]$journal.prior_stage_report_canonical_sha256 -and
                $existingFileHash -ceq [string]$journal.prior_stage_report_file_sha256
            )
            if (-not $isProvenPriorReport) {
                throw 'Published stage report differs from both the journaled report and the proven prior report.'
            }
            Write-StagedRevisionReportValue -RevisionRoot $destination -StageReport $journal.stage_report | Out-Null
        }
    } else {
        if ([bool]$journal.destination_existed -and $null -ne $journal.prior_stage_report_canonical_sha256) { throw 'The prior staged report disappeared during report refresh.' }
        Write-StagedRevisionReportValue -RevisionRoot $destination -StageReport $journal.stage_report | Out-Null
    }
    $publishedReport = Assert-StagedRevisionReport -Path $reportPath -ExpectedRevision $revision
    if ((Get-CanonicalJsonValueSha256 -Value $publishedReport) -cne [string]$journal.stage_report_canonical_sha256) { throw 'Published stage report does not match its journaled canonical digest.' }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash.ToLowerInvariant() -cne [string]$journal.stage_report_file_sha256) { throw 'Published stage report does not match its journaled file digest.' }

    $reportRelative = $reportPath.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
    Update-ManagedChecksumsIfPresent -ProjectRoot $root -ChangedRelativePaths @($reportRelative) -AllowLegacyActive:([bool]$journal.allow_legacy_active)
    Clear-RevisionStageJournal -ProjectRoot $root -ExpectedJournal $journal
    return [pscustomobject]@{State='completed';Revision=$revision;Operation=[string]$journal.operation;Root=$destination}
}

function Convert-DevelopmentLegacyActivePointerForStageRecovery {
    <# A development-tree Stage run historically left its schema-1 pointer in
       corpus-identity form because no portable checksum file exists. A crash
       after candidate publication can therefore leave a journal already bound
       to the legacy database/index identity. Convert that pointer before the
       journal is recovered. Portable trees keep their existing checksum-first
       migration path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    if ((Get-Mql5ChmLayoutMode -ProjectRoot $root) -ne 'development') { return $null }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root -AllowMissing
    if ($null -ne $pointer -and [int]$pointer.schema_version -eq 1) {
        return Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root
    }
    return $pointer
}

function Complete-RevisionStageInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $result = Repair-InterruptedRevisionStageInstall -ProjectRoot $ProjectRoot
    if ([string]$result.State -ne 'completed') { throw 'The staged revision was not published before completion was requested.' }
    return $result
}
