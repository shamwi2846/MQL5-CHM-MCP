[CmdletBinding()]
param(
    [switch]$LockBoundaryOnly,
    [switch]$PackageAliasOnly,
    [switch]$OfficialDownloadDeadlineOnly,
    [switch]$SkipInstalledCorpusValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

$isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
$runningOnWindows = if ($null -ne $isWindowsVariable) {
    [bool]$isWindowsVariable.Value
} else {
    $env:OS -eq 'Windows_NT'
}
$focusedModes = @($LockBoundaryOnly,$PackageAliasOnly,$OfficialDownloadDeadlineOnly | Where-Object { $_ })
if ($focusedModes.Count -gt 1) { throw 'Choose only one focused maintenance regression mode.' }

function Assert-OfficialDownloadDeadlineRegression {
    [CmdletBinding()]
    param()

    if ($null -eq ('Mql5ChmSlowReadStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class Mql5ChmSlowReadStream : Stream
{
    private readonly byte[] payload;
    private readonly int delayMilliseconds;
    private int position;

    public Mql5ChmSlowReadStream(byte[] payload, int delayMilliseconds)
    {
        if (payload == null) throw new ArgumentNullException("payload");
        this.payload = payload;
        this.delayMilliseconds = delayMilliseconds;
    }

    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { return payload.Length; } }
    public override long Position
    {
        get { return position; }
        set { throw new NotSupportedException(); }
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        Thread.Sleep(delayMilliseconds);
        return CopyNextByte(buffer, offset, count);
    }

    public override async Task<int> ReadAsync(
        byte[] buffer,
        int offset,
        int count,
        CancellationToken cancellationToken)
    {
        await Task.Delay(delayMilliseconds, cancellationToken).ConfigureAwait(false);
        return CopyNextByte(buffer, offset, count);
    }

    private int CopyNextByte(byte[] buffer, int offset, int count)
    {
        if (position >= payload.Length) return 0;
        if (count < 1) return 0;
        buffer[offset] = payload[position++];
        return 1;
    }

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
'@
    }

    $tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
    $fixture = Join-Path $tempBase ('mql5-chm-official-download-deadline-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $destination = Join-Path $fixture 'candidate.chm'
    $observation = [pscustomobject]@{ Calls=0 }
    $provider = {
        param([uri]$CurrentUri, [Threading.CancellationToken]$CancellationToken)
        $observation.Calls++
        [void]([Threading.Tasks.Task]::Delay(1000,$CancellationToken).GetAwaiter().GetResult())
        $headers = New-Object Net.WebHeaderCollection
        if ($observation.Calls -le 2) {
            $headers['Location'] = "https://www.mql5.com/files/docs/deadline-$($observation.Calls).chm"
            $stream = [IO.Stream]::Null
            $statusCode = 302
            $contentLength = 0
        } else {
            $stream = New-Object Mql5ChmSlowReadStream(
                [Text.Encoding]::ASCII.GetBytes('ITSFdata'),
                500
            )
            $statusCode = 200
            $contentLength = 8
        }
        $response = [pscustomobject]@{
            StatusCode=$statusCode
            Headers=$headers
            ContentLength=$contentLength
            ResponseUri=$CurrentUri
            TestStream=$stream
        }
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { return $this.TestStream }
        $response | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            if ($null -ne $this.TestStream) { $this.TestStream.Dispose() }
        }
        return $response
    }.GetNewClosure()

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $deadlineError = $null
    try {
        Invoke-OfficialChmDownload `
            -Uri ([uri]'https://www.mql5.com/files/docs/deadline-start.chm') `
            -Destination $destination `
            -MinimumBytes 4 `
            -MaximumBytes 102400 `
            -TimeoutSeconds 5 `
            -InternalTestHooks @{GetResponse=$provider} | Out-Null
    } catch {
        $deadlineError = $_.Exception.Message
    } finally {
        $timer.Stop()
        if (Test-Path -LiteralPath $fixture -PathType Container) {
            Remove-SafeDirectory -ConfinementRoot $tempBase -Path $fixture
        }
    }

    if ($null -eq $deadlineError -or $deadlineError -notmatch '5-second deadline') {
        throw "Official CHM download did not enforce one end-to-end deadline. Error: $deadlineError"
    }
    if ($timer.Elapsed.TotalSeconds -gt 7.0) {
        throw "Official CHM download deadline reset across redirects or trickle reads: $($timer.Elapsed.TotalSeconds) seconds."
    }
    if ($observation.Calls -ne 3) {
        throw "Official CHM deadline fixture did not reach the redirected trickle stream: $($observation.Calls) responses."
    }

    $commonSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Common.ps1') -Raw
    $downloadStart = $commonSource.IndexOf('function Invoke-OfficialChmDownload',[StringComparison]::Ordinal)
    $downloadEnd = $commonSource.IndexOf('function Get-ValidatedRevisionChecksumFiles',[StringComparison]::Ordinal)
    if ($downloadStart -lt 0 -or $downloadEnd -le $downloadStart) {
        throw 'Could not isolate Invoke-OfficialChmDownload for deadline regression validation.'
    }
    $downloadSource = $commonSource.Substring($downloadStart,$downloadEnd-$downloadStart)
    if ($downloadSource.Contains('Get-FileHash') -or -not $downloadSource.Contains('-HashAlgorithm')) {
        throw 'Official CHM SHA-256 is not computed inside the cancellable bounded stream copy.'
    }
}

function Assert-PhysicalLockAliasSerialization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixtureRoot)

    $fixtureRootFull = Resolve-FullPath -Path $FixtureRoot -MustExist -PathType Container
    $aliasFixture = Join-Path $fixtureRootFull ('mql5-chm-lock-alias-' + [Guid]::NewGuid().ToString('N'))
    $aliasLease = $null
    try {
        $aliasMaintenance = Join-Path $aliasFixture 'maintenance'
        New-Item -ItemType Directory -Path $aliasMaintenance -Force | Out-Null
        $dosLockPath = Join-Path $aliasMaintenance '.update.lock'
        [IO.File]::WriteAllBytes($dosLockPath, (New-Object byte[] 0))

        $driveRoot = [IO.Path]::GetPathRoot($aliasMaintenance)
        $mountvol = Invoke-NativeCapture -FilePath (Join-Path $env:SystemRoot 'System32\mountvol.exe') -Arguments @($driveRoot, '/L')
        if ($mountvol.ExitCode -ne 0) { throw "mountvol could not resolve '$driveRoot': $($mountvol.Text)" }
        $volumeRoot = $mountvol.Text.Trim()
        if ($volumeRoot -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { throw "mountvol returned an unexpected volume path: '$volumeRoot'" }
        if (-not $aliasMaintenance.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Fixture path is not on its resolved drive root: $aliasMaintenance"
        }
        $relativeMaintenance = $aliasMaintenance.Substring($driveRoot.Length).TrimStart('\','/')
        $volumeLockPath = [IO.Path]::Combine($volumeRoot, $relativeMaintenance, '.update.lock')

        $aliasHelper = Join-Path $aliasFixture 'try-lock.ps1'
        $helperSource = @'
param([string]$CommonPath, [string]$LockPath)
$ErrorActionPreference = 'Stop'
. $CommonPath
$lease = $null
try {
    $lease = Enter-ExclusiveFileLock -Path $LockPath -TimeoutSeconds 1
    exit 42
} catch {
    if ($_.Exception.Message -like 'Timed out waiting for the exclusive lock*') { exit 0 }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 41
} finally {
    if ($null -ne $lease) { $lease.Dispose() }
}

'@
        [IO.File]::WriteAllText($aliasHelper, $helperSource, (New-Object Text.UTF8Encoding($false)))

        $aliasLease = Enter-ExclusiveFileLock -Path $dosLockPath -TimeoutSeconds 5
        if ([string]$aliasLease.Name -notlike 'Global\Mql5ChmMcp-*') {
            throw "Maintenance lock was not created in the machine-global namespace: $($aliasLease.Name)"
        }
        $aliasResult = Invoke-NativeCapture -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $aliasHelper,
            (Join-Path $PSScriptRoot 'Common.ps1'), $volumeLockPath
        )
        if ($aliasResult.ExitCode -eq 42) { throw 'The volume-GUID alias independently acquired a lock already held through its DOS path.' }
        if ($aliasResult.ExitCode -ne 0) { throw "The volume-GUID alias lock probe failed instead of contending for the physical lock: $($aliasResult.Text)" }
    } finally {
        if ($null -ne $aliasLease) { $aliasLease.Dispose() }
        if (Test-Path -LiteralPath $aliasFixture -PathType Container) { Remove-SafeDirectory -ConfinementRoot $fixtureRootFull -Path $aliasFixture }
    }
}


function Assert-PackagePhysicalAliasRegressions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixtureRoot)

    if (-not $runningOnWindows) { throw 'The package physical-alias regressions require Windows volume aliases.' }
    $fixtureRootFull = Resolve-FullPath -Path $FixtureRoot -MustExist -PathType Container
    $aliasScope = Join-Path $fixtureRootFull ('mql5-chm-package-alias-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $aliasScope -Force | Out-Null

    function ConvertTo-VolumeGuidFixturePath {
        param([Parameter(Mandatory)][string]$DosPath)
        $dosFull = [IO.Path]::GetFullPath($DosPath)
        $driveRoot = [IO.Path]::GetPathRoot($dosFull)
        $mountvol = Invoke-NativeCapture -FilePath (Join-Path $env:SystemRoot 'System32\mountvol.exe') -Arguments @($driveRoot, '/L')
        if ($mountvol.ExitCode -ne 0) { throw "mountvol could not resolve '$driveRoot': $($mountvol.Text)" }
        $volumeRoot = $mountvol.Text.Trim()
        if ($volumeRoot -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { throw "mountvol returned an unexpected volume path: '$volumeRoot'" }
        if (-not $dosFull.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Fixture path is not on its resolved drive root: $dosFull"
        }
        $relative = $dosFull.Substring($driveRoot.Length).TrimStart('\','/')
        if ([string]::IsNullOrWhiteSpace($relative)) { return $volumeRoot }
        return [IO.Path]::Combine($volumeRoot, $relative)
    }

    function New-OwnedPackageFixture {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Path '.mql5-chm-package-root'), "mql5-chm-portable-package-v1`n", (New-Object Text.UTF8Encoding($false)))
        $sentinel = Join-Path $Path 'immutable-input-sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'preserve-input', (New-Object Text.UTF8Encoding($false)))
        return $sentinel
    }

    try {
        # Existing stage: the volume-GUID spelling physically equals the input
        # package. Acceptance lets Reset-OwnedPackageStage delete that input.
        $existingParent = Join-Path $aliasScope 'existing-stage'; New-Item -ItemType Directory -Path $existingParent | Out-Null
        $existingPackage = Join-Path $existingParent 'portable-source'
        $existingSentinel = New-OwnedPackageFixture -Path $existingPackage
        $existingAliasParent = ConvertTo-VolumeGuidFixturePath -DosPath $existingParent
        $existingRejected = $false
        try {
            $existingPlan = Assert-PackageOutputPlan -Root $existingPackage -ReleaseRoot $existingAliasParent -StageRoot (Join-Path $existingAliasParent 'portable-source') -ZipPath (Join-Path $existingAliasParent 'portable-source.zip')
            Reset-OwnedPackageStage -ReleaseRoot $existingPlan.ReleaseRoot -StageRoot $existingPlan.StageRoot | Out-Null
        } catch { $existingRejected = $true }
        if (-not $existingRejected -or -not (Test-Path -LiteralPath $existingSentinel -PathType Leaf)) {
            throw 'A volume-GUID stage physically equal to the input package was not rejected before reset mutation.'
        }

        # Not-yet-created stage: the aliased output is physically beneath the
        # project even though no output leaf exists yet.
        $futureParent = Join-Path $aliasScope 'future-stage'; New-Item -ItemType Directory -Path $futureParent | Out-Null
        $futureProject = Join-Path $futureParent 'project'; New-Item -ItemType Directory -Path $futureProject | Out-Null
        $futureSentinel = Join-Path $futureProject 'immutable-project-sentinel.txt'; [IO.File]::WriteAllText($futureSentinel, 'preserve-project')
        $futureAliasParent = ConvertTo-VolumeGuidFixturePath -DosPath $futureParent
        $futureStage = Join-Path $futureAliasParent 'project\future-output'
        $futureRejected = $false
        try {
            $futurePlan = Assert-PackageOutputPlan -Root $futureProject -ReleaseRoot $futureAliasParent -StageRoot $futureStage -ZipPath (Join-Path $futureAliasParent 'future-output.zip')
            Reset-OwnedPackageStage -ReleaseRoot $futurePlan.ReleaseRoot -StageRoot $futurePlan.StageRoot | Out-Null
        } catch { $futureRejected = $true }
        if (-not $futureRejected -or -not (Test-Path -LiteralPath $futureSentinel -PathType Leaf) -or (Test-Path -LiteralPath $futureStage)) {
            throw 'A not-yet-created volume-GUID stage physically inside the project was not rejected before mutation.'
        }

        # Existing and future ZIP targets must also be compared physically
        # with protected paths, not only the stage directory.
        $zipProject = Join-Path $aliasScope 'zip-project'; New-Item -ItemType Directory -Path $zipProject | Out-Null
        $zipOutput = Join-Path $aliasScope 'zip-output'; New-Item -ItemType Directory -Path $zipOutput | Out-Null
        $zipAliasOutput = ConvertTo-VolumeGuidFixturePath -DosPath $zipOutput
        $protectedZip = Join-Path $zipOutput 'candidate.zip'; [IO.File]::WriteAllText($protectedZip, 'known-good-zip')
        $protectedZipHash = (Get-FileHash -LiteralPath $protectedZip -Algorithm SHA256).Hash
        $zipRejected = $false
        try {
            $zipPlan = Assert-PackageOutputPlan -Root $zipProject -ReleaseRoot $zipAliasOutput -StageRoot (Join-Path $zipAliasOutput 'candidate') -ZipPath (Join-Path $zipAliasOutput 'candidate.zip') -ProtectedSources @($protectedZip)
            [IO.File]::WriteAllText($zipPlan.ZipPath, 'mutated-zip')
        } catch { $zipRejected = $true }
        if (-not $zipRejected -or (Get-FileHash -LiteralPath $protectedZip -Algorithm SHA256).Hash -cne $protectedZipHash) {
            throw 'A volume-GUID ZIP physically equal to a protected file was not rejected before mutation.'
        }

        $futureProtectedZip = Join-Path $zipOutput 'future.zip'
        $futureZipRejected = $false
        try {
            $futureZipPlan = Assert-PackageOutputPlan -Root $zipProject -ReleaseRoot $zipAliasOutput -StageRoot (Join-Path $zipAliasOutput 'future') -ZipPath (Join-Path $zipAliasOutput 'future.zip') -ProtectedSources @($futureProtectedZip)
            [IO.File]::WriteAllText($futureZipPlan.ZipPath, 'created-through-alias')
        } catch { $futureZipRejected = $true }
        if (-not $futureZipRejected -or (Test-Path -LiteralPath $futureProtectedZip)) {
            throw 'A not-yet-created volume-GUID ZIP equal to a protected path was not rejected before mutation.'
        }

        # A physical alias is still valid when it names the normal development
        # release subtree and does not overlap a protected source.
        $allowedProject = Join-Path $aliasScope 'allowed-project'; New-Item -ItemType Directory -Path $allowedProject | Out-Null
        $allowedRelease = Join-Path $allowedProject 'release'; New-Item -ItemType Directory -Path $allowedRelease | Out-Null
        $allowedProtected = Join-Path $allowedProject 'scripts'; New-Item -ItemType Directory -Path $allowedProtected | Out-Null
        $allowedAliasRelease = ConvertTo-VolumeGuidFixturePath -DosPath $allowedRelease
        $allowedPlan = Assert-PackageOutputPlan -Root $allowedProject -ReleaseRoot $allowedAliasRelease -StageRoot (Join-Path $allowedAliasRelease 'candidate') -ZipPath (Join-Path $allowedAliasRelease 'candidate.zip') -ProtectedSources @($allowedProtected)
        if (-not (Test-PhysicalPathWithinOrEqual -Path $allowedPlan.StageRoot -Root $allowedRelease)) {
            throw 'A safe aliased development release plan did not retain its physical output boundary.'
        }

        # SUBST creates another non-reparse lexical alias. Exercise it when a
        # free drive letter is available on the test machine.
        $substLetter = $null
        foreach ($code in 90..80) {
            $candidateLetter = [char]$code
            if (-not (Test-Path -LiteralPath ("$candidateLetter`:\") -ErrorAction SilentlyContinue)) { $substLetter = $candidateLetter; break }
        }
        if ($null -ne $substLetter) {
            $substParent = Join-Path $aliasScope 'subst-stage'; New-Item -ItemType Directory -Path $substParent | Out-Null
            $substPackage = Join-Path $substParent 'portable-source'
            $substSentinel = New-OwnedPackageFixture -Path $substPackage
            $substDrive = "$substLetter`:"
            $substCreated = $false
            try {
                $substCreate = Invoke-NativeCapture -FilePath (Join-Path $env:SystemRoot 'System32\subst.exe') -Arguments @($substDrive, $substParent)
                if ($substCreate.ExitCode -eq 0) {
                    $substCreated = $true
                    $substRelease = "$substDrive\"
                    $substRejected = $false
                    try {
                        $substPlan = Assert-PackageOutputPlan -Root $substPackage -ReleaseRoot $substRelease -StageRoot (Join-Path $substRelease 'portable-source') -ZipPath (Join-Path $substRelease 'portable-source.zip')
                        Reset-OwnedPackageStage -ReleaseRoot $substPlan.ReleaseRoot -StageRoot $substPlan.StageRoot | Out-Null
                    } catch { $substRejected = $true }
                    if (-not $substRejected -or -not (Test-Path -LiteralPath $substSentinel -PathType Leaf)) {
                        throw 'A SUBST stage physically equal to the input package was not rejected before reset mutation.'
                    }
                    Write-Host 'SUBST package physical-alias regression passed.'
                } else {
                    Write-Host "SUBST package-alias regression skipped: $($substCreate.Text)"
                }
            } finally {
                if ($substCreated) {
                    $substRemove = Invoke-NativeCapture -FilePath (Join-Path $env:SystemRoot 'System32\subst.exe') -Arguments @($substDrive, '/D')
                    if ($substRemove.ExitCode -ne 0) { throw "Could not remove package test SUBST drive '$substDrive': $($substRemove.Text)" }
                }
            }
        } else {
            Write-Host 'SUBST package-alias regression skipped: no free drive letter was available.'
        }
    } finally {
        if (Test-Path -LiteralPath $aliasScope -PathType Container) { Remove-SafeDirectory -ConfinementRoot $fixtureRootFull -Path $aliasScope }
    }
}
if ($OfficialDownloadDeadlineOnly) {
    Assert-OfficialDownloadDeadlineRegression
    Write-Host 'Focused official CHM end-to-end deadline regression passed.'
    return
}

if ($LockBoundaryOnly) {
    if (-not $runningOnWindows) { throw 'The focused nested-junction lock regression requires Windows junction support.' }
    $focusedTempRoot = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
    $focusedFixture = Join-Path $focusedTempRoot ('mql5-chm-lock-boundary-' + [Guid]::NewGuid().ToString('N'))
    $focusedTarget = Join-Path $focusedFixture 'target'
    $focusedChild = Join-Path $focusedTarget 'ordinary-child'
    $focusedJunction = Join-Path $focusedFixture 'junction'
    New-Item -ItemType Directory -Path $focusedChild -Force | Out-Null
    New-Item -ItemType Junction -Path $focusedJunction -Target $focusedTarget | Out-Null
    $focusedLease = $null
    $focusedRejected = $false
    try {
        $focusedLease = Enter-ExclusiveFileLock -Path (Join-Path $focusedJunction 'ordinary-child\.update.lock') -TimeoutSeconds 1
    } catch {
        $focusedRejected = $true
    } finally {
        if ($null -ne $focusedLease) { $focusedLease.Dispose() }
        if (Test-Path -LiteralPath $focusedJunction) { [IO.Directory]::Delete($focusedJunction) }
        if (Test-Path -LiteralPath $focusedFixture -PathType Container) { Remove-SafeDirectory -ConfinementRoot $focusedTempRoot -Path $focusedFixture }
    }
    if (-not $focusedRejected) { throw 'The shared lock primitive accepted a lock path beneath a reparse-point ancestor.' }

    # A DOS drive path and its volume-GUID spelling can identify the same
    # physical directory without either path containing a reparse point.
    Assert-PhysicalLockAliasSerialization -FixtureRoot $focusedTempRoot
    Write-Host 'Focused lock boundary and physical-alias regressions passed.'
    return
}

if ($PackageAliasOnly) {
    if (-not $runningOnWindows) { throw 'The focused package-alias regressions require Windows.' }
    $packageTempRoot = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
    $packageFixture = Join-Path $packageTempRoot ('mql5-chm-package-alias-focused-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $packageFixture | Out-Null
    try {
        $packageScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Package-Portable.ps1'
        $packageTokens=$null;$packageParseErrors=$null
        $packageAst=[Management.Automation.Language.Parser]::ParseFile($packageScriptPath,[ref]$packageTokens,[ref]$packageParseErrors)
        if($packageParseErrors.Count){throw 'Package script did not parse for focused safety-helper tests.'}
        foreach($functionName in @('Test-PathWithinOrEqual','Test-PathsOverlap','Get-PhysicalPathDescriptor','Test-PhysicalDescriptorWithinOrEqual','Test-PhysicalDescriptorsEqual','Test-PhysicalDescriptorsOverlap','Test-PhysicalPathWithinOrEqual','Test-PhysicalPathsEqual','Test-PhysicalPathsOverlap','Assert-PackageOutputPlan','Reset-OwnedPackageStage')){
            $definition=$packageAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$true)
            if($null -eq $definition){throw "Package safety helper '$functionName' is missing."}
            Invoke-Expression $definition.Extent.Text
        }
        $script:PackageRootMarkerName='.mql5-chm-package-root';$script:PackageRootMarkerValue='mql5-chm-portable-package-v1'
        Assert-PackagePhysicalAliasRegressions -FixtureRoot $packageFixture
    } finally {
        if (Test-Path -LiteralPath $packageFixture -PathType Container) { Remove-SafeDirectory -ConfinementRoot $packageTempRoot -Path $packageFixture }
    }
    Write-Host 'Focused package physical-alias regressions passed.'
    return
}

Assert-OfficialDownloadDeadlineRegression

$hashes = [pscustomobject]@{
    mql5='b6b3338a985e1efedc2c87fa478f648d7de53e1daa6d2a8a9e5359b8878e23fa'
    mql5book='4c0d0e6ce858b410f63969fc5d6b64076da73ae7f4c010c212b6993d018a1f17'
    neuronetworksbook='fe9470e6ac9452e34ecc54cd80dddf59475c8ae23cac7b5ef071b17f1c32d8f5'
}
$expected = '8d058569d975ec5b5ec419770d952757acd0ea51ad8b63fe78eb49fb00751adc'
if ((Get-CorpusRevision -SourceHashes $hashes) -cne $expected) { throw 'Canonical corpus revision fixture failed.' }

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
if (-not $SkipInstalledCorpusValidation) {
    $sevenZip = Resolve-SevenZipExtractor -Root $projectRoot
    if ([string]::IsNullOrWhiteSpace($sevenZip)) { throw 'Maintenance acceptance requires the bundled CHM-capable 7-Zip executable.' }
    $activeFixture = Assert-ManifestAndCorpus -ProjectRoot $projectRoot
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $listedCount = Get-ChmHtmlTopicCount -SevenZip $sevenZip -ChmPath (Join-Path $activeFixture.Root $definition.FileName)
        $manifestCount = [int]$activeFixture.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        if ($listedCount -ne $manifestCount) { throw "Independent CHM directory count failed for '$($definition.FileName)': $listedCount != $manifestCount." }
    }
}

$validRankings = [pscustomobject]@{}
foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) { $validRankings | Add-Member -NotePropertyName $query -NotePropertyValue ([pscustomobject]@{title=$query;source='mql5'}) }
$validInspection = [pscustomobject]@{ integrity=@('ok'); topic_count=4; section_count=4; fts_count=4; ranking=$validRankings; topics=[pscustomobject]@{} }
Assert-DatabaseInspectionResult -Inspection $validInspection | Out-Null
$badIntegrity = $validInspection.PSObject.Copy(); $badIntegrity.integrity = @('corrupt')
$integrityRejected = $false; try { Assert-DatabaseInspectionResult -Inspection $badIntegrity | Out-Null } catch { $integrityRejected = $true }
if (-not $integrityRejected) { throw 'Database acceptance accepted a failed integrity check.' }
$badRanking = $validInspection.PSObject.Copy(); $badRanking.ranking = [pscustomobject]@{}
$rankingRejected = $false; try { Assert-DatabaseInspectionResult -Inspection $badRanking | Out-Null } catch { $rankingRejected = $true }
if (-not $rankingRejected) { throw 'Database acceptance accepted missing representative topics.' }

$baseSources = [pscustomobject]@{ mql5=[pscustomobject]@{topic_count=1}; mql5book=[pscustomobject]@{topic_count=1}; neuronetworksbook=[pscustomobject]@{topic_count=1} }
$lossSources = [pscustomobject]@{ mql5=[pscustomobject]@{topic_count=0}; mql5book=[pscustomobject]@{topic_count=1}; neuronetworksbook=[pscustomobject]@{topic_count=1} }
$fixtureCorpus = ('a' * 64)
$baseRevisionFixture = [pscustomobject]@{ CorpusRevision=$fixtureCorpus; Manifest=[pscustomobject]@{sources=$baseSources} }
$lossRevisionFixture = [pscustomobject]@{ CorpusRevision=('b' * 64); Manifest=[pscustomobject]@{sources=$lossSources} }
$baseTopicsFixture = [pscustomobject]@{topics=[pscustomobject]@{'mql5:topic'='a'}}
$sameTopicsFixture = [pscustomobject]@{topics=[pscustomobject]@{'mql5:topic'='a'}}
$countLossRejected = $false; try { Assert-NoRevisionTopicLoss -BaseRevision $baseRevisionFixture -CandidateRevision $lossRevisionFixture -BaseInspection $baseTopicsFixture -CandidateInspection $sameTopicsFixture -Context 'fixture' | Out-Null } catch { $countLossRejected = $true }
if (-not $countLossRejected) { throw 'Revision acceptance accepted a per-source topic-count loss.' }
$sameRevisionFixture = [pscustomobject]@{ CorpusRevision=$fixtureCorpus; Manifest=[pscustomobject]@{sources=$baseSources} }
$removedTopicsFixture = [pscustomobject]@{topics=[pscustomobject]@{}}
$stableIdLossRejected = $false; try { Assert-NoRevisionTopicLoss -BaseRevision $baseRevisionFixture -CandidateRevision $sameRevisionFixture -BaseInspection $baseTopicsFixture -CandidateInspection $removedTopicsFixture -Context 'fixture' | Out-Null } catch { $stableIdLossRejected = $true }
if (-not $stableIdLossRejected) { throw 'Revision acceptance accepted a removed stable topic ID.' }
$sameCorpusChangedInspection = [pscustomobject]@{topics=[pscustomobject]@{'mql5:topic'='different-content-hash'}}
$sameCorpusContentChangeRejected = $false
try { Assert-NoRevisionTopicLoss -BaseRevision $baseRevisionFixture -CandidateRevision $sameRevisionFixture -BaseInspection $baseTopicsFixture -CandidateInspection $sameCorpusChangedInspection -Context 'fixture' | Out-Null } catch { $sameCorpusContentChangeRejected = $true }
if (-not $sameCorpusContentChangeRejected) { throw 'Revision acceptance allowed changed topic content for identical CHM bytes.' }

$baseAssetInspectionFixture = [pscustomobject]@{
    assets=[pscustomobject]@{'mql5:asset:aaaaaaaaaaaaaaaaaaaaaaaa'=[pscustomobject]@{sha256=('a'*64);exposure='exposed';occurrence_count=2}}
    asset_summary=[pscustomobject]@{cataloged_count=1;exposed_count=1;excluded_count=0;occurrence_count=2;exposed_occurrence_count=2;total_bytes=100}
}
$reducedAssetInspectionFixture = [pscustomobject]@{
    assets=[pscustomobject]@{}
    asset_summary=[pscustomobject]@{cataloged_count=0;exposed_count=0;excluded_count=0;occurrence_count=0;exposed_occurrence_count=0;total_bytes=0}
}
$assetReductionReport = Get-AssetChangeReport -BaseInspection $baseAssetInspectionFixture -CandidateInspection $reducedAssetInspectionFixture
$assetReductionRejected = $false
try { Assert-AssetChangeReportMatches -Reported $assetReductionReport -Recomputed $assetReductionReport | Out-Null } catch { $assetReductionRejected = $true }
if (-not $assetReductionRejected) { throw 'Asset reduction was accepted without explicit review.' }
Assert-AssetChangeReportMatches -Reported $assetReductionReport -Recomputed $assetReductionReport -AcceptAssetReduction | Out-Null
$tamperedAssetReport = ($assetReductionReport | ConvertTo-Json -Depth 30) | ConvertFrom-Json
$tamperedAssetReport.removed_count = 0
$tamperedAssetReportRejected = $false
try { Assert-AssetChangeReportMatches -Reported $tamperedAssetReport -Recomputed $assetReductionReport -AcceptAssetReduction | Out-Null } catch { $tamperedAssetReportRejected = $true }
if (-not $tamperedAssetReportRejected) { throw 'A stale or tampered asset-change report was accepted.' }

$exposedOccurrenceBaseFixture = [pscustomobject]@{
    assets=[pscustomobject]@{
        'mql5:asset:aaaaaaaaaaaaaaaaaaaaaaaa'=[pscustomobject]@{sha256=('a'*64);exposure='exposed';occurrence_count=2}
        'mql5:asset:bbbbbbbbbbbbbbbbbbbbbbbb'=[pscustomobject]@{sha256=('b'*64);exposure='excluded';occurrence_count=0}
    }
    asset_summary=[pscustomobject]@{cataloged_count=2;exposed_count=1;excluded_count=1;occurrence_count=2;exposed_occurrence_count=2;total_bytes=200}
}
$exposedOccurrenceReducedFixture = [pscustomobject]@{
    assets=[pscustomobject]@{
        'mql5:asset:aaaaaaaaaaaaaaaaaaaaaaaa'=[pscustomobject]@{sha256=('a'*64);exposure='exposed';occurrence_count=1}
        'mql5:asset:bbbbbbbbbbbbbbbbbbbbbbbb'=[pscustomobject]@{sha256=('b'*64);exposure='excluded';occurrence_count=1}
    }
    asset_summary=[pscustomobject]@{cataloged_count=2;exposed_count=1;excluded_count=1;occurrence_count=2;exposed_occurrence_count=1;total_bytes=200}
}
$exposedOccurrenceReductionReport = Get-AssetChangeReport -BaseInspection $exposedOccurrenceBaseFixture -CandidateInspection $exposedOccurrenceReducedFixture
if ([int]$exposedOccurrenceReductionReport.cataloged_delta -ne 0 -or [int]$exposedOccurrenceReductionReport.exposed_delta -ne 0 -or [int]$exposedOccurrenceReductionReport.occurrence_delta -ne 0) {
    throw 'Exposed-occurrence fixture unexpectedly changed total asset or occurrence coverage.'
}
if ([int]$exposedOccurrenceReductionReport.base_exposed_occurrence_count -ne 2 -or [int]$exposedOccurrenceReductionReport.candidate_exposed_occurrence_count -ne 1 -or [int]$exposedOccurrenceReductionReport.exposed_occurrence_delta -ne -1) {
    throw 'Exposed-occurrence reduction was not reported exactly.'
}
$exposedOccurrenceReductionRejected = $false
try { Assert-AssetChangeReportMatches -Reported $exposedOccurrenceReductionReport -Recomputed $exposedOccurrenceReductionReport | Out-Null } catch { $exposedOccurrenceReductionRejected = $true }
if (-not $exposedOccurrenceReductionRejected) { throw 'Exposed-occurrence reduction was accepted without explicit review.' }
Assert-AssetChangeReportMatches -Reported $exposedOccurrenceReductionReport -Recomputed $exposedOccurrenceReductionReport -AcceptAssetReduction | Out-Null
$staleExposedOccurrenceReport = ($exposedOccurrenceReductionReport | ConvertTo-Json -Depth 30) | ConvertFrom-Json
$staleExposedOccurrenceReport.exposed_occurrence_delta = 0
$staleExposedOccurrenceReportRejected = $false
try { Assert-AssetChangeReportMatches -Reported $staleExposedOccurrenceReport -Recomputed $exposedOccurrenceReductionReport -AcceptAssetReduction | Out-Null } catch { $staleExposedOccurrenceReportRejected = $true }
if (-not $staleExposedOccurrenceReportRejected) { throw 'A stale exposed-occurrence delta was accepted.' }

$tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
$fixture = Join-Path $tempBase ('mql5-chm-script-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    function Assert-Fixture {
        param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
        if (-not $Condition) { throw $Message }
    }

    Assert-Fixture -Condition ($script:IndexContract -ceq 'mql5-chm-index-v3-assets-v3') -Message 'The current schema-3 index contract is not v3.'
    Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v1'
    Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v2'
    Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v3' -RequireCurrent
    $legacyCurrentContractRejected=$false;try{Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v1' -RequireCurrent}catch{$legacyCurrentContractRejected=$true}
    Assert-Fixture -Condition $legacyCurrentContractRejected -Message 'RequireCurrent accepted the rollback-only schema-3 v1 contract.'
    $previousCurrentContractRejected=$false;try{Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v2' -RequireCurrent}catch{$previousCurrentContractRejected=$true}
    Assert-Fixture -Condition $previousCurrentContractRejected -Message 'RequireCurrent accepted the rollback-only schema-3 v2 contract.'
    $unknownContractRejected=$false;try{Assert-IndexContract -Contract 'mql5-chm-index-v3-assets-v999'}catch{$unknownContractRejected=$true}
    Assert-Fixture -Condition $unknownContractRejected -Message 'Schema-3 validation accepted an unsupported index contract.'
    $currentSourceDefinition = @(Get-Mql5CorpusDefinition)[0]
    Assert-CurrentCorpusSourceIdentity -Definition $currentSourceDefinition `
        -Sha256 $currentSourceDefinition.Sha256 -TopicCount $currentSourceDefinition.TopicCount
    $staleCurrentSourceRejected=$false
    try {
        Assert-CurrentCorpusSourceIdentity -Definition $currentSourceDefinition `
            -Sha256 ('0' * 64) -TopicCount $currentSourceDefinition.TopicCount
    } catch { $staleCurrentSourceRejected=$true }
    Assert-Fixture -Condition $staleCurrentSourceRejected -Message 'RequireCurrent source identity accepted a stale CHM hash.'

    $unverifiedLayout = Join-Path $fixture 'unverified-layout'; New-Item -ItemType Directory -Path $unverifiedLayout | Out-Null
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $unverifiedLayout) -ceq 'unverified-portable') -Message 'Checksum-less portable layout was not classified as unverified.'
    $missingChecksumsRejected = $false; try { Assert-PackageChecksums -ProjectRoot $unverifiedLayout | Out-Null } catch { $missingChecksumsRejected = $true }
    Assert-Fixture -Condition $missingChecksumsRejected -Message 'Package verification accepted a missing checksums.sha256.'
    [IO.File]::WriteAllText((Join-Path $unverifiedLayout 'checksums.sha256'), '', (New-Object Text.UTF8Encoding($false)))
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $unverifiedLayout) -ceq 'portable') -Message 'Checksummed portable layout classification failed.'
    New-Item -ItemType Directory -Path (Join-Path $unverifiedLayout 'config') | Out-Null
    [IO.File]::WriteAllText((Join-Path $unverifiedLayout 'config\mql5-image-policy.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $unverifiedLayout 'config\mql5-query-expansions.json'), '{}')
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $unverifiedLayout) -ceq 'portable') -Message 'Required portable config files were misclassified as an incomplete development tree.'

    $developmentLayout = Join-Path $fixture 'development-layout'; New-Item -ItemType Directory -Path $developmentLayout | Out-Null
    [IO.File]::WriteAllText((Join-Path $developmentLayout 'package.json'), '{}', (New-Object Text.UTF8Encoding($false)))
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $developmentLayout) -ceq 'incomplete-development') -Message 'Partial development layout was not rejected.'
    foreach ($relative in @('scripts\build.mjs','src\server.mjs','src\indexer.mjs','config\mql5-query-expansions.json','config\mql5-image-policy.json','scripts\inspect-database.mjs','node_modules\esbuild\package.json')) {
        $path = Join-Path $developmentLayout $relative; $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($path, 'fixture', (New-Object Text.UTF8Encoding($false)))
    }
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $developmentLayout) -ceq 'development') -Message 'Complete development layout classification failed.'
    [IO.File]::WriteAllText((Join-Path $developmentLayout '.mql5-chm-package-root'), "mql5-chm-portable-package-v1`n", (New-Object Text.UTF8Encoding($false)))
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $developmentLayout) -ceq 'unverified-portable') -Message 'A checksum-less portable package marker was downgraded to trusted development by fake development files.'
    [IO.File]::WriteAllText((Join-Path $developmentLayout 'checksums.sha256'), 'fixture', (New-Object Text.UTF8Encoding($false)))
    Assert-Fixture -Condition ((Get-Mql5ChmLayoutMode -ProjectRoot $developmentLayout) -ceq 'portable') -Message 'A checksummed portable package was misclassified as development because development markers were present.'
    Remove-Item -LiteralPath (Join-Path $developmentLayout 'checksums.sha256') -Force
    Remove-Item -LiteralPath (Join-Path $developmentLayout '.mql5-chm-package-root') -Force

    # Load the package-safety helpers without executing the packaging script.
    $packageScriptPath = Join-Path $projectRoot 'scripts\Package-Portable.ps1'
    $packageTokens=$null;$packageParseErrors=$null
    $packageAst=[Management.Automation.Language.Parser]::ParseFile($packageScriptPath,[ref]$packageTokens,[ref]$packageParseErrors)
    if($packageParseErrors.Count){throw 'Package script did not parse for safety-helper tests.'}
    $unsafeLiveBuildCalls = @($packageAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-NativeChecked' -and
        $node.Extent.Text -match 'scripts\\build\.mjs' -and
        $node.Extent.Text -notmatch "'--outdir'"
    }, $true))
    Assert-Fixture -Condition ($unsafeLiveBuildCalls.Count -eq 0) -Message 'Portable packaging still contains a build invocation that can overwrite the live app bundles.'
    foreach ($maintenanceScriptName in @('Rebuild-Index.ps1','Update-Documentation.ps1','Check-DocumentationUpdates.ps1','Install-Codex.ps1','Package-Portable.ps1')) {
        $maintenanceScriptText = Get-Content -LiteralPath (Join-Path $projectRoot "scripts\$maintenanceScriptName") -Raw
        $rootGuardIndex = $maintenanceScriptText.IndexOf('Assert-NoReparsePoint -Root $root -Path $root',[StringComparison]::Ordinal)
        $lockIndex = $maintenanceScriptText.IndexOf('Enter-ExclusiveFileLock',[StringComparison]::Ordinal)
        Assert-Fixture -Condition ($rootGuardIndex -ge 0 -and $lockIndex -gt $rootGuardIndex) -Message "$maintenanceScriptName does not reject reparse-point ancestors before deriving the maintenance-lock identity."
    }
    foreach ($maintenanceScriptName in @('Rebuild-Index.ps1','Update-Documentation.ps1')) {
        $maintenanceScriptText = Get-Content -LiteralPath (Join-Path $projectRoot "scripts\$maintenanceScriptName") -Raw
        Assert-Fixture -Condition ($maintenanceScriptText.Contains('Assert-MaintenancePackageIntegrity')) -Message "$maintenanceScriptName does not perform the portable package integrity preflight before bundled/native tools."
    }
    $checkUpdatesScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Check-DocumentationUpdates.ps1') -Raw
    $checkIntegrityIndex = $checkUpdatesScriptText.IndexOf('Assert-MaintenancePackageIntegrity',[StringComparison]::Ordinal)
    $checkDownloadIndex = $checkUpdatesScriptText.IndexOf('Get-DownloadedSourceRecords',[StringComparison]::Ordinal)
    Assert-Fixture -Condition ($checkIntegrityIndex -ge 0 -and $checkDownloadIndex -gt $checkIntegrityIndex -and $checkUpdatesScriptText.Contains('Update-ManagedChecksumsIfPresent -ProjectRoot $root -AllowLegacyActive:')) -Message 'Documentation update checking can use the network before package preflight or cannot reconcile a supported noncurrent active contract.'
    $indexMaintenanceScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\IndexMaintenance.ps1') -Raw
    $updateScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Update-Documentation.ps1') -Raw
    $rebuildScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Rebuild-Index.ps1') -Raw
    $packageScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Package-Portable.ps1') -Raw
    $packageWrapperText = Get-Content -LiteralPath (Join-Path $projectRoot 'Package-Portable.ps1') -Raw
    Assert-Fixture -Condition (
        $indexMaintenanceScriptText.Contains('function Assert-CandidateActivationAccepted') -and
        $updateScriptText.Contains('Assert-CandidateActivationAccepted') -and
        $rebuildScriptText.Contains('Assert-CandidateActivationAccepted') -and
        $packageScriptText.Contains('Assert-CandidateActivationAccepted') -and
        -not $updateScriptText.Contains('function Assert-ApplyTransitionAccepted') -and
        -not $rebuildScriptText.Contains('function Assert-RebuildActivationAccepted')
    ) -Message 'Update, rebuild, and candidate packaging do not share one activation-acceptance verifier.'
    $packageBaseIndex = $packageScriptText.IndexOf('$activeBase = Assert-ManifestAndCorpus',[StringComparison]::Ordinal)
    $packageAcceptanceIndex = $packageScriptText.IndexOf('Assert-CandidateActivationAccepted',[StringComparison]::Ordinal)
    $packageNodeGateIndex = $packageScriptText.IndexOf('$node = Ensure-PinnedNodeRuntime',[StringComparison]::Ordinal)
    Assert-Fixture -Condition (
        $packageScriptText.Contains("(Join-Path `$PSScriptRoot 'IndexMaintenance.ps1')") -and
        $packageNodeGateIndex -ge 0 -and
        $packageBaseIndex -ge 0 -and
        $packageNodeGateIndex -lt $packageAcceptanceIndex -and
        $packageAcceptanceIndex -gt $packageBaseIndex -and
        $packageScriptText.Contains('-BaseRevision $activeBase') -and
        $packageScriptText.Contains('-NodePath $node') -and
        $packageScriptText.Contains('-AcceptAssetReduction:$AcceptAssetReduction') -and
        $packageWrapperText.Contains('[switch]$AcceptAssetReduction') -and
        $packageWrapperText.Contains('$arguments.AcceptAssetReduction=$true')
    ) -Message 'Candidate packaging does not verify pinned Node before semantic inspection, bind the verified runtime path, verify against the current active base, or forward explicit asset-reduction acknowledgement.'
    foreach($blockedByStageScript in @('Install-Codex.ps1','Package-Portable.ps1')){
        $blockedByStageText=Get-Content -LiteralPath (Join-Path $projectRoot "scripts\$blockedByStageScript") -Raw
        $artifactRepairPosition=$blockedByStageText.IndexOf('Repair-InterruptedMaintenanceArtifacts',[StringComparison]::Ordinal)
        $stageGuardPosition=$blockedByStageText.IndexOf('Assert-NoPendingRevisionStageInstall',[StringComparison]::Ordinal)
        Assert-Fixture -Condition ($stageGuardPosition -gt $artifactRepairPosition) -Message "$blockedByStageScript can install or package while a revision-stage transaction is pending."
    }
    $installScriptText=Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Install-Codex.ps1') -Raw
    Assert-Fixture -Condition ($installScriptText.Contains('Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive') -and -not $installScriptText.Contains('Assert-ManifestAndCorpus -ProjectRoot $root -RequireCurrent')) -Message 'The transitional installer cannot register the repaired runtime while a supported noncurrent index is active.'
    $installSmokeIndex=$installScriptText.IndexOf('Smoke-Test-McpServer.mjs',[StringComparison]::Ordinal)
    $installRegistrationIndex=$installScriptText.IndexOf('Install-CodexMql5ChmRegistration',[StringComparison]::Ordinal)
    Assert-Fixture -Condition ($installSmokeIndex -ge 0 -and $installRegistrationIndex -gt $installSmokeIndex -and $installScriptText.Contains("'--expected-active-revision'") -and $installScriptText.Contains("'--expected-index-revision'") -and $installScriptText.Contains("'--expected-corpus-revision'")) -Message 'Installer does not complete the revision-bound MCP smoke test before Codex registration.'
    $rollbackScriptText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Rollback-Documentation.ps1') -Raw
    $rollbackArtifactRepairIndex = $rollbackScriptText.IndexOf('Repair-InterruptedMaintenanceArtifacts',[StringComparison]::Ordinal)
    $rollbackStageRepairIndex = $rollbackScriptText.IndexOf('Repair-InterruptedRevisionStageInstall',[StringComparison]::Ordinal)
    $rollbackTransitionReadIndex = $rollbackScriptText.IndexOf('Get-RevisionTransition',[StringComparison]::Ordinal)
    $rollbackIntegrityIndex = $rollbackScriptText.IndexOf('Assert-MaintenancePackageIntegrity',[StringComparison]::Ordinal)
    Assert-Fixture -Condition ($rollbackScriptText.Contains("IndexMaintenance.ps1") -and $rollbackStageRepairIndex -gt $rollbackArtifactRepairIndex -and $rollbackStageRepairIndex -lt $rollbackTransitionReadIndex -and $rollbackStageRepairIndex -lt $rollbackIntegrityIndex) -Message 'Rollback can change the active base before repairing or rejecting a pending stage-install journal.'
    $rollbackProbeRoot = Join-Path $fixture 'rollback-stage-order'
    $rollbackProbeScripts = Join-Path $rollbackProbeRoot 'scripts'
    New-Item -ItemType Directory -Path $rollbackProbeScripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\Rollback-Documentation.ps1') -Destination (Join-Path $rollbackProbeScripts 'Rollback-Documentation.ps1')
    [IO.File]::WriteAllText((Join-Path $rollbackProbeScripts 'IndexMaintenance.ps1'), @'
function Add-ProbeCall { param([string]$ProjectRoot,[string]$Name) Add-Content -LiteralPath (Join-Path $ProjectRoot 'rollback-order.log') -Value $Name }
function Resolve-FullPath { param([string]$Path,[switch]$MustExist,[string]$PathType) return [IO.Path]::GetFullPath($Path) }
function Assert-NoReparsePoint { param([string]$Root,[string]$Path) }
function Enter-ExclusiveFileLock { param([string]$Path,[string]$IdentityRoot,[int]$TimeoutSeconds) $parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};return [IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
function Repair-InterruptedMaintenanceArtifacts { param([string]$ProjectRoot) Add-ProbeCall $ProjectRoot 'artifacts' }
function Convert-DevelopmentLegacyActivePointerForStageRecovery { param([string]$ProjectRoot) Add-ProbeCall $ProjectRoot 'legacy-convert'; return $null }
function Repair-InterruptedRevisionStageInstall { param([string]$ProjectRoot) Add-ProbeCall $ProjectRoot 'stage'; return [pscustomobject]@{State='completed';Operation='rebuild';Revision=('c'*64)} }
function Get-RevisionTransition { param([string]$ProjectRoot,[switch]$AllowMissing) Add-ProbeCall $ProjectRoot 'transition-read'; return $null }
function Assert-MaintenancePackageIntegrity { param([string]$ProjectRoot,[switch]$AllowPendingTransition) Add-ProbeCall $ProjectRoot 'integrity'; return $true }
function Get-ActiveRevisionPointer { param([string]$ProjectRoot) return [pscustomobject]@{schema_version=2;active_revision=('a'*64);previous_revision=('b'*64)} }
function Assert-Revision { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode) return [pscustomobject]@{IndexRevision=$Revision} }
function Start-RevisionTransition { param([string]$ProjectRoot,[string]$Operation,[string]$FromRevision,[string]$ToRevision) Add-ProbeCall $ProjectRoot 'transition-start'; return [pscustomobject]@{} }
function Complete-RevisionTransition { param([string]$ProjectRoot) Add-ProbeCall $ProjectRoot 'transition-complete'; return [pscustomobject]@{from_revision=('a'*64);to_revision=('b'*64)} }
function Clear-RevisionTransition { param([string]$ProjectRoot,[object]$ExpectedTransition) Add-ProbeCall $ProjectRoot 'transition-clear' }
'@, (New-Object Text.UTF8Encoding($false)))
    $rollbackProbe = Invoke-NativeCapture -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $rollbackProbeScripts 'Rollback-Documentation.ps1'),'-ProjectRoot',$rollbackProbeRoot)
    Assert-Fixture -Condition ($rollbackProbe.ExitCode -eq 0) -Message "Rollback stage-order integration probe failed. $($rollbackProbe.Text)"
    $rollbackOrder = @(Get-Content -LiteralPath (Join-Path $rollbackProbeRoot 'rollback-order.log'))
    $rollbackStageCall = [Array]::IndexOf($rollbackOrder,'stage')
    Assert-Fixture -Condition ($rollbackStageCall -gt [Array]::IndexOf($rollbackOrder,'artifacts') -and $rollbackStageCall -lt [Array]::IndexOf($rollbackOrder,'transition-read') -and $rollbackStageCall -lt [Array]::IndexOf($rollbackOrder,'integrity') -and $rollbackStageCall -lt [Array]::IndexOf($rollbackOrder,'transition-start')) -Message 'Rollback integration did not repair the pending stage transaction before reading or changing revision state.'
    foreach($functionName in @('Test-PathWithinOrEqual','Test-PathsOverlap','Get-PhysicalPathDescriptor','Test-PhysicalDescriptorWithinOrEqual','Test-PhysicalDescriptorsEqual','Test-PhysicalDescriptorsOverlap','Test-PhysicalPathWithinOrEqual','Test-PhysicalPathsEqual','Test-PhysicalPathsOverlap','Assert-PackageOutputPlan','Reset-OwnedPackageStage','Write-CanonicalPortableActivePointer','New-ReproduciblePackageZip','Assert-PackageZipMatchesStage','Test-JsonIntegerValue','Assert-PackageZipSidecar','Write-PackageSidecarDurable','Assert-PreparedPackageManifestShape','Repair-PackagePreparedOrphans','Repair-PackageZipPublicationContext','Publish-PackageZipAtomically')){
        $definition=$packageAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$true)
        if($null -eq $definition){throw "Package safety helper '$functionName' is missing."}
        Invoke-Expression $definition.Extent.Text
    }
    $script:PackageRootMarkerName='.mql5-chm-package-root';$script:PackageRootMarkerValue='mql5-chm-portable-package-v1'
    if($runningOnWindows){Assert-PackagePhysicalAliasRegressions -FixtureRoot $fixture}
    $protectedStageRejected=$false
    try{Assert-PackageOutputPlan -Root $developmentLayout -ReleaseRoot (Join-Path $developmentLayout 'scripts') -StageRoot (Join-Path $developmentLayout 'scripts\unsafe') -ZipPath (Join-Path $developmentLayout 'scripts\unsafe.zip') -ProtectedSources @((Join-Path $developmentLayout 'scripts'))|Out-Null}catch{$protectedStageRejected=$true}
    Assert-Fixture -Condition $protectedStageRejected -Message 'Package output inside a protected source subtree was accepted.'
    $futureBuildOutput=Join-Path $developmentLayout ('build\future-parent-' + [Guid]::NewGuid().ToString('N') + '\portable-candidate-release')
    $futureBuildPlan=Assert-PackageOutputPlan -Root $developmentLayout -ReleaseRoot $futureBuildOutput -StageRoot (Join-Path $futureBuildOutput 'package') -ZipPath (Join-Path $futureBuildOutput 'package.zip')
    Assert-Fixture -Condition ([string]$futureBuildPlan.ReleaseRoot -ceq [IO.Path]::GetFullPath($futureBuildOutput)) -Message 'Package output planning rejected the clean-checkout default beneath an absent build parent.'
    Assert-Fixture -Condition (-not (Test-Path -LiteralPath (Split-Path -Parent $futureBuildOutput))) -Message 'Package output planning created an ignored build parent before the maintenance mutex.'
    $ancestorStageRejected=$false
    try{Assert-PackageOutputPlan -Root $developmentLayout -ReleaseRoot $fixture -StageRoot $developmentLayout -ZipPath (Join-Path $fixture 'ancestor.zip')|Out-Null}catch{$ancestorStageRejected=$true}
    Assert-Fixture -Condition $ancestorStageRejected -Message 'Package output equal to/containing the project root was accepted.'
    if($runningOnWindows){
        $outputTarget=Join-Path $fixture 'output-target';New-Item -ItemType Directory -Path $outputTarget|Out-Null
        $outputJunction=Join-Path $fixture 'output-junction';New-Item -ItemType Junction -Path $outputJunction -Target $outputTarget|Out-Null
        $junctionOutputRejected=$false
        try{Assert-PackageOutputPlan -Root $developmentLayout -ReleaseRoot (Join-Path $outputJunction 'release') -StageRoot (Join-Path $outputJunction 'release\package') -ZipPath (Join-Path $outputJunction 'release\package.zip')|Out-Null}catch{$junctionOutputRejected=$true}
        Assert-Fixture -Condition $junctionOutputRejected -Message 'Package output through a reparse-point parent was accepted.'
        [IO.Directory]::Delete($outputJunction)
    }
    $ownedOutput=Join-Path $fixture 'owned-package-output';New-Item -ItemType Directory -Path $ownedOutput|Out-Null
    $ownedStage=Join-Path $ownedOutput 'package';New-Item -ItemType Directory -Path $ownedStage|Out-Null
    $sentinel=Join-Path $ownedStage 'user-sentinel.txt';[IO.File]::WriteAllText($sentinel,'preserve')
    $unownedStageRejected=$false;try{Reset-OwnedPackageStage -ReleaseRoot $ownedOutput -StageRoot $ownedStage|Out-Null}catch{$unownedStageRejected=$true}
    Assert-Fixture -Condition ($unownedStageRejected -and (Test-Path -LiteralPath $sentinel)) -Message 'Packaging replaced an existing unowned directory.'
    [IO.File]::WriteAllText((Join-Path $ownedStage '.mql5-chm-package-root'),"mql5-chm-portable-package-v1`n",(New-Object Text.UTF8Encoding($false)))
    Reset-OwnedPackageStage -ReleaseRoot $ownedOutput -StageRoot $ownedStage|Out-Null
    Assert-Fixture -Condition ((Test-Path -LiteralPath (Join-Path $ownedStage '.mql5-chm-package-root')) -and -not (Test-Path -LiteralPath $sentinel)) -Message 'Owned package-stage reset failed.'
    $ownedPayload=Join-Path $ownedStage 'payload.txt';[IO.File]::WriteAllText($ownedPayload,'owned-package-payload',(New-Object Text.UTF8Encoding($false)))
    $ownedChecksumLines=@(
        ((Get-FileHash -LiteralPath (Join-Path $ownedStage '.mql5-chm-package-root') -Algorithm SHA256).Hash.ToLowerInvariant()+' *.mql5-chm-package-root'),
        ((Get-FileHash -LiteralPath $ownedPayload -Algorithm SHA256).Hash.ToLowerInvariant()+' *payload.txt')
    )
    [IO.File]::WriteAllText((Join-Path $ownedStage 'checksums.sha256'),(($ownedChecksumLines -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
    $existingZip=Join-Path $ownedOutput 'package.zip';[IO.File]::WriteAllText($existingZip,'known-good');$existingZipHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $existingZip).Hash
    $zipFailureRejected=$false;try{Publish-PackageZipAtomically -ReleaseRoot $ownedOutput -StageRoot (Join-Path $ownedOutput 'missing-stage') -ZipPath $existingZip|Out-Null}catch{$zipFailureRejected=$true}
    Assert-Fixture -Condition ($zipFailureRejected -and (Get-FileHash -Algorithm SHA256 -LiteralPath $existingZip).Hash -ceq $existingZipHash) -Message 'Failed ZIP publication destroyed or changed the previous known-good ZIP.'
    Assert-Fixture -Condition (@(Get-ChildItem -LiteralPath $ownedOutput -Filter '.package-*.zip' -Force).Count -eq 0) -Message 'Failed atomic ZIP publication left temporary or backup debris.'
    $mismatchSource=Join-Path $ownedOutput 'wrong-package-root';New-Item -ItemType Directory -Path $mismatchSource|Out-Null
    [IO.File]::WriteAllText((Join-Path $mismatchSource 'unexpected.txt'),'unexpected',(New-Object Text.UTF8Encoding($false)))
    $script:packageMismatchSource=$mismatchSource
    $originalNewReproduciblePackageZip=(Get-Item Function:\New-ReproduciblePackageZip).ScriptBlock
    function New-ReproduciblePackageZip {
        [CmdletBinding()]
        param([string]$ReleaseRoot,[string]$StageRoot,[string]$ZipPath,[string]$SevenZipPath)
        Microsoft.PowerShell.Archive\Compress-Archive -LiteralPath $script:packageMismatchSource -DestinationPath $ZipPath -CompressionLevel Optimal -Force
        return $ZipPath
    }
    try {
        $mismatchedZipRejected=$false;try{Publish-PackageZipAtomically -ReleaseRoot $ownedOutput -StageRoot $ownedStage -ZipPath $existingZip|Out-Null}catch{$mismatchedZipRejected=$true}
    } finally {
        Set-Item Function:\New-ReproduciblePackageZip -Value $originalNewReproduciblePackageZip
        Remove-Variable -Name packageMismatchSource -Scope Script -ErrorAction SilentlyContinue
    }
    Assert-Fixture -Condition ($mismatchedZipRejected -and (Get-FileHash -Algorithm SHA256 -LiteralPath $existingZip).Hash -ceq $existingZipHash) -Message 'A ZIP with the wrong immutable tree displaced the previous known-good ZIP.'
    Assert-Fixture -Condition (@(Get-ChildItem -LiteralPath $ownedOutput -Filter '.package-*.zip' -Force).Count -eq 0) -Message 'Rejected mismatched ZIP publication left temporary or backup debris.'

    # A legacy ZIP without a sidecar can be upgraded, after which malformed or
    # mismatched pairs fail before publication changes either canonical file.
    $publishedPair=Publish-PackageZipAtomically -ReleaseRoot $ownedOutput -StageRoot $ownedStage -ZipPath $existingZip
    Assert-PackageZipSidecar -ZipPath $publishedPair.ZipPath -ManifestPath $publishedPair.ManifestPath|Out-Null
    $publishedHash=(Get-FileHash -LiteralPath $publishedPair.ZipPath -Algorithm SHA256).Hash
    $validSidecar=[IO.File]::ReadAllText($publishedPair.ManifestPath)
    $tamperedSidecar=$validSidecar -replace '"sha256"\s*:\s*"[0-9a-f]{64}"','"sha256": "0000000000000000000000000000000000000000000000000000000000000000"'
    [IO.File]::WriteAllText($publishedPair.ManifestPath,$tamperedSidecar,(New-Object Text.UTF8Encoding($false)))
    $malformedPairRejected=$false;try{Publish-PackageZipAtomically -ReleaseRoot $ownedOutput -StageRoot $ownedStage -ZipPath $existingZip|Out-Null}catch{$malformedPairRejected=$true}
    Assert-Fixture -Condition ($malformedPairRejected -and (Get-FileHash -LiteralPath $existingZip -Algorithm SHA256).Hash -ceq $publishedHash) -Message 'A mismatched existing ZIP/sidecar pair was silently overwritten.'
    [IO.File]::WriteAllText($publishedPair.ManifestPath,($validSidecar -replace '"file"','"File"'),(New-Object Text.UTF8Encoding($false)))
    $wrongCasePairRejected=$false;try{Publish-PackageZipAtomically -ReleaseRoot $ownedOutput -StageRoot $ownedStage -ZipPath $existingZip|Out-Null}catch{$wrongCasePairRejected=$true}
    Assert-Fixture -Condition ($wrongCasePairRejected -and (Get-FileHash -LiteralPath $existingZip -Algorithm SHA256).Hash -ceq $publishedHash) -Message 'A ZIP sidecar with non-canonical property casing was accepted or changed the ZIP.'
    [IO.File]::WriteAllText($publishedPair.ManifestPath,$validSidecar,(New-Object Text.UTF8Encoding($false)))

    # Simulate a process killed after creating an atomic JSON temporary but
    # before publication. Temp-only debris is disposable; backup-only debris
    # without a canonical target remains fail-closed.
    $killedWriteFixture = Join-Path $fixture 'killed-atomic-write'; New-Item -ItemType Directory -Path (Join-Path $killedWriteFixture 'data') -Force | Out-Null
    $killedTemporary = Join-Path $killedWriteFixture ('data\.json.tmp-' + [Guid]::NewGuid().ToString('N'))
    $killHelper = Join-Path $fixture 'kill-writer.ps1'
    [IO.File]::WriteAllText($killHelper, "param([string]`$Target)`n[IO.File]::WriteAllText(`$Target,'partial')`nStop-Process -Id `$PID -Force`n", (New-Object Text.UTF8Encoding($false)))
    $child = Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -ArgumentList @('-NoProfile','-File',$killHelper,$killedTemporary) -Wait -PassThru -WindowStyle Hidden
    Assert-Fixture -Condition ($child.ExitCode -ne 0 -and (Test-Path -LiteralPath $killedTemporary -PathType Leaf)) -Message 'Hard-interruption fixture did not leave the expected atomic temporary.'
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $killedWriteFixture
    Assert-Fixture -Condition (-not (Test-Path -LiteralPath $killedTemporary)) -Message 'Temp-only active-pointer debris was not reconciled.'
    $orphanedBackup = Join-Path $killedWriteFixture ('data\.json.backup-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($orphanedBackup,'backup')
    $orphanedBackupRejected=$false;try{Repair-InterruptedMaintenanceArtifacts -ProjectRoot $killedWriteFixture}catch{$orphanedBackupRejected=$true}
    Assert-Fixture -Condition $orphanedBackupRejected -Message 'Backup-only active-pointer debris was discarded without a canonical pointer.'
    Remove-Item -LiteralPath $orphanedBackup -Force
    Set-UpdateStatus -ProjectRoot $killedWriteFixture -Status 'up-to-date' -ActiveRevision ('7'*64) -ActiveCorpusRevision ('7'*64) -CandidateRevision ('7'*64) -CandidateCorpusRevision ('7'*64) -Message 'legacy ambiguity fixture'|Out-Null
    $ambiguousMaintenanceBackup=Join-Path $killedWriteFixture ('maintenance\.json.backup-'+[Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($ambiguousMaintenanceBackup,'could belong to the missing transition journal')
    $ambiguousMaintenanceRejected=$false;try{Repair-InterruptedMaintenanceArtifacts -ProjectRoot $killedWriteFixture}catch{$ambiguousMaintenanceRejected=$true}
    Assert-Fixture -Condition ($ambiguousMaintenanceRejected -and (Test-Path -LiteralPath $ambiguousMaintenanceBackup -PathType Leaf)) -Message 'Ambiguous legacy maintenance backup was deleted by validating an unrelated canonical JSON file.'
    Remove-Item -LiteralPath $ambiguousMaintenanceBackup -Force
    $pendingStageGuardPath=Join-Path $killedWriteFixture 'maintenance\revision-stage.json';[IO.File]::WriteAllText($pendingStageGuardPath,'pending fixture')
    $pendingStageGuardRejected=$false;try{Assert-NoPendingRevisionStageInstall -ProjectRoot $killedWriteFixture}catch{$pendingStageGuardRejected=$true}
    Assert-Fixture -Condition $pendingStageGuardRejected -Message 'Pending revision-stage presence did not block an unrelated operation.'
    Remove-Item -LiteralPath $pendingStageGuardPath -Force
    if ($runningOnWindows) {
        $junctionTarget = Join-Path $fixture 'junction-target'; New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        $junctionRoot = Join-Path $fixture 'junction-root'; New-Item -ItemType Junction -Path $junctionRoot -Target $junctionTarget | Out-Null
        $junctionRootRejected=$false;try{Assert-NoReparsePoint -Root $junctionRoot -Path $junctionRoot}catch{$junctionRootRejected=$true}
        Assert-Fixture -Condition $junctionRootRejected -Message 'A reparse point was accepted as the confinement root itself.'
        $junctionChild = Join-Path $junctionRoot 'ordinary-child'; New-Item -ItemType Directory -Path $junctionChild | Out-Null
        $junctionAncestorRejected=$false;try{Assert-NoReparsePoint -Root $junctionChild -Path $junctionChild}catch{$junctionAncestorRejected=$true}
        Assert-Fixture -Condition $junctionAncestorRejected -Message 'A confinement root beneath a reparse-point ancestor was accepted.'
        $nestedJunctionLockRejected=$false;$nestedJunctionLease=$null
        try{$nestedJunctionLease=Enter-ExclusiveFileLock -Path (Join-Path $junctionChild 'locks\.update.lock') -TimeoutSeconds 1}catch{$nestedJunctionLockRejected=$true}finally{if($null -ne $nestedJunctionLease){$nestedJunctionLease.Dispose()}}
        Assert-Fixture -Condition $nestedJunctionLockRejected -Message 'The shared lock primitive accepted a lock path beneath a reparse-point ancestor.'
        [IO.Directory]::Delete($junctionRoot)
        Assert-PhysicalLockAliasSerialization -FixtureRoot $fixture
        $externalRevisionTarget=Join-Path $fixture 'external-revision-target';New-Item -ItemType Directory -Path $externalRevisionTarget|Out-Null
        $externalTemporary=Join-Path $externalRevisionTarget ('.json.tmp-'+[Guid]::NewGuid().ToString('N'));[IO.File]::WriteAllText($externalTemporary,'external-sentinel')
        $recoveryRevisions=Join-Path $killedWriteFixture 'revisions';New-Item -ItemType Directory -Path $recoveryRevisions -Force|Out-Null
        $revisionJunction=Join-Path $recoveryRevisions ('a'*64);New-Item -ItemType Junction -Path $revisionJunction -Target $externalRevisionTarget|Out-Null
        $revisionJunctionRejected=$false;try{Repair-InterruptedMaintenanceArtifacts -ProjectRoot $killedWriteFixture}catch{$revisionJunctionRejected=$true}
        Assert-Fixture -Condition ($revisionJunctionRejected -and (Test-Path -LiteralPath $externalTemporary -PathType Leaf)) -Message 'Recovery traversed a revision junction or changed its external target.'
        [IO.Directory]::Delete($revisionJunction)
    }

    $pointer = Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $expected -PreviousRevision $null
    if ([string]$pointer.active_revision -cne $expected) { throw 'Atomic active pointer fixture failed.' }
    $status = Set-UpdateStatus -ProjectRoot $fixture -Status 'up-to-date' -ActiveRevision $expected -ActiveCorpusRevision $expected -CandidateRevision $expected -CandidateCorpusRevision $expected -Message 'fixture'
    if ([string]$status.status -ne 'up-to-date') { throw 'Atomic update status fixture failed.' }
    $transitionFixtureValue=[ordered]@{schema_version=2;operation='apply';from_revision=('8'*64);from_corpus_revision=('8'*64);to_revision=('9'*64);to_corpus_revision=('9'*64);started_at='2026-07-18T01:00:00Z'}
    Write-JsonAtomic -Path (Join-Path $fixture 'maintenance\revision-transition.json') -Value $transitionFixtureValue -ConfinementRoot $fixture
    $atomicTargets=@(
        [pscustomobject]@{Path=(Join-Path $fixture 'data\active.json');Value=[ordered]@{schema_version=2;active_revision=$expected;previous_revision=$null;activated_at='2026-07-18T01:01:00Z'}},
        [pscustomobject]@{Path=(Join-Path $fixture 'maintenance\update-status.json');Value=[ordered]@{schema_version=2;checked_at='2026-07-18T01:01:00Z';status='up-to-date';active_revision=$expected;active_corpus_revision=$expected;candidate_revision=$expected;candidate_corpus_revision=$expected;message='replacement'}},
        [pscustomobject]@{Path=(Join-Path $fixture 'maintenance\revision-transition.json');Value=[ordered]@{schema_version=2;operation='apply';from_revision=('8'*64);from_corpus_revision=('8'*64);to_revision=('9'*64);to_corpus_revision=('9'*64);started_at='2026-07-18T01:01:00Z'}}
    )
    $originalAtomicReplace=(Get-Item Function:\Invoke-AtomicFileReplace).ScriptBlock
    try{
        function Invoke-AtomicFileReplace{
            param([string]$ReplacementPath,[string]$DestinationPath,[string]$BackupPath)
            [IO.File]::Move($DestinationPath,$BackupPath)
            throw 'injected partial atomic replace failure'
        }
        foreach($atomicTarget in $atomicTargets){
            $before=[IO.File]::ReadAllBytes($atomicTarget.Path);$replaceRejected=$false
            try{Write-JsonAtomic -Path $atomicTarget.Path -Value $atomicTarget.Value -ConfinementRoot $fixture}catch{$replaceRejected=$true}
            Assert-Fixture -Condition ($replaceRejected -and [Linq.Enumerable]::SequenceEqual([byte[]]$before,[byte[]][IO.File]::ReadAllBytes($atomicTarget.Path))) -Message "Partial replacement did not restore the original canonical JSON: $($atomicTarget.Path)"
            $leaf=[IO.Path]::GetFileName($atomicTarget.Path);$debris=@(Get-ChildItem -LiteralPath (Split-Path -Parent $atomicTarget.Path) -Filter ".$leaf.replace.*" -Force)
            Assert-Fixture -Condition ($debris.Count -eq 0) -Message "Immediately restorable replacement left JSON debris: $($atomicTarget.Path)"
        }
    }finally{Set-Item Function:\Invoke-AtomicFileReplace -Value $originalAtomicReplace}
    Remove-Item -LiteralPath (Join-Path $fixture 'maintenance\revision-transition.json') -Force

    # A hard kill while bytes are still being written leaves only the strict
    # target-specific .writing name. It has never crossed the prepared-name
    # boundary and is reclaimed without changing a valid canonical file.
    foreach($writingCase in @(
        [pscustomobject]@{Target=(Join-Path $fixture 'data\active.json');Canonical=$true},
        [pscustomobject]@{Target=(Join-Path $fixture 'maintenance\update-status.json');Canonical=$true},
        [pscustomobject]@{Target=(Join-Path $fixture 'maintenance\revision-transition.json');Canonical=$false},
        [pscustomobject]@{Target=(Join-Path $fixture 'maintenance\revision-stage.json');Canonical=$false},
        [pscustomobject]@{Target=(Join-Path $fixture 'checksums.sha256');Canonical=$false}
    )){
        $leaf=[IO.Path]::GetFileName($writingCase.Target)
        $writing=Join-Path (Split-Path -Parent $writingCase.Target) (".$leaf.replace.writing-"+[Guid]::NewGuid().ToString('N'))
        $before=if($writingCase.Canonical){[IO.File]::ReadAllBytes($writingCase.Target)}else{$null}
        [IO.File]::WriteAllText($writing,'{"partial":',(New-Object Text.UTF8Encoding($false)))
        Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
        Assert-Fixture -Condition (-not (Test-Path -LiteralPath $writing)) -Message "Incomplete target-specific write was not reclaimed: $writing"
        if($writingCase.Canonical){
            Assert-Fixture -Condition ([Linq.Enumerable]::SequenceEqual([byte[]]$before,[byte[]][IO.File]::ReadAllBytes($writingCase.Target))) -Message "Incomplete write changed canonical bytes: $($writingCase.Target)"
        }else{
            Assert-Fixture -Condition (-not (Test-Path -LiteralPath $writingCase.Target)) -Message "Incomplete first write created a canonical target: $($writingCase.Target)"
        }
    }

    # A fully flushed legacy/prepared temp can still be promoted, while a
    # writing leaf that coexists with publication debris is ambiguous.
    $transitionTarget=Join-Path $fixture 'maintenance\revision-transition.json'
    $transitionLeaf=[IO.Path]::GetFileName($transitionTarget)
    $transitionToken=[Guid]::NewGuid().ToString('N')
    $transitionTemp=Join-Path (Split-Path -Parent $transitionTarget) (".$transitionLeaf.replace.tmp-$transitionToken")
    $transitionJson=($transitionFixtureValue|ConvertTo-Json -Depth 20)+[Environment]::NewLine
    [IO.File]::WriteAllText($transitionTemp,$transitionJson,(New-Object Text.UTF8Encoding($false)))
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-Fixture -Condition ((Test-Path -LiteralPath $transitionTarget -PathType Leaf) -and -not (Test-Path -LiteralPath $transitionTemp)) -Message 'A complete prepared transition temp was not promoted.'
    Remove-Item -LiteralPath $transitionTarget -Force
    $ambiguousToken=[Guid]::NewGuid().ToString('N')
    $ambiguousWriting=Join-Path (Split-Path -Parent $transitionTarget) (".$transitionLeaf.replace.writing-$ambiguousToken")
    $ambiguousTemp=Join-Path (Split-Path -Parent $transitionTarget) (".$transitionLeaf.replace.tmp-$ambiguousToken")
    [IO.File]::WriteAllText($ambiguousWriting,'partial',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($ambiguousTemp,$transitionJson,(New-Object Text.UTF8Encoding($false)))
    $ambiguousTargetWriteRejected=$false
    try{Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture}catch{$ambiguousTargetWriteRejected=$true}
    Assert-Fixture -Condition ($ambiguousTargetWriteRejected -and (Test-Path -LiteralPath $ambiguousWriting) -and (Test-Path -LiteralPath $ambiguousTemp)) -Message 'Writing/prepared coexistence was not retained fail-closed.'
    Remove-Item -LiteralPath $ambiguousWriting,$ambiguousTemp -Force

    $recoverablePointerBytes=[IO.File]::ReadAllBytes((Join-Path $fixture 'data\active.json'))
    try{
        function Invoke-AtomicFileReplace{
            param([string]$ReplacementPath,[string]$DestinationPath,[string]$BackupPath)
            [IO.File]::Move($DestinationPath,$BackupPath)
            New-Item -ItemType Directory -Path $DestinationPath -ErrorAction Stop|Out-Null
            throw 'injected retained atomic replace failure'
        }
        $retainedFailure=$false
        try{Write-JsonAtomic -Path (Join-Path $fixture 'data\active.json') -Value ([ordered]@{schema_version=2;active_revision=$expected;previous_revision=$null;activated_at='2026-07-18T01:02:00Z'}) -ConfinementRoot $fixture}catch{$retainedFailure=$true}
    }finally{Set-Item Function:\Invoke-AtomicFileReplace -Value $originalAtomicReplace}
    Assert-Fixture -Condition $retainedFailure -Message 'Injected non-restorable atomic replacement did not fail.'
    Remove-Item -LiteralPath (Join-Path $fixture 'data\active.json') -Force
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-Fixture -Condition ([Linq.Enumerable]::SequenceEqual([byte[]]$recoverablePointerBytes,[byte[]][IO.File]::ReadAllBytes((Join-Path $fixture 'data\active.json')))) -Message 'Target-specific recovery did not restore the retained active-pointer backup.'
    $invalid = [ordered]@{ schema_version=1; active_revision=$expected; previous_revision=$null; activated_at=[DateTime]::UtcNow.ToString('O'); unexpected=$true }
    Write-JsonAtomic -Path (Join-Path $fixture 'data\active.json') -Value $invalid -ConfinementRoot $fixture
    $rejected = $false
    try { Get-ActiveRevisionPointer -ProjectRoot $fixture | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Strict active pointer fixture accepted an extra property.' }

    $revisionA = ('a' * 64) -join ''; $revisionB = ('b' * 64) -join ''; $revisionC = ('c' * 64) -join ''
    Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $revisionA -PreviousRevision $null | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture "revisions\$revisionA") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture "revisions\$revisionB") -Force | Out-Null
    Write-JsonAtomic -Path (Join-Path $fixture "revisions\$revisionB\manifest.json") -Value ([ordered]@{
        schema_version=$script:ManifestSchemaVersion
        index_revision=$revisionB
        corpus_sha256=$revisionB
        database=[ordered]@{sha256=$revisionB}
    }) -ConfinementRoot $fixture
    $countsFixture = [ordered]@{ mql5=[ordered]@{base=1;candidate=2;delta=1} }
    $rankingsFixture = [ordered]@{ OnTick=[ordered]@{title='OnTick';source='mql5'} }
    $assetChangesFixture = [ordered]@{
        added_count=0;removed_count=0;changed_count=0;added_asset_ids=@();removed_asset_ids=@();changed_asset_ids=@()
        added_truncated=$false;removed_truncated=$false;changed_truncated=$false
        base_cataloged_count=1;candidate_cataloged_count=1;cataloged_delta=0
        base_exposed_count=1;candidate_exposed_count=1;exposed_delta=0;candidate_excluded_count=0
        base_occurrence_count=1;candidate_occurrence_count=1;occurrence_delta=0
        base_exposed_occurrence_count=1;candidate_exposed_occurrence_count=1;exposed_occurrence_delta=0
        candidate_total_bytes=4;unsupported_count=0;oversized_count=0;unresolved_count=0;unclassified_count=0;reduction_requires_review=$false
    }
    Set-StagedRevisionReport -ProjectRoot $fixture -Revision $revisionB -CorpusRevision $revisionB -BaseRevision $revisionA -BaseCorpusRevision $revisionA -SourceTopicCounts $countsFixture -Changes ([ordered]@{removed_count=0;changed_count=1}) -AssetChanges $assetChangesFixture -RequiredRankings $rankingsFixture | Out-Null
    Set-StagedRevisionReport -ProjectRoot $fixture -Revision $revisionB -CorpusRevision $revisionB -BaseRevision $revisionC -BaseCorpusRevision $revisionC -SourceTopicCounts $countsFixture -Changes ([ordered]@{removed_count=0;changed_count=2}) -AssetChanges $assetChangesFixture -RequiredRankings $rankingsFixture | Out-Null
    $refreshedReport = Read-JsonFile -Path (Join-Path $fixture "revisions\$revisionB\stage-report.json") -Context 'refreshed stage report fixture'
    Assert-Fixture -Condition ([string]$refreshedReport.base_index_revision -ceq $revisionC -and [int]$refreshedReport.changes.changed_count -eq 2) -Message 'Restaging did not refresh the existing report against the current base.'
    $stageReportPath=Join-Path $fixture "revisions\$revisionB\stage-report.json";$stageReportBytes=[IO.File]::ReadAllBytes($stageReportPath)
    $originalAtomicReplace=(Get-Item Function:\Invoke-AtomicFileReplace).ScriptBlock
    try{
        function Invoke-AtomicFileReplace{param([string]$ReplacementPath,[string]$DestinationPath,[string]$BackupPath);[IO.File]::Move($DestinationPath,$BackupPath);throw 'injected stage-report replace failure'}
        $stageReplaceRejected=$false
        try{Set-StagedRevisionReport -ProjectRoot $fixture -Revision $revisionB -CorpusRevision $revisionB -BaseRevision $revisionA -BaseCorpusRevision $revisionA -SourceTopicCounts $countsFixture -Changes ([ordered]@{removed_count=0;changed_count=3}) -AssetChanges $assetChangesFixture -RequiredRankings $rankingsFixture|Out-Null}catch{$stageReplaceRejected=$true}
    }finally{Set-Item Function:\Invoke-AtomicFileReplace -Value $originalAtomicReplace}
    Assert-Fixture -Condition ($stageReplaceRejected -and [Linq.Enumerable]::SequenceEqual([byte[]]$stageReportBytes,[byte[]][IO.File]::ReadAllBytes($stageReportPath))) -Message 'Partial stage-report replacement did not preserve the prior verified report.'
    $reportTemporary = Join-Path $fixture "revisions\$revisionB\.json.tmp-$([Guid]::NewGuid().ToString('N'))"
    $reportBackup = Join-Path $fixture "revisions\$revisionB\.json.backup-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($reportTemporary,'partial');[IO.File]::WriteAllText($reportBackup,'old')
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-Fixture -Condition (-not (Test-Path -LiteralPath $reportTemporary) -and -not (Test-Path -LiteralPath $reportBackup)) -Message 'Staged-report atomic debris was not reconciled against a valid canonical report.'
    $uncommittedReportTemporary = Join-Path $fixture "revisions\$revisionA\.json.tmp-$([Guid]::NewGuid().ToString('N'))"
    $secondUncommittedReportTemporary = Join-Path $fixture "revisions\$revisionA\.json.tmp-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($uncommittedReportTemporary,'partial')
    [IO.File]::WriteAllText($secondUncommittedReportTemporary,'also partial')
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-Fixture -Condition (-not (Test-Path -LiteralPath $uncommittedReportTemporary) -and -not (Test-Path -LiteralPath $secondUncommittedReportTemporary) -and -not (Test-Path -LiteralPath (Join-Path $fixture "revisions\$revisionA\stage-report.json"))) -Message 'Uncommitted temp-only staged-report debris was not discarded without publication.'
    Write-JsonAtomic -Path (Join-Path $fixture "revisions\$revisionA\manifest.json") -Value ([ordered]@{
        schema_version=$script:ManifestSchemaVersion
        index_revision=$revisionA
        corpus_sha256=$revisionA
        database=[ordered]@{sha256=$revisionA}
    }) -ConfinementRoot $fixture
    $orphanedReportBackup = Join-Path $fixture "revisions\$revisionA\.json.backup-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($orphanedReportBackup,'old')
    $orphanedReportRejected=$false;try{Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture}catch{$orphanedReportRejected=$true}
    Assert-Fixture -Condition ($orphanedReportRejected -and (Test-Path -LiteralPath $orphanedReportBackup -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $fixture "revisions\$revisionA\stage-report.json"))) -Message 'An invalid backup-only staged report was not rejected and retained for recovery.'
    Remove-Item -LiteralPath $orphanedReportBackup -Force

    $revisionInstallDebris = Join-Path $fixture ('revisions\.revision-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $revisionInstallDebris | Out-Null
    [IO.File]::WriteAllText((Join-Path $revisionInstallDebris 'partial.txt'),'partial')
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $fixture
    Assert-Fixture -Condition (-not (Test-Path -LiteralPath $revisionInstallDebris)) -Message 'Interrupted same-volume revision installation debris was not reconciled.'

    $revisionD = ('d' * 64)
    $candidateWork = Join-Path $fixture 'candidate-work'; $candidateSource = Join-Path $candidateWork 'revision'
    New-Item -ItemType Directory -Path $candidateSource -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $candidateSource 'fixture.txt'),'validated candidate')
    $installCandidate = [pscustomobject]@{ Revision=$revisionD; Root=$candidateSource; WorkRoot=$candidateWork }
    $originalAssertRevisionForInstall = (Get-Item Function:\Assert-Revision).ScriptBlock
    try {
        function Assert-Revision {
            param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$RevisionConfinementRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent)
            $validatedRoot = if ([string]::IsNullOrWhiteSpace($RevisionRoot)) { Join-Path $ProjectRoot "revisions\$Revision" } else { $RevisionRoot }
            [pscustomobject]@{ Root=$validatedRoot; Revision=$Revision; IndexRevision=$Revision; CorpusRevision=$Revision; ManifestSchemaVersion=3 }
        }
        $installedCandidate = Install-RevisionCandidate -ProjectRoot $fixture -Candidate $installCandidate
    } finally {
        Set-Item Function:\Assert-Revision -Value $originalAssertRevisionForInstall
    }
    Assert-Fixture -Condition ((Test-Path -LiteralPath $candidateSource -PathType Container) -and (Test-Path -LiteralPath (Join-Path $installedCandidate 'fixture.txt') -PathType Leaf)) -Message 'Revision installation moved or lost the external candidate instead of copying through a same-volume sibling.'
    Assert-Fixture -Condition (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'revisions') -Filter '.revision-install-*' -Force).Count -eq 0) -Message 'Successful revision installation left temporary sibling debris.'

    $raceRevision = ('1' * 64)
    $raceWork = Join-Path $fixture 'candidate-race-work'; $raceSource = Join-Path $raceWork 'revision'
    New-Item -ItemType Directory -Path $raceSource -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $raceSource 'fixture.txt'),'race candidate')
    $raceCandidate = [pscustomobject]@{ Revision=$raceRevision; Root=$raceSource; WorkRoot=$raceWork }
    $raceDestination = Join-Path $fixture "revisions\$raceRevision"
    $originalAssertRevisionForRace = (Get-Item Function:\Assert-Revision).ScriptBlock
    $script:injectRevisionInstallRace = $true
    try {
        function Assert-Revision {
            param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$RevisionConfinementRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent)
            if ($script:injectRevisionInstallRace -and -not [string]::IsNullOrWhiteSpace($RevisionRoot)) {
                New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "revisions\$Revision") -ErrorAction Stop | Out-Null
                $script:injectRevisionInstallRace = $false
            }
            $validatedRoot = if ([string]::IsNullOrWhiteSpace($RevisionRoot)) { Join-Path $ProjectRoot "revisions\$Revision" } else { $RevisionRoot }
            [pscustomobject]@{ Root=$validatedRoot; Revision=$Revision; IndexRevision=$Revision; CorpusRevision=$Revision; ManifestSchemaVersion=3 }
        }
        $lateDestinationRejected=$false;try{Install-RevisionCandidate -ProjectRoot $fixture -Candidate $raceCandidate|Out-Null}catch{$lateDestinationRejected=$true}
    } finally {
        Set-Item Function:\Assert-Revision -Value $originalAssertRevisionForRace
        Remove-Variable -Name injectRevisionInstallRace -Scope Script -ErrorAction SilentlyContinue
    }
    $absorbedInstallDebris = if (Test-Path -LiteralPath $raceDestination -PathType Container) { @(Get-ChildItem -LiteralPath $raceDestination -Filter '.revision-install-*' -Force).Count } else { 0 }
    if (Test-Path -LiteralPath $raceDestination -PathType Container) { Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path $raceDestination }
    Assert-Fixture -Condition ($lateDestinationRejected -and $absorbedInstallDebris -eq 0) -Message 'A late-created destination absorbed the temporary revision directory instead of failing the atomic rename.'

    $managedFixture = Join-Path $fixture 'managed-checksums'; New-Item -ItemType Directory -Path (Join-Path $managedFixture "revisions\$revisionA") -Force | Out-Null
    Set-ActiveRevisionPointer -ProjectRoot $managedFixture -ActiveRevision $revisionA -PreviousRevision $null | Out-Null
    $immutablePath = Join-Path $managedFixture 'immutable.txt'
    [IO.File]::WriteAllText($immutablePath, 'immutable', (New-Object Text.UTF8Encoding($false)))
    Set-UpdateStatus -ProjectRoot $managedFixture -Status 'up-to-date' -ActiveRevision $revisionA -ActiveCorpusRevision $revisionA -CandidateRevision $revisionA -CandidateCorpusRevision $revisionA -Message 'legacy status' | Out-Null
    $legacyTransition = [ordered]@{ schema_version=1; operation='apply'; from_revision=$revisionA; to_revision=$revisionB; started_at=[DateTime]::UtcNow.ToString('O') }
    Write-JsonAtomic -Path (Join-Path $managedFixture 'maintenance\revision-transition.json') -Value $legacyTransition -ConfinementRoot $managedFixture
    Write-JsonAtomic -Path (Join-Path $managedFixture 'maintenance\revision-stage.json') -Value ([ordered]@{schema_version=1;operation='rebuild';candidate_revision=$revisionB}) -ConfinementRoot $managedFixture
    $legacyEntries = @('data/active.json','immutable.txt','maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json')
    $legacyLines = foreach ($relative in $legacyEntries) {
        $path = Join-Path $managedFixture $relative.Replace('/','\')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()) *$relative"
    }
    [IO.File]::WriteAllLines((Join-Path $managedFixture 'checksums.sha256'), $legacyLines, (New-Object Text.UTF8Encoding($false)))
    Set-UpdateStatus -ProjectRoot $managedFixture -Status 'check-unavailable' -ActiveRevision $revisionA -ActiveCorpusRevision $revisionA -CandidateRevision $null -CandidateCorpusRevision $null -Message 'mutable status changed' | Out-Null
    $originalAssertPackageChecksums = (Get-Item Function:\Assert-PackageChecksums).ScriptBlock
    $originalGetValidatedRevisionChecksumFiles = (Get-Item Function:\Get-ValidatedRevisionChecksumFiles).ScriptBlock
    try {
        function Assert-PackageChecksums { param([string]$ProjectRoot) return $true }
        function Get-ValidatedRevisionChecksumFiles { param([string]$ProjectRoot,[string]$Revision,[switch]$AllowLegacy) return @() }
        Update-ManagedChecksumsIfPresent -ProjectRoot $managedFixture
        $unblessedPath = Join-Path $managedFixture 'unblessed.txt'; [IO.File]::WriteAllText($unblessedPath,'not in the original closure')
        $unblessedRejected = $false
        try { Update-ManagedChecksumsIfPresent -ProjectRoot $managedFixture -ChangedRelativePaths @('unblessed.txt') } catch { $unblessedRejected = $true }
        Assert-Fixture -Condition $unblessedRejected -Message 'Managed checksum writer blessed an arbitrary new file.'
        Remove-Item -LiteralPath $unblessedPath -Force
    } finally {
        Set-Item Function:\Assert-PackageChecksums -Value $originalAssertPackageChecksums
        Set-Item Function:\Get-ValidatedRevisionChecksumFiles -Value $originalGetValidatedRevisionChecksumFiles
    }
    $managedText = Get-Content -LiteralPath (Join-Path $managedFixture 'checksums.sha256') -Raw
    Assert-Fixture -Condition (-not $managedText.Contains('maintenance/update-status.json')) -Message 'Managed checksums retained mutable update status.'
    Assert-Fixture -Condition (-not $managedText.Contains('maintenance/revision-transition.json')) -Message 'Managed checksums retained the transition journal.'
    Assert-Fixture -Condition (-not $managedText.Contains('maintenance/revision-stage.json')) -Message 'Managed checksums retained the stage-install journal.'
    Assert-Fixture -Condition ($managedText.Contains('immutable.txt')) -Message 'Managed checksums lost an immutable entry.'
    Remove-Item -LiteralPath (Join-Path $managedFixture 'checksums.sha256') -Force
    Remove-Item -LiteralPath (Join-Path $managedFixture 'maintenance\revision-transition.json') -Force

    $originalAssertRevision = (Get-Item Function:\Assert-Revision).ScriptBlock
    $originalUpdateManagedChecksums = (Get-Item Function:\Update-ManagedChecksumsIfPresent).ScriptBlock
    $script:managedChecksumCalls = 0
    $script:failManagedChecksums = $false
    $script:lastAllowLegacyActive = $false
    try {
        function Assert-Revision {
            param([string]$ProjectRoot, [string]$Revision, [string]$RevisionRoot, [string]$IdentityMode='Auto', [switch]$RequireCurrent)
            $contract=if($Revision -ceq $revisionA){'mql5-chm-index-v3-assets-v1'}else{$script:IndexContract}
            return [pscustomobject]@{ Revision=$Revision; IndexRevision=$Revision; CorpusRevision=$Revision; ManifestSchemaVersion=3; Manifest=[pscustomobject]@{index_contract=$contract}; Root=(Join-Path $ProjectRoot "revisions\$Revision") }
        }
        function Update-ManagedChecksumsIfPresent {
            param([string]$ProjectRoot, [string[]]$ChangedRelativePaths=@(), [switch]$AllowLegacyActive)
            $script:managedChecksumCalls++
            $script:lastAllowLegacyActive=[bool]$AllowLegacyActive
            if ($script:failManagedChecksums) { throw 'injected managed-checksum failure' }
        }

        Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $revisionA -PreviousRevision $null | Out-Null
        $transition = Start-RevisionTransition -ProjectRoot $fixture -Operation apply -FromRevision $revisionA -ToRevision $revisionB
        $completed = Complete-RevisionTransition -ProjectRoot $fixture
        $afterApply = Get-ActiveRevisionPointer -ProjectRoot $fixture
        Assert-Fixture -Condition ([string]$afterApply.active_revision -ceq $revisionB -and [string]$afterApply.previous_revision -ceq $revisionA) -Message 'Apply transition did not switch to the target exactly once.'
        $applyTimestamp = [string]$afterApply.activated_at
        Complete-RevisionTransition -ProjectRoot $fixture | Out-Null
        $afterApplyRetry = Get-ActiveRevisionPointer -ProjectRoot $fixture
        Assert-Fixture -Condition ([string]$afterApplyRetry.active_revision -ceq $revisionB -and [string]$afterApplyRetry.previous_revision -ceq $revisionA) -Message 'Repeated apply completion changed revision direction.'
        Assert-Fixture -Condition ([string]$afterApplyRetry.activated_at -ceq $applyTimestamp) -Message 'Repeated apply completion rewrote the active pointer.'
        $applyStatus = Get-UpdateStatus -ProjectRoot $fixture
        Assert-Fixture -Condition ([string]$applyStatus.status -ceq 'up-to-date' -and [string]$applyStatus.candidate_revision -ceq $revisionB) -Message 'Apply transition wrote the wrong update status.'
        Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $completed

        Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $revisionB -PreviousRevision $revisionA | Out-Null
        Start-RevisionTransition -ProjectRoot $fixture -Operation rollback -FromRevision $revisionB -ToRevision $revisionA | Out-Null
        $rollback = Complete-RevisionTransition -ProjectRoot $fixture
        $afterRollback = Get-ActiveRevisionPointer -ProjectRoot $fixture
        $rollbackTimestamp = [string]$afterRollback.activated_at
        Assert-Fixture -Condition $script:lastAllowLegacyActive -Message 'Rollback to a supported noncurrent schema-3 contract did not enable compatibility checksum validation.'
        Complete-RevisionTransition -ProjectRoot $fixture | Out-Null
        $afterRollbackRetry = Get-ActiveRevisionPointer -ProjectRoot $fixture
        Assert-Fixture -Condition ([string]$afterRollbackRetry.active_revision -ceq $revisionA -and [string]$afterRollbackRetry.previous_revision -ceq $revisionB) -Message 'Repeated rollback completion toggled back to the replaced revision.'
        Assert-Fixture -Condition ([string]$afterRollbackRetry.activated_at -ceq $rollbackTimestamp) -Message 'Repeated rollback completion rewrote the active pointer.'
        $rollbackStatus = Get-UpdateStatus -ProjectRoot $fixture
        Assert-Fixture -Condition ([string]$rollbackStatus.status -ceq 'different-revision-available' -and [string]$rollbackStatus.candidate_revision -ceq $revisionB) -Message 'Rollback transition wrote the wrong update status.'
        Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $rollback

        Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $revisionA -PreviousRevision $null | Out-Null
        $interrupted = Start-RevisionTransition -ProjectRoot $fixture -Operation apply -FromRevision $revisionA -ToRevision $revisionB
        $script:failManagedChecksums = $true
        $failedAsInjected = $false
        try { Complete-RevisionTransition -ProjectRoot $fixture | Out-Null } catch { if ($_.Exception.Message -eq 'injected managed-checksum failure') { $failedAsInjected = $true } else { throw } }
        Assert-Fixture -Condition $failedAsInjected -Message 'Injected transition interruption did not fail at the checksum boundary.'
        Assert-Fixture -Condition ($null -ne (Get-RevisionTransition -ProjectRoot $fixture)) -Message 'Interrupted transition lost its recovery journal.'
        $switchedAt = [string](Get-ActiveRevisionPointer -ProjectRoot $fixture).activated_at
        $script:failManagedChecksums = $false
        $recovered = Complete-RevisionTransition -ProjectRoot $fixture
        Assert-Fixture -Condition ([string](Get-ActiveRevisionPointer -ProjectRoot $fixture).activated_at -ceq $switchedAt) -Message 'Recovery rewrote an already-switched pointer.'
        Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $recovered

        Set-ActiveRevisionPointer -ProjectRoot $fixture -ActiveRevision $revisionC -PreviousRevision $null | Out-Null
        $conflict = [ordered]@{ schema_version=2; operation='apply'; from_revision=$revisionA; from_corpus_revision=$revisionA; to_revision=$revisionB; to_corpus_revision=$revisionB; started_at=[DateTime]::UtcNow.ToString('O') }
        Write-JsonAtomic -Path (Join-Path $fixture 'maintenance\revision-transition.json') -Value $conflict -ConfinementRoot $fixture
        $callsBeforeConflict = $script:managedChecksumCalls
        $conflictRejected = $false
        try { Complete-RevisionTransition -ProjectRoot $fixture | Out-Null } catch { $conflictRejected = $true }
        Assert-Fixture -Condition $conflictRejected -Message 'A conflicting active pointer was accepted during recovery.'
        Assert-Fixture -Condition ($script:managedChecksumCalls -eq $callsBeforeConflict) -Message 'Conflicting recovery reached checksum mutation.'
        $actualConflict = Get-RevisionTransition -ProjectRoot $fixture
        $mismatched = [pscustomobject]@{ schema_version=2; operation='apply'; from_revision=$revisionA; from_corpus_revision=$revisionA; to_revision=$revisionC; to_corpus_revision=$revisionC; started_at=[string]$actualConflict.started_at }
        $clearRejected = $false
        try { Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $mismatched } catch { $clearRejected = $true }
        Assert-Fixture -Condition $clearRejected -Message 'Transition clear accepted mismatched expected content.'
        Clear-RevisionTransition -ProjectRoot $fixture -ExpectedTransition $actualConflict

        $malformed = [ordered]@{ schema_version=2; operation='apply'; from_revision=$revisionA; from_corpus_revision=$revisionA; to_revision=$revisionB; to_corpus_revision=$revisionB; started_at=[DateTime]::UtcNow.ToString('O'); unexpected=$true }
        Write-JsonAtomic -Path (Join-Path $fixture 'maintenance\revision-transition.json') -Value $malformed -ConfinementRoot $fixture
        $malformedRejected = $false
        try { Get-RevisionTransition -ProjectRoot $fixture | Out-Null } catch { $malformedRejected = $true }
        Assert-Fixture -Condition $malformedRejected -Message 'Strict transition validation accepted an extra property.'
        Remove-Item -LiteralPath (Join-Path $fixture 'maintenance\revision-transition.json') -Force
    } finally {
        Set-Item Function:\Assert-Revision -Value $originalAssertRevision
        Set-Item Function:\Update-ManagedChecksumsIfPresent -Value $originalUpdateManagedChecksums
        Remove-Variable -Name lastAllowLegacyActive -Scope Script -ErrorAction SilentlyContinue
    }

    # The manifest tree digest must describe the exact externally stored asset
    # closure. Tampering and unlisted files must fail without invoking Node.
    $assetProject = Join-Path $fixture 'asset-closure'; $assetRevisionRoot = Join-Path $assetProject ('revisions\' + ('d' * 64))
    foreach ($sourceName in @('mql5','mql5book','neuronetworksbook')) { New-Item -ItemType Directory -Path (Join-Path $assetRevisionRoot "assets\$sourceName") -Force | Out-Null }
    $assetName = ('1' * 64) + '.bin'; $assetPath = Join-Path $assetRevisionRoot "assets\mql5\$assetName"
    [IO.File]::WriteAllBytes($assetPath, [byte[]](1,2,3,4))
    $assetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
    $storageKey = "assets/mql5/$assetName"; $treeRecord = "$storageKey$([char]0)$assetHash$([char]0)4$([char]0)"
    $treeSha = [Security.Cryptography.SHA256]::Create(); try { $treeHash = ([BitConverter]::ToString($treeSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($treeRecord)))).Replace('-','').ToLowerInvariant() } finally { $treeSha.Dispose() }
    $emptySourceAssets = { param($count,$bytes) [pscustomobject]@{cataloged_count=$count;exposed_count=$count;excluded_count=0;occurrence_count=$count;exposed_occurrence_count=$count;total_bytes=$bytes} }
    $assetManifest = [pscustomobject]@{ assets=[pscustomobject]@{
        directory='assets';cataloged_count=1;exposed_count=1;excluded_count=0;occurrence_count=1;exposed_occurrence_count=1;total_bytes=4
        catalog_sha256=('2'*64);tree_sha256=$treeHash;policy_sha256=('3'*64)
        by_source=[pscustomobject]@{mql5=(& $emptySourceAssets 1 4);mql5book=(& $emptySourceAssets 0 0);neuronetworksbook=(& $emptySourceAssets 0 0)}
    } }
    Get-RevisionAssetClosure -ProjectRoot $assetProject -RevisionRoot $assetRevisionRoot -Manifest $assetManifest | Out-Null
    [IO.File]::WriteAllBytes($assetPath, [byte[]](9,9,9,9))
    $assetTamperRejected = $false; try { Get-RevisionAssetClosure -ProjectRoot $assetProject -RevisionRoot $assetRevisionRoot -Manifest $assetManifest | Out-Null } catch { $assetTamperRejected=$true }
    Assert-Fixture -Condition $assetTamperRejected -Message 'Asset closure accepted tampered bytes.'
    [IO.File]::WriteAllBytes($assetPath, [byte[]](1,2,3,4))
    $unlistedAsset = Join-Path $assetRevisionRoot 'assets\mql5\unlisted.txt'; [IO.File]::WriteAllText($unlistedAsset,'x')
    $unlistedRejected = $false; try { Get-RevisionAssetClosure -ProjectRoot $assetProject -RevisionRoot $assetRevisionRoot -Manifest $assetManifest | Out-Null } catch { $unlistedRejected=$true }
    Assert-Fixture -Condition $unlistedRejected -Message 'Asset closure accepted an unsafe unlisted file.'
    Remove-Item -LiteralPath $unlistedAsset -Force

    # Exercise the package checksum boundary independently: every active
    # revision file is required, and post-checksum asset tampering is refused.
    $packageFixture = Join-Path $fixture 'package-asset-tamper'; New-Item -ItemType Directory -Path $packageFixture | Out-Null
    $packageRevision = ('e' * 64); $packageRevisionNext = ('f' * 64); $packageRevisionRoot = Join-Path $packageFixture "revisions\$packageRevision"
    $packageFixtureFiles = @(
        @(Get-PortablePackageRequiredStaticPaths | ForEach-Object { $_.Replace('/', '\') })
        "revisions\$packageRevision\manifest.json", "revisions\$packageRevision\mql5-docs.sqlite", "revisions\$packageRevision\mql5.chm", "revisions\$packageRevision\mql5book.chm", "revisions\$packageRevision\neuronetworksbook.chm", "revisions\$packageRevision\corpus.lock.json", "revisions\$packageRevision\assets\mql5\$assetName"
    )
    foreach ($relative in $packageFixtureFiles | Where-Object { $_ -ne 'data\active.json' }) {
        $path=Join-Path $packageFixture $relative; $parent=Split-Path -Parent $path; if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        if ($relative -eq 'maintenance\.update.lock') { [IO.File]::WriteAllBytes($path, (New-Object byte[] 0)) }
        elseif ($relative -eq '.mql5-chm-package-root') { [IO.File]::WriteAllText($path,"mql5-chm-portable-package-v1`n",(New-Object Text.UTF8Encoding($false))) }
        elseif ($relative -eq 'package.json') { Copy-Item -LiteralPath (Join-Path $projectRoot 'package.json') -Destination $path }
        else { [IO.File]::WriteAllText($path,"fixture-$relative") }
    }
    Copy-Item -LiteralPath $packageRevisionRoot -Destination (Join-Path $packageFixture "revisions\$packageRevisionNext") -Recurse
    Set-ActiveRevisionPointer -ProjectRoot $packageFixture -ActiveRevision $packageRevision -PreviousRevision $null -SchemaVersion 2 | Out-Null
    $packageLines = Get-ChildItem -LiteralPath $packageFixture -Recurse -File | Where-Object Name -ne 'checksums.sha256' | ForEach-Object { $relative=$_.FullName.Substring($packageFixture.TrimEnd('\').Length).TrimStart('\'); "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()) *$relative" }
    [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'),$packageLines,(New-Object Text.UTF8Encoding($false)))
    $originalAssertRevisionForPackage = (Get-Item Function:\Assert-Revision).ScriptBlock
    try {
        function Assert-Revision { param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent) [pscustomobject]@{Root=(Join-Path $ProjectRoot "revisions\$Revision");ManifestSchemaVersion=3;CorpusRevision=$Revision;AssetClosure=[pscustomobject]@{Entries=@([pscustomobject]@{StorageKey="assets/mql5/$assetName"})}} }
        Assert-PackageChecksums -ProjectRoot $packageFixture | Out-Null
        $originalChecksumText = Get-Content -LiteralPath (Join-Path $packageFixture 'checksums.sha256') -Raw
        $originalAtomicReplace=(Get-Item Function:\Invoke-AtomicFileReplace).ScriptBlock
        try{
            function Invoke-AtomicFileReplace{param([string]$ReplacementPath,[string]$DestinationPath,[string]$BackupPath);[IO.File]::Move($DestinationPath,$BackupPath);throw 'injected checksum replace failure'}
            $checksumReplaceRejected=$false
            try{Update-ManagedChecksumsIfPresent -ProjectRoot $packageFixture|Out-Null}catch{$checksumReplaceRejected=$true}
        }finally{Set-Item Function:\Invoke-AtomicFileReplace -Value $originalAtomicReplace}
        Assert-Fixture -Condition ($checksumReplaceRejected -and (Get-Content -LiteralPath (Join-Path $packageFixture 'checksums.sha256') -Raw) -ceq $originalChecksumText) -Message 'Partial checksum replacement did not preserve the prior manifest.'
        Assert-Fixture -Condition (@(Get-ChildItem -LiteralPath $packageFixture -Filter '.checksums.sha256.replace.*' -Force).Count -eq 0) -Message 'Immediately restorable checksum replacement left debris.'
        $originalPointerBytes = [IO.File]::ReadAllBytes((Join-Path $packageFixture 'data\active.json'))
        $pendingTransition = [ordered]@{
            schema_version=2; operation='apply'; from_revision=$packageRevision; from_corpus_revision=$packageRevision
            to_revision=$packageRevisionNext; to_corpus_revision=$packageRevisionNext; started_at=[DateTime]::UtcNow.ToString('O')
        }
        Write-JsonAtomic -Path (Join-Path $packageFixture 'maintenance\revision-transition.json') -Value $pendingTransition -ConfinementRoot $packageFixture
        Set-ActiveRevisionPointer -ProjectRoot $packageFixture -ActiveRevision $packageRevisionNext -PreviousRevision $packageRevision -SchemaVersion 2 | Out-Null
        Assert-PackageChecksums -ProjectRoot $packageFixture -AllowPendingTransition | Out-Null
        $postSwitchPointerHash = (Get-FileHash -LiteralPath (Join-Path $packageFixture 'data\active.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $reconciledLines = @($originalChecksumText -split "`r?`n" | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '(?i)\*?data[/\\]active\.json$') { "$postSwitchPointerHash *data/active.json" } else { $_ }
        })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $reconciledLines, (New-Object Text.UTF8Encoding($false)))
        Assert-PackageChecksums -ProjectRoot $packageFixture -AllowPendingTransition | Out-Null
        Set-ActiveRevisionPointer -ProjectRoot $packageFixture -ActiveRevision $packageRevisionNext -PreviousRevision $null -SchemaVersion 2 | Out-Null
        $invalidPendingPointerRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture -AllowPendingTransition|Out-Null}catch{$invalidPendingPointerRejected=$true}
        Assert-Fixture -Condition $invalidPendingPointerRejected -Message 'Pending-transition checksum verification accepted a pointer that did not preserve from_revision as previous_revision.'
        [IO.File]::WriteAllBytes((Join-Path $packageFixture 'data\active.json'),$originalPointerBytes)
        [IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath (Join-Path $packageFixture 'maintenance\revision-transition.json') -Force

        $runtimeFixturePath = Join-Path $packageFixture 'runtime\node.exe'; $runtimeFixtureBytes = [IO.File]::ReadAllBytes($runtimeFixturePath)
        [IO.File]::AppendAllText($runtimeFixturePath,'tampered-before-native')
        $maintenanceIntegrityRejected=$false;try{Assert-MaintenancePackageIntegrity -ProjectRoot $packageFixture|Out-Null}catch{$maintenanceIntegrityRejected=$true}
        Assert-Fixture -Condition $maintenanceIntegrityRejected -Message 'Maintenance integrity preflight accepted a tampered bundled runtime.'
        [IO.File]::WriteAllBytes($runtimeFixturePath,$runtimeFixtureBytes)

        $commonFixturePath = Join-Path $packageFixture 'scripts\Common.ps1'; $commonFixtureBytes = [IO.File]::ReadAllBytes($commonFixturePath)
        Remove-Item -LiteralPath $commonFixturePath -Force
        $withoutCommon = @($originalChecksumText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)\*scripts[/\\]Common\.ps1$' })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $withoutCommon, (New-Object Text.UTF8Encoding($false)))
        $missingRequiredScriptRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$missingRequiredScriptRejected=$true}
        Assert-Fixture -Condition $missingRequiredScriptRejected -Message 'Package verification accepted a package missing an essential maintenance script and its checksum entry.'
        [IO.File]::WriteAllBytes($commonFixturePath,$commonFixtureBytes);[IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        $smokeFixturePath = Join-Path $packageFixture 'scripts\Smoke-Test-McpServer.mjs'; $smokeFixtureBytes = [IO.File]::ReadAllBytes($smokeFixturePath)
        Remove-Item -LiteralPath $smokeFixturePath -Force
        $withoutSmoke = @($originalChecksumText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)\*scripts[/\\]Smoke-Test-McpServer\.mjs$' })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $withoutSmoke, (New-Object Text.UTF8Encoding($false)))
        $missingSmokeRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$missingSmokeRejected=$true}
        Assert-Fixture -Condition $missingSmokeRejected -Message 'Package verification accepted a package missing the pre-registration MCP smoke helper and its checksum entry.'
        [IO.File]::WriteAllBytes($smokeFixturePath,$smokeFixtureBytes);[IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        $packageManifestFixturePath = Join-Path $packageFixture 'package.json'; $packageManifestFixtureBytes = [IO.File]::ReadAllBytes($packageManifestFixturePath)
        Remove-Item -LiteralPath $packageManifestFixturePath -Force
        $withoutPackageManifest = @($originalChecksumText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)\*package\.json$' })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $withoutPackageManifest, (New-Object Text.UTF8Encoding($false)))
        $missingPackageManifestRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$missingPackageManifestRejected=$true}
        Assert-Fixture -Condition $missingPackageManifestRejected -Message 'Package verification accepted a package missing the installer version manifest and its checksum entry.'
        [IO.File]::WriteAllBytes($packageManifestFixturePath,$packageManifestFixtureBytes);[IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        $sevenZipRuntimeFixturePath = Join-Path $packageFixture 'scripts\SevenZipRuntime.ps1'; $sevenZipRuntimeFixtureBytes = [IO.File]::ReadAllBytes($sevenZipRuntimeFixturePath)
        Remove-Item -LiteralPath $sevenZipRuntimeFixturePath -Force
        $withoutSevenZipRuntime = @($originalChecksumText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)\*scripts[/\\]SevenZipRuntime\.ps1$' })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $withoutSevenZipRuntime, (New-Object Text.UTF8Encoding($false)))
        $missingSevenZipRuntimeRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$missingSevenZipRuntimeRejected=$true}
        Assert-Fixture -Condition $missingSevenZipRuntimeRejected -Message 'Package verification accepted a package missing SevenZipRuntime.ps1 and its checksum entry.'
        [IO.File]::WriteAllBytes($sevenZipRuntimeFixturePath,$sevenZipRuntimeFixtureBytes);[IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        $toolFixturePath = Join-Path $packageFixture 'tools\7z.dll'; $toolFixtureBytes = [IO.File]::ReadAllBytes($toolFixturePath)
        Remove-Item -LiteralPath $toolFixturePath -Force
        $withoutTool = @($originalChecksumText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)\*tools[/\\]7z\.dll$' })
        [IO.File]::WriteAllLines((Join-Path $packageFixture 'checksums.sha256'), $withoutTool, (New-Object Text.UTF8Encoding($false)))
        $missingToolPairRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$missingToolPairRejected=$true}
        Assert-Fixture -Condition $missingToolPairRejected -Message 'Package verification accepted a missing/mixed 7-Zip tool pair.'
        [IO.File]::WriteAllBytes($toolFixturePath,$toolFixtureBytes);[IO.File]::WriteAllText((Join-Path $packageFixture 'checksums.sha256'),$originalChecksumText,(New-Object Text.UTF8Encoding($false)))
        $heldPackageLock = Enter-ExclusiveFileLock -Path (Join-Path $packageFixture 'maintenance\.update.lock') -IdentityRoot $packageFixture -TimeoutSeconds 5
        try { Assert-PackageChecksums -ProjectRoot $packageFixture | Out-Null } finally { $heldPackageLock.Dispose() }
        $packageLockPath = Join-Path $packageFixture 'maintenance\.update.lock'
        Remove-Item -LiteralPath $packageLockPath -Force
        $missingLockRejected = $false
        $missingLockLease = $null
        try {
            $missingLockLease = Enter-ExclusiveFileLock -Path $packageLockPath -IdentityRoot $packageFixture -TimeoutSeconds 5
            Assert-PackageChecksums -ProjectRoot $packageFixture | Out-Null
        } catch { $missingLockRejected = $true } finally { if ($null -ne $missingLockLease) { $missingLockLease.Dispose() } }
        Assert-Fixture -Condition $missingLockRejected -Message 'Package verification silently recreated or accepted a missing immutable lock marker.'
        [IO.File]::WriteAllBytes($packageLockPath, (New-Object byte[] 0))
        foreach ($omittedDevelopmentRelative in @('scripts\build.mjs','scripts\Test-Maintenance.ps1')) {
            $omittedDevelopmentPath = Join-Path $packageFixture $omittedDevelopmentRelative
            [IO.File]::WriteAllText($omittedDevelopmentPath, 'development-only and intentionally unchecksummed')
            $omittedDevelopmentRejected = $false
            try { Assert-PackageChecksums -ProjectRoot $packageFixture | Out-Null } catch { $omittedDevelopmentRejected = $true }
            Assert-Fixture -Condition $omittedDevelopmentRejected -Message "Package verification accepted omitted development file '$omittedDevelopmentRelative'."
            Remove-Item -LiteralPath $omittedDevelopmentPath -Force
        }
        $unlistedPackageFile = Join-Path $packageFixture 'unlisted-root-file.txt'; [IO.File]::WriteAllText($unlistedPackageFile,'not checksummed')
        $unlistedPackageRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$unlistedPackageRejected=$true}
        Assert-Fixture -Condition $unlistedPackageRejected -Message 'Package verification accepted an unlisted immutable root file.'
        Remove-Item -LiteralPath $unlistedPackageFile -Force
        New-Item -ItemType Directory -Path (Join-Path $packageFixture 'maintenance') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $packageFixture 'maintenance\update-status.json'),'mutable and intentionally unlisted')
        Assert-PackageChecksums -ProjectRoot $packageFixture | Out-Null
        [IO.File]::AppendAllText((Join-Path $packageRevisionRoot "assets\mql5\$assetName"),'tampered')
    $packageTamperRejected=$false;try{Assert-PackageChecksums -ProjectRoot $packageFixture|Out-Null}catch{$packageTamperRejected=$true}
    Assert-Fixture -Condition $packageTamperRejected -Message 'Package verification accepted a tampered asset.'
    } finally { Set-Item Function:\Assert-Revision -Value $originalAssertRevisionForPackage }

    # An existing Codex registration is equivalent only when no environment,
    # working-directory, or tool-filter override can change the four-tool server.
    function New-RegistrationFixture {
        param(
            [AllowNull()][object]$Env = $null,
            [AllowNull()][object]$EnvVars = @(),
            [AllowNull()][object]$Cwd = $null,
            [AllowNull()][object]$EnabledTools = $null,
            [AllowNull()][object]$DisabledTools = $null
        )
        return [pscustomobject]@{
            transport=[pscustomobject]@{type='stdio';command='C:\verified\node.exe';args=@('C:\verified\server.mjs');env=$Env;env_vars=$EnvVars;cwd=$Cwd}
            enabled_tools=$EnabledTools;disabled_tools=$DisabledTools
        }
    }
    $cleanRegistration=New-RegistrationFixture -Env ([pscustomobject]@{})
    Assert-Fixture -Condition (Test-Mql5ChmRegistrationMatches -Registration $cleanRegistration -NodePath 'C:\verified\node.exe' -ServerPath 'C:\verified\server.mjs') -Message 'A clean, exact Codex registration was rejected.'
    $registrationOverrides=@(
        (New-RegistrationFixture -Env ([pscustomobject]@{NODE_OPTIONS='--import=C:\evil.mjs'})),
        (New-RegistrationFixture -EnvVars @('NODE_OPTIONS')),
        (New-RegistrationFixture -Cwd 'C:\untrusted'),
        (New-RegistrationFixture -EnabledTools @('mql5_chm_search')),
        (New-RegistrationFixture -DisabledTools @('mql5_chm_read_image'))
    )
    foreach($registrationOverride in $registrationOverrides){
        Assert-Fixture -Condition (-not (Test-Mql5ChmRegistrationMatches -Registration $registrationOverride -NodePath 'C:\verified\node.exe' -ServerPath 'C:\verified\server.mjs')) -Message 'Codex registration equivalence accepted an environment, cwd, or tool-filter override.'
    }

    # A destination appearing after validation must never absorb the temporary
    # legacy copy as a child directory. Equivalent destinations may win; an
    # invalid late destination must fail closed and leave no absorbed debris.
    $legacyRaceCorpus=('2'*64);$legacyRaceIndex=('3'*64)
    $legacyRaceSource=Join-Path $fixture "revisions\$legacyRaceCorpus"
    $legacyRaceDestination=Join-Path $fixture "revisions\$legacyRaceIndex"
    New-Item -ItemType Directory -Path $legacyRaceSource -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRaceSource 'fixture.txt'),'legacy race source')
    $originalAssertRevisionForLegacyRace=(Get-Item Function:\Assert-Revision).ScriptBlock
    $script:injectLegacyRevisionRace=$true
    try{
        function Assert-Revision{
            param([string]$ProjectRoot,[string]$Revision,[string]$RevisionRoot,[string]$RevisionConfinementRoot,[string]$IdentityMode='Auto',[switch]$RequireCurrent)
            if($script:injectLegacyRevisionRace -and -not [string]::IsNullOrWhiteSpace($RevisionRoot)){
                New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "revisions\$legacyRaceIndex") -ErrorAction Stop|Out-Null
                $script:injectLegacyRevisionRace=$false
            }
            $validatedRoot=if([string]::IsNullOrWhiteSpace($RevisionRoot)){Join-Path $ProjectRoot "revisions\$Revision"}else{$RevisionRoot}
            if($Revision -ceq $legacyRaceIndex -and [string]::IsNullOrWhiteSpace($RevisionRoot) -and -not(Test-Path -LiteralPath (Join-Path $validatedRoot 'fixture.txt') -PathType Leaf)){throw 'injected invalid late legacy destination'}
            [pscustomobject]@{Root=$validatedRoot;IndexRevision=$legacyRaceIndex;CorpusRevision=$legacyRaceCorpus;ManifestSchemaVersion=2}
        }
        $legacyLateDestinationRejected=$false
        try{Install-LegacyRevisionIndexIdentity -ProjectRoot $fixture -LegacyCorpusRevision $legacyRaceCorpus|Out-Null}catch{$legacyLateDestinationRejected=$true}
    }finally{
        Set-Item Function:\Assert-Revision -Value $originalAssertRevisionForLegacyRace
        Remove-Variable -Name injectLegacyRevisionRace -Scope Script -ErrorAction SilentlyContinue
    }
    $absorbedLegacyDebris=if(Test-Path -LiteralPath $legacyRaceDestination -PathType Container){@(Get-ChildItem -LiteralPath $legacyRaceDestination -Filter '.legacy-index-*' -Force).Count}else{0}
    Assert-Fixture -Condition ($legacyLateDestinationRejected -and $absorbedLegacyDebris -eq 0) -Message 'A late-created destination absorbed the temporary legacy revision instead of failing the atomic rename.'
    if(Test-Path -LiteralPath $legacyRaceDestination -PathType Container){Remove-SafeDirectory -ConfinementRoot (Join-Path $fixture 'revisions') -Path $legacyRaceDestination}

    function New-LegacyRevisionFixture {
        param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Seed)
        $sourceHashes=[pscustomobject]@{};$sourceObjects=[ordered]@{};$lockSources=@();$timestamp='2026-07-18T00:00:00Z'
        $holding=Join-Path $Root ('.holding-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $holding -Force|Out-Null
        foreach($definition in Get-Mql5CorpusDefinition){
            $chmPath=Join-Path $holding $definition.FileName;[IO.File]::WriteAllText($chmPath,"$Seed-$($definition.Id)")
            $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $chmPath).Hash.ToLowerInvariant();$sourceHashes|Add-Member -NotePropertyName $definition.Id -NotePropertyValue $hash
            $sourceObjects[$definition.Id]=[ordered]@{filename=$definition.FileName;sha256=$hash;bytes=(Get-Item $chmPath).Length;http_last_modified=$null;http_etag=$null;retrieved_at=$timestamp;topic_count=$definition.TopicCount;section_count=$definition.TopicCount}
            $lockSources += [ordered]@{id=$definition.Id;filename=$definition.FileName;sha256=$hash;expected_topics=$definition.TopicCount;bytes=(Get-Item $chmPath).Length;http_last_modified=$null;http_etag=$null;retrieved_at=$timestamp}
        }
        $corpus=Get-CorpusRevision -SourceHashes $sourceHashes;$revisionRoot=Join-Path $Root "revisions\$corpus";New-Item -ItemType Directory -Path $revisionRoot -Force|Out-Null
        foreach($definition in Get-Mql5CorpusDefinition){Move-Item -LiteralPath (Join-Path $holding $definition.FileName) -Destination (Join-Path $revisionRoot $definition.FileName)};Remove-Item -LiteralPath $holding -Force
        $databasePath=Join-Path $revisionRoot 'mql5-docs.sqlite';[IO.File]::WriteAllText($databasePath,"database-$Seed");$databaseHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $databasePath).Hash.ToLowerInvariant()
        $manifest=[ordered]@{schema_version=2;database=[ordered]@{filename='mql5-docs.sqlite';sha256=$databaseHash;bytes=(Get-Item $databasePath).Length};sources=$sourceObjects;total_topic_count=4827;total_section_count=4827;topic_link_count=0;resolved_topic_link_count=0;unresolved_topic_link_count=0;corpus_sha256=$corpus;indexed_at=$timestamp;build_timestamp=$timestamp}
        Write-JsonAtomic -Path (Join-Path $revisionRoot 'manifest.json') -Value $manifest -ConfinementRoot $revisionRoot
        Write-JsonAtomic -Path (Join-Path $revisionRoot 'corpus.lock.json') -Value ([ordered]@{schema_version='1.1';sources=$lockSources;expected_total_topics=4827}) -ConfinementRoot $revisionRoot
        return [pscustomobject]@{Corpus=$corpus;Index=$databaseHash;Root=$revisionRoot}
    }

    function Write-LegacyStageReportFixture {
        param([Parameter(Mandatory)][object]$Revision,[Parameter(Mandatory)][string]$BaseRevision)
        $sourceCounts=[ordered]@{}
        foreach($definition in Get-Mql5CorpusDefinition){$sourceCounts[$definition.Id]=[ordered]@{base=$definition.TopicCount;candidate=$definition.TopicCount;delta=0}}
        $rankings=[ordered]@{}
        foreach($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')){$rankings[$query]=[ordered]@{title=$query;source='mql5'}}
        $report=[ordered]@{
            schema_version=1;revision=[string]$Revision.Corpus;base_revision=$BaseRevision;staged_at='2026-07-18T00:20:00Z';validation_passed=$true
            source_topic_counts=$sourceCounts
            changes=[ordered]@{added_count=0;removed_count=0;changed_count=0;added_topic_ids=@();removed_topic_ids=@();changed_topic_ids=@();added_truncated=$false;removed_truncated=$false;changed_truncated=$false}
            required_rankings=$rankings
        }
        Write-JsonAtomic -Path (Join-Path $Revision.Root 'stage-report.json') -Value $report -ConfinementRoot $Revision.Root
    }

    $freshMigrationFixture=Join-Path $fixture 'legacy-migration-before-copy';New-Item -ItemType Directory -Path $freshMigrationFixture|Out-Null
    $freshActive=New-LegacyRevisionFixture -Root $freshMigrationFixture -Seed 'fresh-active';$freshPrevious=New-LegacyRevisionFixture -Root $freshMigrationFixture -Seed 'fresh-previous'
    Set-ActiveRevisionPointer -ProjectRoot $freshMigrationFixture -ActiveRevision $freshActive.Corpus -PreviousRevision $freshPrevious.Corpus -SchemaVersion 1 -ActivatedAt '2026-07-18T00:30:00Z'|Out-Null
    $freshMigrated=Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $freshMigrationFixture
    Assert-Fixture -Condition ([string]$freshMigrated.active_revision -ceq $freshActive.Index -and [string]$freshMigrated.previous_revision -ceq $freshPrevious.Index) -Message 'Migration interrupted before either legacy copy did not recover both selections.'
    Assert-Fixture -Condition ((Test-Path -LiteralPath (Join-Path $freshMigrationFixture "revisions\$($freshActive.Index)")) -and (Test-Path -LiteralPath (Join-Path $freshMigrationFixture "revisions\$($freshPrevious.Index)"))) -Message 'Fresh migration did not install both additive index-keyed copies.'
    Assert-Fixture -Condition ((Test-Path -LiteralPath $freshActive.Root) -and (Test-Path -LiteralPath $freshPrevious.Root)) -Message 'Fresh migration modified or removed a corpus-keyed legacy revision.'

    $portableMigrationFixture=Join-Path $fixture 'legacy-portable-migration-checksum-recovery';New-Item -ItemType Directory -Path $portableMigrationFixture|Out-Null
    $portableLegacyActive=New-LegacyRevisionFixture -Root $portableMigrationFixture -Seed 'portable-active'
    $portableLegacyPrevious=New-LegacyRevisionFixture -Root $portableMigrationFixture -Seed 'portable-previous'
    Write-LegacyStageReportFixture -Revision $portableLegacyActive -BaseRevision $portableLegacyPrevious.Corpus
    $legacyGenericTemporary=Join-Path $portableLegacyActive.Root ('.json.tmp-'+[Guid]::NewGuid().ToString('N'));[IO.File]::WriteAllText($legacyGenericTemporary,'obsolete temporary')
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $portableMigrationFixture
    Assert-Fixture -Condition (-not(Test-Path -LiteralPath $legacyGenericTemporary)) -Message 'A valid legacy stage report could not reconcile old generic temporary debris.'
    $legacyReportPath=Join-Path $portableLegacyActive.Root 'stage-report.json'
    $legacyGenericBackup=Join-Path $portableLegacyActive.Root ('.json.backup-'+[Guid]::NewGuid().ToString('N'));[IO.File]::Move($legacyReportPath,$legacyGenericBackup)
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $portableMigrationFixture
    Assert-Fixture -Condition ((Test-Path -LiteralPath $legacyReportPath -PathType Leaf) -and -not(Test-Path -LiteralPath $legacyGenericBackup)) -Message 'A legacy stage-report backup was not restored through the manifest-bound validator.'
    Get-ValidatedRevisionChecksumFiles -ProjectRoot $portableMigrationFixture -Revision $portableLegacyActive.Corpus -IdentityMode Corpus -AllowLegacy | Out-Null
    $legacyReport=Read-JsonFile -Path $legacyReportPath -Context 'legacy report fixture';$legacyReport.validation_passed='true'
    Write-JsonAtomic -Path $legacyReportPath -Value $legacyReport -ConfinementRoot $portableLegacyActive.Root
    $invalidLegacyReportRejected=$false;try{Get-ValidatedRevisionChecksumFiles -ProjectRoot $portableMigrationFixture -Revision $portableLegacyActive.Corpus -IdentityMode Corpus -AllowLegacy|Out-Null}catch{$invalidLegacyReportRejected=$true}
    Assert-Fixture -Condition $invalidLegacyReportRejected -Message 'Legacy revision validation accepted a self-described stage report with a non-Boolean approval flag.'
    Write-LegacyStageReportFixture -Revision $portableLegacyActive -BaseRevision $portableLegacyPrevious.Corpus
    Set-ActiveRevisionPointer -ProjectRoot $portableMigrationFixture -ActiveRevision $portableLegacyActive.Corpus -PreviousRevision $portableLegacyPrevious.Corpus -SchemaVersion 1 -ActivatedAt '2026-07-18T00:45:00Z'|Out-Null
    foreach($relative in $packageFixtureFiles|Where-Object{$_ -ne 'data\active.json' -and $_ -notlike 'revisions\*'}){
        $path=Join-Path $portableMigrationFixture $relative
        if(Test-Path -LiteralPath $path){continue}
        $parent=Split-Path -Parent $path;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        if($relative -eq 'maintenance\.update.lock'){[IO.File]::WriteAllBytes($path,(New-Object byte[] 0))}
        elseif($relative -eq '.mql5-chm-package-root'){[IO.File]::WriteAllText($path,"mql5-chm-portable-package-v1`n",(New-Object Text.UTF8Encoding($false)))}
        elseif($relative -eq 'package.json'){Copy-Item -LiteralPath (Join-Path $projectRoot 'package.json') -Destination $path}
        else{[IO.File]::WriteAllText($path,"fixture-$relative")}
    }
    $portableMigrationLines=Get-ChildItem -LiteralPath $portableMigrationFixture -Recurse -File|Where-Object FullName -ne (Join-Path $portableMigrationFixture 'checksums.sha256')|ForEach-Object{
        $relative=$_.FullName.Substring($portableMigrationFixture.TrimEnd('\').Length).TrimStart('\')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()) *$relative"
    }
    [IO.File]::WriteAllLines((Join-Path $portableMigrationFixture 'checksums.sha256'),$portableMigrationLines,(New-Object Text.UTF8Encoding($false)))
    $portablePreMigrationChecksums=Get-Content -LiteralPath (Join-Path $portableMigrationFixture 'checksums.sha256') -Raw
    Assert-PackageChecksums -ProjectRoot $portableMigrationFixture -AllowLegacyActive -AllowLegacyPointer|Out-Null

    Install-LegacyRevisionIndexIdentity -ProjectRoot $portableMigrationFixture -LegacyCorpusRevision $portableLegacyActive.Corpus|Out-Null
    $singleCopyNormallyRejected=$false;try{Assert-PackageChecksums -ProjectRoot $portableMigrationFixture -AllowLegacyActive -AllowLegacyPointer|Out-Null}catch{$singleCopyNormallyRejected=$true}
    Assert-Fixture -Condition $singleCopyNormallyRejected -Message 'Normal package verification accepted an unjournaled extra legacy index copy.'
    Assert-PackageChecksums -ProjectRoot $portableMigrationFixture -AllowLegacyActive -AllowLegacyPointer -AllowInterruptedLegacyIndexCopies|Out-Null
    Install-LegacyRevisionIndexIdentity -ProjectRoot $portableMigrationFixture -LegacyCorpusRevision $portableLegacyPrevious.Corpus|Out-Null
    Assert-PackageChecksums -ProjectRoot $portableMigrationFixture -AllowLegacyActive -AllowLegacyPointer -AllowInterruptedLegacyIndexCopies|Out-Null
    Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $portableMigrationFixture|Out-Null
    $portableNewline=[Environment]::NewLine
    $portableCoreJson='{'+$portableNewline+
        '  "schema_version": 1,'+$portableNewline+
        '  "active_revision": "'+$portableLegacyActive.Corpus+'",'+$portableNewline+
        '  "previous_revision": "'+$portableLegacyPrevious.Corpus+'",'+$portableNewline+
        '  "activated_at": "2026-07-18T00:45:00Z"'+$portableNewline+
        '}'+$portableNewline
    $portableDesktopJson='{'+$portableNewline+
        '    "schema_version":  1,'+$portableNewline+
        '    "active_revision":  "'+$portableLegacyActive.Corpus+'",'+$portableNewline+
        '    "previous_revision":  "'+$portableLegacyPrevious.Corpus+'",'+$portableNewline+
        '    "activated_at":  "2026-07-18T00:45:00Z"'+$portableNewline+
        '}'+$portableNewline
    $pointerSha=[Security.Cryptography.SHA256]::Create()
    try{
        $portableCoreHash=([BitConverter]::ToString($pointerSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($portableCoreJson)))).Replace('-','').ToLowerInvariant();$pointerSha.Initialize()
        $portableDesktopHash=([BitConverter]::ToString($pointerSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($portableDesktopJson)))).Replace('-','').ToLowerInvariant()
    }finally{$pointerSha.Dispose()}
    Assert-Fixture -Condition (Test-InterruptedLegacyPointerChecksumMigration -ProjectRoot $portableMigrationFixture -ExpectedLegacyPointerSha256 $portableCoreHash) -Message 'Cross-host recovery rejected the exact PowerShell 7 schema-1 pointer bytes.'
    Assert-Fixture -Condition (Test-InterruptedLegacyPointerChecksumMigration -ProjectRoot $portableMigrationFixture -ExpectedLegacyPointerSha256 $portableDesktopHash) -Message 'Cross-host recovery rejected the exact Windows PowerShell 5.1 schema-1 pointer bytes.'
    Assert-Fixture -Condition (-not(Test-InterruptedLegacyPointerChecksumMigration -ProjectRoot $portableMigrationFixture -ExpectedLegacyPointerSha256 ('0'*64))) -Message 'Legacy pointer recovery accepted an unproven checksum.'
    [IO.File]::WriteAllText((Join-Path $portableMigrationFixture 'checksums.sha256'),$portablePreMigrationChecksums,(New-Object Text.UTF8Encoding($false)))
    Assert-MaintenancePackageIntegrity -ProjectRoot $portableMigrationFixture|Out-Null
    Assert-PackageChecksums -ProjectRoot $portableMigrationFixture -AllowLegacyActive|Out-Null

    $legacyTransitionFixture=Join-Path $fixture 'legacy-portable-transition-recovery';New-Item -ItemType Directory -Path $legacyTransitionFixture|Out-Null
    $legacyTransitionFrom=New-LegacyRevisionFixture -Root $legacyTransitionFixture -Seed 'transition-from'
    $legacyTransitionTo=New-LegacyRevisionFixture -Root $legacyTransitionFixture -Seed 'transition-to'
    Write-LegacyStageReportFixture -Revision $legacyTransitionTo -BaseRevision $legacyTransitionFrom.Corpus
    Set-ActiveRevisionPointer -ProjectRoot $legacyTransitionFixture -ActiveRevision $legacyTransitionFrom.Corpus -PreviousRevision $legacyTransitionTo.Corpus -SchemaVersion 1 -ActivatedAt '2026-07-18T00:55:00Z'|Out-Null
    foreach($relative in $packageFixtureFiles|Where-Object{$_ -ne 'data\active.json' -and $_ -notlike 'revisions\*'}){
        $path=Join-Path $legacyTransitionFixture $relative
        if(Test-Path -LiteralPath $path){continue}
        $parent=Split-Path -Parent $path;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        if($relative -eq 'maintenance\.update.lock'){[IO.File]::WriteAllBytes($path,(New-Object byte[] 0))}
        elseif($relative -eq '.mql5-chm-package-root'){[IO.File]::WriteAllText($path,"mql5-chm-portable-package-v1`n",(New-Object Text.UTF8Encoding($false)))}
        elseif($relative -eq 'package.json'){Copy-Item -LiteralPath (Join-Path $projectRoot 'package.json') -Destination $path}
        else{[IO.File]::WriteAllText($path,"fixture-$relative")}
    }
    $legacyTransition=[ordered]@{schema_version=1;operation='rollback';from_revision=$legacyTransitionFrom.Corpus;to_revision=$legacyTransitionTo.Corpus;started_at='2026-07-18T00:56:00Z'}
    Write-JsonAtomic -Path (Join-Path $legacyTransitionFixture 'maintenance\revision-transition.json') -Value $legacyTransition -ConfinementRoot $legacyTransitionFixture
    $legacyTransitionLines=Get-ChildItem -LiteralPath $legacyTransitionFixture -Recurse -File|Where-Object{
        $_.FullName -ne (Join-Path $legacyTransitionFixture 'checksums.sha256') -and $_.FullName -ne (Join-Path $legacyTransitionFixture 'maintenance\revision-transition.json')
    }|ForEach-Object{
        $relative=$_.FullName.Substring($legacyTransitionFixture.TrimEnd('\').Length).TrimStart('\')
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()) *$relative"
    }
    [IO.File]::WriteAllLines((Join-Path $legacyTransitionFixture 'checksums.sha256'),$legacyTransitionLines,(New-Object Text.UTF8Encoding($false)))
    Assert-MaintenancePackageIntegrity -ProjectRoot $legacyTransitionFixture -AllowPendingTransition|Out-Null
    Set-ActiveRevisionPointer -ProjectRoot $legacyTransitionFixture -ActiveRevision $legacyTransitionTo.Corpus -PreviousRevision $legacyTransitionFrom.Corpus -SchemaVersion 1 -ActivatedAt '2026-07-18T00:57:00Z'|Out-Null
    Assert-MaintenancePackageIntegrity -ProjectRoot $legacyTransitionFixture -AllowPendingTransition|Out-Null
    Install-LegacyRevisionIndexIdentity -ProjectRoot $legacyTransitionFixture -LegacyCorpusRevision $legacyTransitionTo.Corpus|Out-Null
    Install-LegacyRevisionIndexIdentity -ProjectRoot $legacyTransitionFixture -LegacyCorpusRevision $legacyTransitionFrom.Corpus|Out-Null
    Set-ActiveRevisionPointer -ProjectRoot $legacyTransitionFixture -ActiveRevision $legacyTransitionTo.Index -PreviousRevision $legacyTransitionFrom.Index -SchemaVersion 2 -ActivatedAt '2026-07-18T00:57:00Z'|Out-Null
    Assert-MaintenancePackageIntegrity -ProjectRoot $legacyTransitionFixture -AllowPendingTransition|Out-Null
    $completedLegacyTransition=Complete-RevisionTransition -ProjectRoot $legacyTransitionFixture
    Complete-RevisionTransition -ProjectRoot $legacyTransitionFixture|Out-Null
    Assert-PackageChecksums -ProjectRoot $legacyTransitionFixture -AllowLegacyActive -AllowPendingTransition|Out-Null
    Clear-RevisionTransition -ProjectRoot $legacyTransitionFixture -ExpectedTransition $completedLegacyTransition
    $legacyTransitionPointer=Get-ActiveRevisionPointer -ProjectRoot $legacyTransitionFixture
    Assert-Fixture -Condition ([int]$legacyTransitionPointer.schema_version -eq 2 -and [string]$legacyTransitionPointer.active_revision -ceq $legacyTransitionTo.Index -and [string]$legacyTransitionPointer.previous_revision -ceq $legacyTransitionFrom.Index) -Message 'Legacy transition recovery did not migrate the recovered selection to index identity.'
    Assert-PackageChecksums -ProjectRoot $legacyTransitionFixture -AllowLegacyActive|Out-Null

    $migrationFixture=Join-Path $fixture 'legacy-migration';New-Item -ItemType Directory -Path $migrationFixture|Out-Null
    $legacyActive=New-LegacyRevisionFixture -Root $migrationFixture -Seed 'active';$legacyPrevious=New-LegacyRevisionFixture -Root $migrationFixture -Seed 'previous'
    $legacyActivatedAt='2026-07-18T01:02:03Z';Set-ActiveRevisionPointer -ProjectRoot $migrationFixture -ActiveRevision $legacyActive.Corpus -PreviousRevision $legacyPrevious.Corpus -SchemaVersion 1 -ActivatedAt $legacyActivatedAt|Out-Null
    Install-LegacyRevisionIndexIdentity -ProjectRoot $migrationFixture -LegacyCorpusRevision $legacyActive.Corpus|Out-Null
    Assert-Fixture -Condition (Test-Path -LiteralPath (Join-Path $migrationFixture "revisions\$($legacyActive.Index)")) -Message 'Interrupted migration fixture did not install the additive index-keyed copy.'
    $migrated=Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $migrationFixture
    Assert-Fixture -Condition ([int]$migrated.schema_version -eq 2 -and [string]$migrated.active_revision -ceq $legacyActive.Index -and [string]$migrated.previous_revision -ceq $legacyPrevious.Index -and [string]$migrated.activated_at -ceq $legacyActivatedAt) -Message 'Legacy active/previous pointer migration failed.'
    Assert-Fixture -Condition (Test-Path -LiteralPath $legacyActive.Root) -Message 'Legacy migration removed the corpus-keyed rollback source.'
    $retryTimestamp=[string](Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $migrationFixture).activated_at
    Assert-Fixture -Condition ($retryTimestamp -ceq $legacyActivatedAt) -Message 'Retrying pointer migration rewrote activated_at.'
    Start-RevisionTransition -ProjectRoot $migrationFixture -Operation rollback -FromRevision $legacyActive.Index -ToRevision $legacyPrevious.Index | Out-Null
    $legacyRollback=Complete-RevisionTransition -ProjectRoot $migrationFixture
    $afterLegacyRollback=Get-ActiveRevisionPointer -ProjectRoot $migrationFixture
    Assert-Fixture -Condition ([string]$afterLegacyRollback.active_revision -ceq $legacyPrevious.Index -and [string]$afterLegacyRollback.previous_revision -ceq $legacyActive.Index) -Message 'Schema-2 pointer could not roll back to a copied legacy manifest-2 revision.'
    $legacyRollbackRetry=Complete-RevisionTransition -ProjectRoot $migrationFixture
    $afterLegacyRollbackRetry=Get-ActiveRevisionPointer -ProjectRoot $migrationFixture
    Assert-Fixture -Condition ([string]$afterLegacyRollbackRetry.active_revision -ceq $legacyPrevious.Index -and [string]$afterLegacyRollbackRetry.previous_revision -ceq $legacyActive.Index) -Message 'Interrupted rollback recovery toggled the active and previous revisions.'
    Clear-RevisionTransition -ProjectRoot $migrationFixture -ExpectedTransition $legacyRollbackRetry

    $migrationConflict=Join-Path $fixture 'legacy-migration-conflict';New-Item -ItemType Directory -Path $migrationConflict|Out-Null
    $conflictingLegacy=New-LegacyRevisionFixture -Root $migrationConflict -Seed 'conflict';New-Item -ItemType Directory -Path (Join-Path $migrationConflict "revisions\$($conflictingLegacy.Index)")|Out-Null
    Set-ActiveRevisionPointer -ProjectRoot $migrationConflict -ActiveRevision $conflictingLegacy.Corpus -PreviousRevision $null -SchemaVersion 1|Out-Null
    $migrationConflictRejected=$false;try{Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $migrationConflict|Out-Null}catch{$migrationConflictRejected=$true}
    Assert-Fixture -Condition $migrationConflictRejected -Message 'Legacy migration accepted a conflicting pre-existing index directory.'
    Assert-Fixture -Condition ([int](Get-ActiveRevisionPointer -ProjectRoot $migrationConflict).schema_version -eq 1) -Message 'Failed migration changed the legacy pointer.'

    $corpusResult = if ($SkipInstalledCorpusValidation) { 'installed CHM counts deferred to the release suite' } else { 'independent CHM counts' }
    Write-Host "Maintenance fixtures passed: package-layout trust, $corpusResult, integrity/ranking/topic-loss refusal, exact asset closure and package tamper refusal, legacy pointer migration/retry/conflict refusal, checksum migration, stage-report refresh, strict schema-2 journals, idempotent apply/rollback, and interruption recovery."
} finally {
    if (Test-Path -LiteralPath $fixture -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $fixture }
}
