[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [ValidateRange(5,600)][int]$TimeoutSeconds = 120,
    [ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$maintenanceRoot = Join-Path $root 'maintenance'
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$lock = $null; $tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
Assert-NoReparsePoint -Root $tempBase -Path $tempBase
$downloadRoot = Join-Path $tempBase ('mql5-chm-update-check-' + [Guid]::NewGuid().ToString('N'))
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -IdentityRoot $root -TimeoutSeconds $LockTimeoutSeconds
    New-Item -ItemType Directory -Path $downloadRoot -ErrorAction Stop | Out-Null
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    Convert-DevelopmentLegacyActivePointerForStageRecovery -ProjectRoot $root | Out-Null
    Repair-InterruptedRevisionStageInstall -ProjectRoot $root | Out-Null
    $pending = Get-RevisionTransition -ProjectRoot $root -AllowMissing
    Assert-MaintenancePackageIntegrity -ProjectRoot $root -AllowPendingTransition:($null -ne $pending) | Out-Null
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    $active = Assert-ManifestAndCorpus -ProjectRoot $root
    try {
        Write-Host 'Downloading the three official MQL5 CHMs into temporary storage...'
        $records = Get-DownloadedSourceRecords -DownloadRoot $downloadRoot -TimeoutSeconds $TimeoutSeconds
        $candidate = Get-RevisionFromSourceRecords -SourceRecords $records
        if ($candidate -eq [string]$active.CorpusRevision) {
            $status = Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision ([string]$active.IndexRevision) -CandidateCorpusRevision $candidate -Message 'The official CHM downloads match the active local corpus revision.'
        } else {
            $status = Set-UpdateStatus -ProjectRoot $root -Status 'different-revision-available' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision $null -CandidateCorpusRevision $candidate -Message 'A different official CHM corpus revision is available. Stage it to obtain a validated index revision.'
        }
        Write-Host "Update status: $($status.status)"
        Write-Host "Active index revision: $($status.active_revision)"
        Write-Host "Active corpus revision: $($status.active_corpus_revision)"
        Write-Host "Candidate corpus revision: $($status.candidate_corpus_revision)"
    } catch {
        $message = [regex]::Replace([string]$_.Exception.Message, '[\x00-\x1f\x7f]+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'The official documentation update check failed without a diagnostic message.' }
        if ($message.Length -gt 500) { $message = $message.Substring(0,500) }
        $status = Set-UpdateStatus -ProjectRoot $root -Status 'check-unavailable' -ActiveRevision ([string]$active.IndexRevision) -ActiveCorpusRevision ([string]$active.CorpusRevision) -CandidateRevision $null -CandidateCorpusRevision $null -Message $message
        Write-Warning "Documentation update check is unavailable. $message"
    }
    if ([int]$pointer.schema_version -eq 2) {
        $activeRequiresCompatibilityValidation = [int]$active.ManifestSchemaVersion -ne $script:ManifestSchemaVersion -or [string]$active.Manifest.index_contract -cne $script:IndexContract
        Update-ManagedChecksumsIfPresent -ProjectRoot $root -AllowLegacyActive:$activeRequiresCompatibilityValidation
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if (Test-Path -LiteralPath $downloadRoot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $downloadRoot }
}
