[CmdletBinding(DefaultParameterSetName='Stage')]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
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
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$maintenanceRoot = Join-Path $root 'maintenance'
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$lock = $null
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -IdentityRoot $root -TimeoutSeconds $LockTimeoutSeconds
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    if ($PSCmdlet.ParameterSetName -eq 'Stage') { Convert-DevelopmentLegacyActivePointerForStageRecovery -ProjectRoot $root | Out-Null }
    $stageRecovery = Repair-InterruptedRevisionStageInstall -ProjectRoot $root
    if ([string]$stageRecovery.State -eq 'completed') { Write-Host "Recovered incomplete $($stageRecovery.Operation) staging for inactive revision $($stageRecovery.Revision)." }
    $pending = Get-RevisionTransition -ProjectRoot $root -AllowMissing
    Assert-MaintenancePackageIntegrity -ProjectRoot $root -AllowPendingTransition:($null -ne $pending) | Out-Null
    if ($null -ne $pending) {
        if ($PSCmdlet.ParameterSetName -ne 'Apply') { throw 'A revision transition is incomplete. Retry its matching -Apply operation before staging.' }
        if ([string]$pending.operation -ne 'apply') { throw 'A rollback transition is incomplete. Recover it with Rollback-Documentation.ps1.' }
        if ([string]$pending.to_revision -cne $Revision) { throw 'The requested revision does not match the pending apply transition.' }
        if ([int]$pending.schema_version -eq 2) {
            $baseForRecovery = Assert-Revision -ProjectRoot $root -Revision ([string]$pending.from_revision) -IdentityMode Index
            Assert-CandidateActivationAccepted -ProjectRoot $root -CandidateIndexRevision ([string]$pending.to_revision) -BaseRevision $baseForRecovery -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
        }
        $completed = Complete-RevisionTransition -ProjectRoot $root
        Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
        Write-Host "Recovered incomplete $($completed.operation) transition $($completed.from_revision) -> $($completed.to_revision). Restart any running Codex or Claude Code sessions that use this package before using it."
        return
    }

    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ($PSCmdlet.ParameterSetName -eq 'Stage' -and [int]$pointer.schema_version -eq 1 -and (Test-Path -LiteralPath (Join-Path $root 'checksums.sha256') -PathType Leaf)) {
        $pointer = Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root
    }
    $active = Assert-ManifestAndCorpus -ProjectRoot $root
    if ($PSCmdlet.ParameterSetName -eq 'Apply') {
        if ([int]$pointer.schema_version -eq 1) {
            $pointer = Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root -AdditionalValidatedRevisions @($Revision)
            $active = Assert-ManifestAndCorpus -ProjectRoot $root
        }
        if ($Revision -eq [string]$pointer.active_revision) {
            $current = Assert-Revision -ProjectRoot $root -Revision $Revision -IdentityMode Index -RequireCurrent
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision $Revision -ActiveCorpusRevision ([string]$current.CorpusRevision) -CandidateRevision $Revision -CandidateCorpusRevision ([string]$current.CorpusRevision) -Message 'The requested verified index revision is already active locally.' | Out-Null
            Update-ManagedChecksumsIfPresent -ProjectRoot $root
            Write-Host "Index revision $Revision is already active; status and managed checksums were reconciled."
            return
        }
        Assert-CandidateActivationAccepted -ProjectRoot $root -CandidateIndexRevision $Revision -BaseRevision $active -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
        Start-RevisionTransition -ProjectRoot $root -Operation apply -FromRevision ([string]$pointer.active_revision) -ToRevision $Revision | Out-Null
        $completed = Complete-RevisionTransition -ProjectRoot $root
        Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
        Write-Host "Activated documentation index revision $Revision. Restart any running Codex or Claude Code sessions that use this package before using it."
        return
    }

    Assert-NoPendingRevisionTransition -ProjectRoot $root
    $tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
    $downloadRoot = Join-Path $tempBase ('mql5-chm-update-stage-' + [Guid]::NewGuid().ToString('N'))
    Assert-NoReparsePoint -Root $tempBase -Path $tempBase
    $work = Join-Path $tempBase ('mql5-chm-update-work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null
    try {
        Write-Host 'Downloading official MQL5 CHMs for an inactive staged revision...'
        $records = Get-DownloadedSourceRecords -DownloadRoot $downloadRoot -TimeoutSeconds $TimeoutSeconds
        $candidateCorpusRevision = Get-RevisionFromSourceRecords -SourceRecords $records
        $activeContract = if ([int]$active.ManifestSchemaVersion -eq 3 -and $null -ne $active.Manifest.PSObject.Properties['index_contract']) { [string]$active.Manifest.index_contract } else { '' }
        $currentPolicyDigest = Get-CanonicalImagePolicySha256 -ProjectRoot $root
        $activePolicyDigest = if ([int]$active.ManifestSchemaVersion -eq 3 -and $null -ne $active.Manifest.PSObject.Properties['assets']) { [string]$active.Manifest.assets.policy_sha256 } else { '' }
        if ($candidateCorpusRevision -eq [string]$active.CorpusRevision -and $activeContract -ceq $script:IndexContract -and $activePolicyDigest -ceq $currentPolicyDigest) {
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision ([string]$active.IndexRevision) -CandidateCorpusRevision $candidateCorpusRevision -Message 'The official CHM downloads and local index contract match the active revision.' | Out-Null
            if ([int]$pointer.schema_version -eq 2) { Update-ManagedChecksumsIfPresent -ProjectRoot $root }
            Write-Host "Official documentation and index are already active: $($active.IndexRevision)"
            return
        }
        $candidate = New-RevisionCandidate -ProjectRoot $root -SourceRecords $records -WorkingRoot $work -ExtractionTimeoutSeconds $ExtractionTimeoutSeconds -HhTimeoutSeconds $HhTimeoutSeconds
        if ([string]$candidate.CorpusRevision -cne $candidateCorpusRevision) { throw 'Staged index corpus revision does not match the downloaded CHM revision.' }
        $candidateAlreadyCurrent = Assert-DeterministicRebuildResult -BaseRevision $active -CandidateRevision $candidate
        if ($candidateAlreadyCurrent) {
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision ([string]$active.IndexRevision) -CandidateCorpusRevision $candidateCorpusRevision -Message 'The rebuilt official CHMs and identity-bearing index inputs match the active revision.' | Out-Null
            if ([int]$pointer.schema_version -eq 2) { Update-ManagedChecksumsIfPresent -ProjectRoot $root }
            Write-Host "Official documentation and index are already active: $($active.IndexRevision)"
            return
        }
        $node = Resolve-NodeExecutable -ProjectRoot $root
        $baseInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $active.DatabasePath
        Assert-NoRevisionTopicLoss -BaseRevision $active -CandidateRevision $candidate -BaseInspection $baseInspection -CandidateInspection $candidate.Inspection -Context 'stage' | Out-Null
        if ([string]$candidate.IndexRevision -ceq [string]$active.IndexRevision) { throw 'Candidate index revision equals the active index despite changed identity-bearing inputs.' }
        $sourceCounts = [ordered]@{}
        foreach ($definition in Get-Mql5CorpusDefinition) {
            $baseCount = [int]$active.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
            $newCount = [int]$candidate.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
            $sourceCounts[$definition.Id] = [ordered]@{ base=$baseCount; candidate=$newCount; delta=($newCount-$baseCount) }
        }
        $changes = Assert-NoRevisionTopicLoss -BaseRevision $active -CandidateRevision $candidate -BaseInspection $baseInspection -CandidateInspection $candidate.Inspection -Context 'stage'
        $assetChanges = Get-AssetChangeReport -BaseInspection $baseInspection -CandidateInspection $candidate.Inspection
        $rankings = [ordered]@{}; foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) { $row=$candidate.Inspection.ranking.PSObject.Properties[$query].Value; $rankings[$query]=[ordered]@{title=[string]$row.title;source=[string]$row.source} }
        $stageReport = New-StagedRevisionReportValue -Revision ([string]$candidate.IndexRevision) -CorpusRevision ([string]$candidate.CorpusRevision) -BaseRevision ([string]$active.IndexRevision) -BaseCorpusRevision ([string]$active.CorpusRevision) -SourceTopicCounts $sourceCounts -Changes $changes -AssetChanges $assetChanges -RequiredRankings $rankings
        $allowLegacyBase = (
            [int]$active.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion -or
            ([int]$active.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and [string]$active.Manifest.index_contract -cne $script:IndexContract)
        )
        Start-RevisionStageInstall -ProjectRoot $root -Operation documentation-update -Candidate $candidate -StageReport $stageReport -AllowLegacyActive:$allowLegacyBase | Out-Null
        $installedRoot = Install-RevisionCandidate -ProjectRoot $root -Candidate $candidate
        Complete-RevisionStageInstall -ProjectRoot $root | Out-Null
        $installed = Assert-Revision -ProjectRoot $root -Revision ([string]$candidate.IndexRevision) -IdentityMode Index -RequireCurrent
        $installedInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $installed.DatabasePath -RequireAssets
        $installedReport = Join-Path $installedRoot 'stage-report.json'
        Assert-StagedRevisionReport -Path $installedReport -ExpectedRevision ([string]$candidate.IndexRevision) | Out-Null
        Set-UpdateStatus -ProjectRoot $root -Status 'different-revision-available' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision ([string]$candidate.IndexRevision) -CandidateCorpusRevision ([string]$candidate.CorpusRevision) -Message 'A validated official CHM index revision is staged and remains inactive until explicitly applied.' | Out-Null
        Write-Host "Staged validated inactive index revision: $($candidate.IndexRevision)"
        Write-Host "Assets: +$($assetChanges.added_count) -$($assetChanges.removed_count) changed=$($assetChanges.changed_count) exposed=$($assetChanges.candidate_exposed_count) excluded=$($assetChanges.candidate_excluded_count)"
        Write-Host "Apply with: .\Update-Documentation.ps1 -Apply -Revision $($candidate.IndexRevision)"
    } finally {
        if (Test-Path -LiteralPath $downloadRoot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $downloadRoot }
        if (Test-Path -LiteralPath $work -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $work }
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
