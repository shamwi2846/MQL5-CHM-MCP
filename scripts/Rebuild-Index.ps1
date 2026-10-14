[CmdletBinding(DefaultParameterSetName='Stage')]
param(
    [Parameter(ParameterSetName='Stage')][switch]$Stage,
    [Parameter(Mandatory,ParameterSetName='Apply')][switch]$Apply,
    [Parameter(Mandatory,ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
    [Parameter(ParameterSetName='Apply')][switch]$AcceptAssetReduction,
    [Parameter(ParameterSetName='Stage')][ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
    [Parameter(ParameterSetName='Stage')][ValidateRange(10,300)][int]$HhTimeoutSeconds = 60,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$maintenanceRoot = Join-Path $root 'maintenance'
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
Assert-NoReparsePoint -Root $tempBase -Path $tempBase
$lock = $null; $work = Join-Path $tempBase ('mql5-chm-rebuild-work-' + [Guid]::NewGuid().ToString('N'))
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -IdentityRoot $root -TimeoutSeconds $LockTimeoutSeconds
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    if ($PSCmdlet.ParameterSetName -eq 'Stage') { Convert-DevelopmentLegacyActivePointerForStageRecovery -ProjectRoot $root | Out-Null }
    $stageRecovery = Repair-InterruptedRevisionStageInstall -ProjectRoot $root
    if ([string]$stageRecovery.State -eq 'completed') { Write-Host "Recovered incomplete $($stageRecovery.Operation) staging for inactive revision $($stageRecovery.Revision)." }
    $pending = Get-RevisionTransition -ProjectRoot $root -AllowMissing
    Assert-MaintenancePackageIntegrity -ProjectRoot $root -AllowPendingTransition:($null -ne $pending) | Out-Null
    if ($null -ne $pending) {
        if ($PSCmdlet.ParameterSetName -ne 'Apply' -or [int]$pending.schema_version -ne 2 -or [string]$pending.operation -ne 'apply' -or [string]$pending.to_revision -cne $Revision) { throw 'A revision transition is incomplete. Retry the matching rebuild -Apply operation before continuing.' }
        $pointerForRecovery = Get-ActiveRevisionPointer -ProjectRoot $root
        $baseForRecovery = Assert-Revision -ProjectRoot $root -Revision ([string]$pending.from_revision) -IdentityMode Index
        Assert-CandidateActivationAccepted -ProjectRoot $root -CandidateIndexRevision ([string]$pending.to_revision) -BaseRevision $baseForRecovery -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
        $completed = Complete-RevisionTransition -ProjectRoot $root
        Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
        Write-Host "Recovered incomplete rebuild activation $($completed.from_revision) -> $($completed.to_revision). Restart any running Codex or Claude Code sessions that use this package before using it."
        return
    }

    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root -AllowMissing
    if ($PSCmdlet.ParameterSetName -eq 'Apply') {
        if ($null -eq $pointer) {
            $candidate = (Assert-CandidateActivationAccepted -ProjectRoot $root -CandidateIndexRevision $Revision -BaseRevision $null -AcceptAssetReduction:$AcceptAssetReduction).Candidate
            Set-ActiveRevisionPointer -ProjectRoot $root -ActiveRevision $Revision -PreviousRevision $null -SchemaVersion 2 | Out-Null
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision $Revision -ActiveCorpusRevision ([string]$candidate.CorpusRevision) -CandidateRevision $Revision -CandidateCorpusRevision ([string]$candidate.CorpusRevision) -Message 'The initial verified index revision was activated locally.' | Out-Null
            Update-ManagedChecksumsIfPresent -ProjectRoot $root
            Write-Host "Activated initial index revision $Revision. Restart any running Codex or Claude Code sessions that use this package before using it."
            return
        }
        if ([int]$pointer.schema_version -eq 1) { $pointer = Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root -AdditionalValidatedRevisions @($Revision) }
        $base = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index
        if ($Revision -ceq [string]$base.IndexRevision) {
            $current = Assert-Revision -ProjectRoot $root -Revision $Revision -IdentityMode Index -RequireCurrent
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision $Revision -ActiveCorpusRevision ([string]$current.CorpusRevision) -CandidateRevision $Revision -CandidateCorpusRevision ([string]$current.CorpusRevision) -Message 'The requested verified index revision is already active locally.' | Out-Null
            Update-ManagedChecksumsIfPresent -ProjectRoot $root
            Write-Host "Index revision $Revision is already active; status and managed checksums were reconciled."
            return
        }
        Assert-CandidateActivationAccepted -ProjectRoot $root -CandidateIndexRevision $Revision -BaseRevision $base -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
        Start-RevisionTransition -ProjectRoot $root -Operation apply -FromRevision ([string]$base.IndexRevision) -ToRevision $Revision | Out-Null
        $completed = Complete-RevisionTransition -ProjectRoot $root
        Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
        Write-Host "Activated rebuilt index revision $Revision. Restart any running Codex or Claude Code sessions that use this package before using it."
        return
    }

    if ($null -ne $pointer -and [int]$pointer.schema_version -eq 1 -and (Test-Path -LiteralPath (Join-Path $root 'checksums.sha256') -PathType Leaf)) {
        $pointer = Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root
    }
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    $base = if ($null -eq $pointer) { $null } else { Assert-ManifestAndCorpus -ProjectRoot $root }
    if ($null -eq $base) {
        Write-Host 'No active revision exists; importing the trusted root CHMs into an inactive candidate.'
        $records = Get-SourceRecordsFromRootMigration -ProjectRoot $root
    } else {
        Write-Host "Building an inactive index candidate from corpus $($base.CorpusRevision)."
        $records = Get-SourceRecordsFromActiveRevision -ProjectRoot $root
    }
    $candidate = New-RevisionCandidate -ProjectRoot $root -SourceRecords $records -WorkingRoot $work -ExtractionTimeoutSeconds $ExtractionTimeoutSeconds -HhTimeoutSeconds $HhTimeoutSeconds
    if ($null -ne $base) {
        if (Assert-DeterministicRebuildResult -BaseRevision $base -CandidateRevision $candidate) {
            Write-Host "The verified index is already current: $($candidate.IndexRevision)"
            return
        }
        $node = Resolve-NodeExecutable -ProjectRoot $root
        $baseInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $base.DatabasePath
        Assert-NoRevisionTopicLoss -BaseRevision $base -CandidateRevision $candidate -BaseInspection $baseInspection -CandidateInspection $candidate.Inspection -Context 'rebuild stage' | Out-Null
    }
    $sourceCounts = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $baseCount = if ($null -eq $base) { 0 } else { [int]$base.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count }
        $newCount = [int]$candidate.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        $sourceCounts[$definition.Id] = [ordered]@{ base=$baseCount; candidate=$newCount; delta=($newCount-$baseCount) }
    }
    # The immutable base was inspected once above; reuse it for both reports
    # (Update-Documentation.ps1 does the same).
    $changes = if ($null -eq $base) { Get-TopicChangeReport -BaseInspection $null -CandidateInspection $candidate.Inspection } else { Get-TopicChangeReport -BaseInspection $baseInspection -CandidateInspection $candidate.Inspection }
    $baseAssetInspection = if ($null -eq $base) { $null } else { $baseInspection }
    $assetChanges = Get-AssetChangeReport -BaseInspection $baseAssetInspection -CandidateInspection $candidate.Inspection
    $rankings = [ordered]@{}; foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) { $row=$candidate.Inspection.ranking.PSObject.Properties[$query].Value; $rankings[$query]=[ordered]@{title=[string]$row.title;source=[string]$row.source} }
    $stageReport = New-StagedRevisionReportValue -Revision ([string]$candidate.IndexRevision) -CorpusRevision ([string]$candidate.CorpusRevision) -BaseRevision $(if ($null -eq $base) { $null } else { [string]$base.IndexRevision }) -BaseCorpusRevision $(if ($null -eq $base) { $null } else { [string]$base.CorpusRevision }) -SourceTopicCounts $sourceCounts -Changes $changes -AssetChanges $assetChanges -RequiredRankings $rankings
    $allowLegacyBase = $null -ne $base -and (
        [int]$base.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion -or
        ([int]$base.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and [string]$base.Manifest.index_contract -cne $script:IndexContract)
    )
    Start-RevisionStageInstall -ProjectRoot $root -Operation rebuild -Candidate $candidate -StageReport $stageReport -AllowLegacyActive:$allowLegacyBase | Out-Null
    $installedRoot = Install-RevisionCandidate -ProjectRoot $root -Candidate $candidate
    Complete-RevisionStageInstall -ProjectRoot $root | Out-Null
    $installed = Assert-Revision -ProjectRoot $root -Revision ([string]$candidate.IndexRevision) -IdentityMode Index -RequireCurrent
    $installedReport = Join-Path $installedRoot 'stage-report.json'
    Assert-StagedRevisionReport -Path $installedReport -ExpectedRevision ([string]$candidate.IndexRevision) | Out-Null
    if ($null -ne $base) {
        Set-UpdateStatus -ProjectRoot $root -Status 'different-revision-available' -ActiveRevision ([string]$base.IndexRevision) -ActiveCorpusRevision ([string]$base.CorpusRevision) -CandidateRevision ([string]$candidate.IndexRevision) -CandidateCorpusRevision ([string]$candidate.CorpusRevision) -Message 'A validated rebuilt index revision is staged and remains inactive until explicitly applied.' | Out-Null
    }
    Write-Host "Staged inactive index revision: $($candidate.IndexRevision)"
    Write-Host "Assets: +$($assetChanges.added_count) -$($assetChanges.removed_count) changed=$($assetChanges.changed_count) exposed=$($assetChanges.candidate_exposed_count) excluded=$($assetChanges.candidate_excluded_count)"
    Write-Host "Apply with: .\Rebuild-Index.ps1 -Apply -Revision $($candidate.IndexRevision)"
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if (Test-Path -LiteralPath $work -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $work }
}
