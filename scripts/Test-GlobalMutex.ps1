[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$tempRoot = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
$fixtureRoot = Join-Path $tempRoot ('mql5-chm-global-mutex-' + [Guid]::NewGuid().ToString('N'))
$maintenanceRoot = Join-Path $fixtureRoot 'maintenance'
$lockPath = Join-Path $maintenanceRoot '.update.lock'
$signalPath = Join-Path $fixtureRoot 'holder.ready'
$helperPath = Join-Path $fixtureRoot 'holder.ps1'
$holder = $null
$keepAlive = $null
$lease = $null

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'package.json'), '{}', (New-Object Text.UTF8Encoding($false)))
    $openFailure = $false
    try {
        Enter-ExclusiveFileLock -Path $lockPath -IdentityRoot $fixtureRoot -TimeoutSeconds 1 -InternalMutexFactory { param($name) throw 'synthetic global mutex open failure' } | Out-Null
    } catch { $openFailure = $_.Exception.Message -match 'no maintenance files were changed' }
    if (-not $openFailure) { throw 'Synthetic machine-global mutex open failure was not reported.' }
    if (Test-Path -LiteralPath $maintenanceRoot) { throw 'Machine-global mutex open failure mutated the missing maintenance directory.' }

    New-Item -ItemType Directory -Path $maintenanceRoot -Force | Out-Null
    $firstUseRecovery = Enter-ExclusiveFileLock -Path $lockPath -IdentityRoot $fixtureRoot -TimeoutSeconds 5
    $firstUseRecovery.Dispose()
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf) -or (Get-Item -LiteralPath $lockPath).Length -ne 0) {
        throw 'An empty interrupted development maintenance directory was not safely recovered.'
    }

    $portableFixture = Join-Path $fixtureRoot 'portable-marker-cutpoint'
    New-Item -ItemType Directory -Path (Join-Path $portableFixture 'maintenance') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $portableFixture '.mql5-chm-package-root'), "mql5-chm-portable-package-v1`n", (New-Object Text.UTF8Encoding($false)))
    $portableMissingMarkerRejected = $false
    try {
        Enter-ExclusiveFileLock -Path (Join-Path $portableFixture 'maintenance\.update.lock') -IdentityRoot $portableFixture -TimeoutSeconds 5 | Out-Null
    } catch { $portableMissingMarkerRejected = $_.Exception.Message -match 'missing its zero-byte lock marker' }
    if (-not $portableMissingMarkerRejected -or (Test-Path -LiteralPath (Join-Path $portableFixture 'maintenance\.update.lock'))) {
        throw 'A damaged portable maintenance marker was recreated instead of being rejected.'
    }

    $markerHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash

    $seed = Enter-ExclusiveFileLock -Path $lockPath -IdentityRoot $fixtureRoot -TimeoutSeconds 5
    if ([string]$seed.Name -notlike 'Global\Mql5ChmMcp-*') { throw 'Maintenance mutex is not machine-global.' }
    $keepAlive = New-Object Threading.Mutex($false, [string]$seed.Name)
    $seed.Dispose()

    $helper = @'
param([string]$CommonPath,[string]$IdentityRoot,[string]$LockPath,[string]$SignalPath)
$ErrorActionPreference='Stop'
. $CommonPath
$lease=Enter-ExclusiveFileLock -Path $LockPath -IdentityRoot $IdentityRoot -TimeoutSeconds 5
[IO.File]::WriteAllText($SignalPath,'ready',(New-Object Text.UTF8Encoding($false)))
[Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
'@
    [IO.File]::WriteAllText($helperPath, $helper, (New-Object Text.UTF8Encoding($false)))
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    $argumentList = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $helperPath + '"'),
        '-CommonPath',('"' + (Join-Path $PSScriptRoot 'Common.ps1') + '"'),
        '-IdentityRoot',('"' + $fixtureRoot + '"'),
        '-LockPath',('"' + $lockPath + '"'),'-SignalPath',('"' + $signalPath + '"')
    )
    $holder = Start-Process -FilePath $pwsh -ArgumentList $argumentList -PassThru -WindowStyle Hidden
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $signalPath -PathType Leaf) -and $timer.Elapsed.TotalSeconds -lt 15) {
        if ($holder.HasExited) { throw "Mutex holder exited before acquiring the lock: $($holder.ExitCode)" }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $signalPath -PathType Leaf)) { throw 'Mutex holder did not signal acquisition.' }

    $contended = $false
    try { $lease = Enter-ExclusiveFileLock -Path $lockPath -IdentityRoot $fixtureRoot -TimeoutSeconds 1 }
    catch { if ($_.Exception.Message -like 'Timed out waiting for the exclusive lock*') { $contended = $true } else { throw } }
    finally { if ($null -ne $lease) { $lease.Dispose(); $lease=$null } }
    if (-not $contended) { throw 'A second process acquired the machine-global mutex while it was held.' }

    Stop-Process -Id $holder.Id -Force
    $holder.WaitForExit(10000) | Out-Null
    if (-not $holder.HasExited) { throw 'Forced mutex holder did not terminate.' }
    $holder.Dispose(); $holder=$null

    $lease = Enter-ExclusiveFileLock -Path $lockPath -IdentityRoot $fixtureRoot -TimeoutSeconds 5
    if ($null -eq $lease) { throw 'Abandoned machine-global mutex was not recovered.' }
    $lease.Dispose(); $lease=$null
    if ((Get-Item -LiteralPath $lockPath).Length -ne 0 -or (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -cne $markerHash) {
        throw 'Maintenance locking changed the zero-byte .update.lock marker.'
    }
    Write-Host 'Global mutex contention, forced-holder, abandoned recovery, and marker tests passed.'
} finally {
    if ($null -ne $lease) { $lease.Dispose() }
    if ($null -ne $holder) {
        try { if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue; $holder.WaitForExit(5000) | Out-Null } } finally { $holder.Dispose() }
    }
    if ($null -ne $keepAlive) { $keepAlive.Dispose() }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempRoot -Path $fixtureRoot }
}
