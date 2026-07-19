[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [ValidateRange(1,3600)][int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
$maintenanceRoot = Join-Path $root 'maintenance'; if (-not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) { New-Item -ItemType Directory -Path $maintenanceRoot | Out-Null }
$lock = $null
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -TimeoutSeconds $LockTimeoutSeconds
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    Convert-DevelopmentLegacyActivePointerForStageRecovery -ProjectRoot $root | Out-Null
    $stageRecovery = Repair-InterruptedRevisionStageInstall -ProjectRoot $root
    if ([string]$stageRecovery.State -eq 'completed') { Write-Host "Recovered incomplete $($stageRecovery.Operation) staging for inactive revision $($stageRecovery.Revision) before rollback." }
    $pending = Get-RevisionTransition -ProjectRoot $root -AllowMissing
    Assert-MaintenancePackageIntegrity -ProjectRoot $root -AllowPendingTransition:($null -ne $pending) | Out-Null
    if ($null -ne $pending) {
        if ([string]$pending.operation -ne 'rollback') { throw 'An apply transition is incomplete. Recover it with Update-Documentation.ps1 -Apply before rolling back.' }
        $identityMode = if ([int]$pending.schema_version -eq 1) { 'Corpus' } else { 'Index' }
        Assert-Revision -ProjectRoot $root -Revision ([string]$pending.from_revision) -IdentityMode $identityMode | Out-Null
        Assert-Revision -ProjectRoot $root -Revision ([string]$pending.to_revision) -IdentityMode $identityMode | Out-Null
        $completed = Complete-RevisionTransition -ProjectRoot $root
        Write-Host "Recovered incomplete rollback $($completed.from_revision) -> $($completed.to_revision). Restart Codex before using it."
        Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
        return
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$pointer.schema_version -eq 1) { $pointer = Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root }
    if ($null -eq $pointer.previous_revision) { throw 'No previous verified documentation revision is available for rollback.' }
    $current = [string]$pointer.active_revision; $previous = [string]$pointer.previous_revision
    Assert-Revision -ProjectRoot $root -Revision $current -IdentityMode Index | Out-Null
    Assert-Revision -ProjectRoot $root -Revision $previous -IdentityMode Index | Out-Null
    Start-RevisionTransition -ProjectRoot $root -Operation rollback -FromRevision $current -ToRevision $previous | Out-Null
    $completed = Complete-RevisionTransition -ProjectRoot $root
    Write-Host "Rolled back documentation revision $current -> $previous. Restart Codex before using it."
    Clear-RevisionTransition -ProjectRoot $root -ExpectedTransition $completed
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
