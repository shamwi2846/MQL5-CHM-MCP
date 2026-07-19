[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'SevenZipRuntime.ps1')

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
$buildRoot = Join-Path $projectRoot 'build'
if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) { New-Item -ItemType Directory -Path $buildRoot | Out-Null }
$testRoot = Join-Path $buildRoot ('sevenzip-runtime-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0

function Assert-Test {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Get-TextDescriptor {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{Bytes=[int64]$bytes.Length;Sha256=$hash}
}

function New-SevenZipFixture {
    param([Parameter(Mandatory)][string]$Name,[switch]$WithRuntime)
    $fixture = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $fixture 'tools') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'licenses') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'build') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7zip.provenance.json') -Destination (Join-Path $fixture 'tools\7zip.provenance.json')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses\7ZIP-LICENSE.txt') -Destination (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')
    if ($WithRuntime) {
        Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7z.exe') -Destination (Join-Path $fixture 'tools\7z.exe')
        Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7z.dll') -Destination (Join-Path $fixture 'tools\7z.dll')
    }
    return $fixture
}

function New-SevenZipRepairHooks {
    param(
        [string]$DownloadText = 'synthetic-msi',
        [string]$ExpectedText = 'synthetic-msi',
        [ValidateSet('valid','missing-dll','bad-exe','bad-license','throw')][string]$ExtractionMode = 'valid',
        [scriptblock]$PublicationCheckpoint,
        [scriptblock]$PeMachineTypeProbe,
        [scriptblock]$FileVersionProbe,
        [scriptblock]$NativeInfoProbe,
        [hashtable]$Observation
    )
    if ($null -eq $Observation) { $Observation = @{} }
    $descriptor = Get-TextDescriptor -Text $ExpectedText
    $referenceRoot = $projectRoot
    $downloadValue = $DownloadText
    $extractMode = $ExtractionMode
    $observationValue = $Observation
    $download = {
        param($uri,$destination,$timeoutSeconds,$maximumBytes)
        $observationValue.Uri = [string]$uri.AbsoluteUri
        $observationValue.TimeoutSeconds = [int]$timeoutSeconds
        $observationValue.MaximumBytes = [int64]$maximumBytes
        [IO.File]::WriteAllText($destination,$downloadValue,(New-Object Text.UTF8Encoding($false)))
    }.GetNewClosure()
    $extract = {
        param($artifact,$destination)
        if ($extractMode -ceq 'throw') { throw 'synthetic msiexec failure' }
        $distribution = Join-Path $destination 'Files\7-Zip'
        New-Item -ItemType Directory -Path $distribution -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $referenceRoot 'tools\7z.exe') -Destination (Join-Path $distribution '7z.exe')
        if ($extractMode -cne 'missing-dll') {
            Copy-Item -LiteralPath (Join-Path $referenceRoot 'tools\7z.dll') -Destination (Join-Path $distribution '7z.dll')
        }
        Copy-Item -LiteralPath (Join-Path $referenceRoot 'licenses\7ZIP-LICENSE.txt') -Destination (Join-Path $distribution 'License.txt')
        if ($extractMode -ceq 'bad-exe') {
            $stream = [IO.File]::Open((Join-Path $distribution '7z.exe'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.WriteByte(0) } finally { $stream.Dispose() }
        }
        if ($extractMode -ceq 'bad-license') {
            [IO.File]::AppendAllText((Join-Path $distribution 'License.txt'),'tampered')
        }
    }.GetNewClosure()
    $hooks = @{
        ExpectedArtifactBytes = [int64]$descriptor.Bytes
        ExpectedArtifactSha256 = [string]$descriptor.Sha256
        DownloadArtifact = $download
        ExtractArtifact = $extract
    }
    if ($null -ne $PublicationCheckpoint) { $hooks.PublicationCheckpoint = $PublicationCheckpoint }
    if ($null -ne $PeMachineTypeProbe) { $hooks.PeMachineTypeProbe = $PeMachineTypeProbe }
    if ($null -ne $FileVersionProbe) { $hooks.FileVersionProbe = $FileVersionProbe }
    if ($null -ne $NativeInfoProbe) { $hooks.NativeInfoProbe = $NativeInfoProbe }
    return $hooks
}

function Assert-NoSevenZipTemporaryDebris {
    param([Parameter(Mandatory)][string]$Fixture)
    $toolDebris = @(Get-ReservedSevenZipRuntimeArtifacts -ToolsRoot (Join-Path $Fixture 'tools'))
    $licenseDebris = @(Get-ReservedSevenZipLicenseArtifacts -LicensesRoot (Join-Path $Fixture 'licenses'))
    $buildDebris = @(Get-ChildItem -LiteralPath (Join-Path $Fixture 'build') -Force | Where-Object { $_.Name -like '7zip-*' })
    Assert-Test ($toolDebris.Count -eq 0) '7-Zip runtime repair retained reserved tools debris.'
    Assert-Test ($licenseDebris.Count -eq 0) '7-Zip runtime repair retained reserved license debris.'
    Assert-Test ($buildDebris.Count -eq 0) '7-Zip runtime repair retained isolated build debris.'
}

try {
    $metadata = Get-PinnedSevenZipMetadata -ProjectRoot $projectRoot
    Assert-Test ([int64]$metadata.ArtifactBytes -eq 1999872) 'Pinned 7-Zip MSI byte count is wrong.'
    Assert-Test ([string]$metadata.ArtifactSha256 -ceq 'db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e') 'Pinned 7-Zip MSI hash is wrong.'
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $projectRoot 'tools\7z.exe') -DllPath (Join-Path $projectRoot 'tools\7z.dll') -LicensePath (Join-Path $projectRoot 'licenses\7ZIP-LICENSE.txt')) 'Checked-in 7-Zip runtime is not the pinned pair.'

    $badOriginRejected = $false
    try { Invoke-BoundedSevenZipDownload -Uri ([Uri]'https://example.com/7z2602-x64.msi') -Destination (Join-Path $testRoot 'unexpected.msi') | Out-Null }
    catch { $badOriginRejected = $true }
    Assert-Test $badOriginRejected '7-Zip downloader accepted a non-pinned origin.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $testRoot 'unexpected.msi'))) 'Rejected 7-Zip origin created an output file.'

    # A missing pair is repaired from an isolated, validated MSI extraction.
    $fixture = New-SevenZipFixture -Name 'successful-repair'
    $observed = @{}
    $hooks = New-SevenZipRepairHooks -Observation $observed
    $result = Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks $hooks
    Assert-Test ([string]$result.ExeName -ceq '7z.exe') 'Successful 7-Zip repair returned the wrong executable.'
    Assert-Test ([string]$observed.Uri -ceq $script:PinnedSevenZipMsiUri) '7-Zip repair requested the wrong artifact URL.'
    Assert-Test ([int]$observed.TimeoutSeconds -eq 300) '7-Zip repair did not impose the 300-second deadline.'
    Assert-Test ([int64]$observed.MaximumBytes -eq 16777216) '7-Zip repair did not impose the 16 MiB stream cap.'
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Repaired 7-Zip pair failed final validation.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # Missing and wrong canonical license files are repaired from the same
    # validated MSI without republishing an already-valid executable pair.
    foreach ($licenseCase in @('missing-license','wrong-license')) {
        $fixture = New-SevenZipFixture -Name $licenseCase -WithRuntime
        $license = Join-Path $fixture 'licenses\7ZIP-LICENSE.txt'
        if ($licenseCase -ceq 'missing-license') { Remove-Item -LiteralPath $license -Force }
        else { [IO.File]::WriteAllText($license,'damaged license',(New-Object Text.UTF8Encoding($false))) }
        $exeHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.exe') -Algorithm SHA256).Hash
        $dllHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.dll') -Algorithm SHA256).Hash
        Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks) | Out-Null
        Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath $license) "7-Zip repair did not replace the $licenseCase fixture from the validated MSI."
        Assert-Test ((Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.exe') -Algorithm SHA256).Hash -ceq $exeHash) "7-Zip license-only repair republished the executable for $licenseCase."
        Assert-Test ((Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.dll') -Algorithm SHA256).Hash -ceq $dllHash) "7-Zip license-only repair republished the library for $licenseCase."
        Assert-NoSevenZipTemporaryDebris -Fixture $fixture
    }

    # Wrong artifact bytes fail before extraction or canonical mutation.
    $fixture = New-SevenZipFixture -Name 'bad-artifact'
    $hooks = New-SevenZipRepairHooks -DownloadText 'wrong-msi' -ExpectedText 'expected-msi'
    $rejected = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks $hooks | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected '7-Zip repair accepted a bad artifact hash/size.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'tools\7z.exe'))) 'Bad MSI repair published an executable.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'tools\7z.dll'))) 'Bad MSI repair published a library.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    foreach ($case in @(
        [pscustomobject]@{Name='msiexec-failure';Mode='throw';Pe=$null;Version=$null;Native=$null},
        [pscustomobject]@{Name='missing-dll';Mode='missing-dll';Pe=$null;Version=$null;Native=$null},
        [pscustomobject]@{Name='bad-output-hash';Mode='bad-exe';Pe=$null;Version=$null;Native=$null},
        [pscustomobject]@{Name='bad-license';Mode='bad-license';Pe=$null;Version=$null;Native=$null},
        [pscustomobject]@{Name='bad-architecture';Mode='valid';Pe={ param($path) 0x014c };Version=$null;Native=$null},
        [pscustomobject]@{Name='bad-version';Mode='valid';Pe=$null;Version={ param($path) '25.01' };Native=$null},
        [pscustomobject]@{Name='missing-chm-capability';Mode='valid';Pe=$null;Version=$null;Native={ param($path) [pscustomobject]@{ExitCode=0;Text='7-Zip 26.02 (x64)'} }}
    )) {
        $fixture = New-SevenZipFixture -Name $case.Name
        $hooks = New-SevenZipRepairHooks -ExtractionMode $case.Mode -PeMachineTypeProbe $case.Pe -FileVersionProbe $case.Version -NativeInfoProbe $case.Native
        $rejected = $false
        try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks $hooks | Out-Null } catch { $rejected = $true }
        Assert-Test $rejected "7-Zip repair accepted invalid case '$($case.Name)'."
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'tools\7z.exe'))) "Invalid case '$($case.Name)' published an executable."
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'tools\7z.dll'))) "Invalid case '$($case.Name)' published a library."
        Assert-NoSevenZipTemporaryDebris -Fixture $fixture
    }

    # Every durable publication cut point recovers to the complete candidate.
    foreach ($checkpointCase in @(
        [pscustomobject]@{Name='journal';Phase='journal-written';Index=-1},
        [pscustomobject]@{Name='first-backup';Phase='prior-backed-up';Index=0},
        [pscustomobject]@{Name='before-first-publish';Phase='before-candidate-publish';Index=0},
        [pscustomobject]@{Name='after-first-publish';Phase='candidate-published';Index=0}
    )) {
        $fixture = New-SevenZipFixture -Name ("cut-" + $checkpointCase.Name) -WithRuntime
        $exe = Join-Path $fixture 'tools\7z.exe'
        $stream = [IO.File]::Open($exe,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.WriteByte(0) } finally { $stream.Dispose() }
        $phaseValue = [string]$checkpointCase.Phase
        $indexValue = [int]$checkpointCase.Index
        $checkpoint = {
            param($phase,$index,$target,$other)
            if ([string]$phase -ceq $phaseValue -and [int]$index -eq $indexValue) { throw 'synthetic publication interruption' }
        }.GetNewClosure()
        $hooks = New-SevenZipRepairHooks -PublicationCheckpoint $checkpoint
        Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks $hooks | Out-Null
        Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) "Publication cut '$($checkpointCase.Name)' did not recover the candidate pair."
        Assert-NoSevenZipTemporaryDebris -Fixture $fixture
    }

    $fixture = New-SevenZipFixture -Name 'cut-runtime-journal-prepared'
    $checkpoint = { param($phase) if ([string]$phase -ceq 'journal-prepared') { throw 'synthetic prepared runtime journal interruption' } }
    $interrupted = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks -PublicationCheckpoint $checkpoint) | Out-Null }
    catch { $interrupted = $_.Exception.Message -match 'synthetic prepared runtime journal interruption' }
    Assert-Test $interrupted '7-Zip runtime journal-prepared cut did not interrupt publication.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'tools') -Force | Where-Object Name -like '.7zip-runtime-transaction.json.prepared-*').Count -eq 1) '7-Zip runtime journal-prepared cut did not retain its bound recovery journal.'
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks) | Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) '7-Zip runtime journal-prepared recovery did not produce the pinned set.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # The independently rooted license publication is also recoverable at
    # every durable file-set cut point.
    foreach ($checkpointCase in @(
        [pscustomobject]@{Name='license-journal';Phase='journal-written';Index=-1},
        [pscustomobject]@{Name='license-backup';Phase='prior-backed-up';Index=0},
        [pscustomobject]@{Name='license-before-publish';Phase='before-candidate-publish';Index=0},
        [pscustomobject]@{Name='license-after-publish';Phase='candidate-published';Index=0}
    )) {
        $fixture = New-SevenZipFixture -Name ("cut-" + $checkpointCase.Name) -WithRuntime
        [IO.File]::WriteAllText((Join-Path $fixture 'licenses\7ZIP-LICENSE.txt'),'damaged license',(New-Object Text.UTF8Encoding($false)))
        $phaseValue = [string]$checkpointCase.Phase
        $indexValue = [int]$checkpointCase.Index
        $checkpoint = {
            param($phase,$index,$target,$other)
            if ([string]$phase -ceq $phaseValue -and [int]$index -eq $indexValue -and [IO.Path]::GetFileName([string]$target) -ceq '7ZIP-LICENSE.txt') {
                throw 'synthetic license publication interruption'
            }
        }.GetNewClosure()
        Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks -PublicationCheckpoint $checkpoint) | Out-Null
        Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) "License publication cut '$($checkpointCase.Name)' did not recover the complete pinned set."
        Assert-NoSevenZipTemporaryDebris -Fixture $fixture
    }

    $fixture = New-SevenZipFixture -Name 'cut-license-journal-prepared' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $checkpoint = { param($phase) if ([string]$phase -ceq 'journal-prepared') { throw 'synthetic prepared license journal interruption' } }
    $interrupted = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks -PublicationCheckpoint $checkpoint) | Out-Null }
    catch { $interrupted = $_.Exception.Message -match 'synthetic prepared license journal interruption' }
    Assert-Test $interrupted '7-Zip license journal-prepared cut did not interrupt publication.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'licenses') -Force | Where-Object Name -like '.7zip-license-transaction.json.prepared-*').Count -eq 1) '7-Zip license journal-prepared cut did not retain its bound recovery journal.'
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks) | Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) '7-Zip license journal-prepared recovery did not produce the pinned set.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # If a candidate disappears after the prior pair is backed up, recovery
    # restores the exact prior bytes and leaves no misleading completion marker.
    $fixture = New-SevenZipFixture -Name 'publication-rollback'
    [IO.File]::WriteAllText((Join-Path $fixture 'tools\7z.dll'),'prior-dll')
    [IO.File]::WriteAllText((Join-Path $fixture 'tools\7z.exe'),'prior-exe')
    $priorDllHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.dll') -Algorithm SHA256).Hash
    $priorExeHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.exe') -Algorithm SHA256).Hash
    $checkpoint = {
        param($phase,$index,$target,$other)
        if ([string]$phase -ceq 'before-candidate-publish' -and [int]$index -eq 0) {
            Remove-Item -LiteralPath $other -Force
        }
    }
    $hooks = New-SevenZipRepairHooks -PublicationCheckpoint $checkpoint
    $rolledBack = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks $hooks | Out-Null } catch { $rolledBack = $true }
    Assert-Test $rolledBack 'Interrupted 7-Zip publication unexpectedly reported success after rollback.'
    Assert-Test ((Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.dll') -Algorithm SHA256).Hash -ceq $priorDllHash) '7-Zip rollback did not restore the prior library.'
    Assert-Test ((Get-FileHash -LiteralPath (Join-Path $fixture 'tools\7z.exe') -Algorithm SHA256).Hash -ceq $priorExeHash) '7-Zip rollback did not restore the prior executable.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # Complete exact-token pre-journal debris is recoverable offline.
    $fixture = New-SevenZipFixture -Name 'offline-prejournal-complete'
    $token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7z.dll') -Destination (Join-Path $fixture "tools\.7z-dll-$token.prepared")
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7z.exe') -Destination (Join-Path $fixture "tools\.7z-exe-$token.prepared")
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload | Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Offline pre-journal recovery did not publish the complete pinned pair.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # Incomplete offline debris is ambiguous and preserved.
    $fixture = New-SevenZipFixture -Name 'offline-prejournal-partial'
    $token = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $partial = Join-Path $fixture "tools\.7z-exe-$token.prepared"
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\7z.exe') -Destination $partial
    $rejected = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Incomplete offline 7-Zip debris was accepted.'
    Assert-Test (Test-Path -LiteralPath $partial -PathType Leaf) 'Incomplete offline 7-Zip debris was not preserved.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'tools\7z.exe'))) 'Incomplete offline debris created a canonical executable.'

    # Hard termination during a durable copy leaves an exact .writing leaf.
    # Offline recovery removes only that incomplete item and retains a complete
    # prepared sibling for later repair.
    foreach($writingKind in @('exe','dll')) {
        $fixture = New-SevenZipFixture -Name "offline-partial-$writingKind-writing"
        $token = if($writingKind -ceq 'exe'){'d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1'}else{'d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2'}
        $writingPath = Join-Path $fixture "tools\.7z-$writingKind-$token.writing"
        $preparedSibling = if($writingKind -ceq 'exe'){
            Join-Path $fixture "tools\.7z-dll-$token.prepared"
        }else{
            Join-Path $fixture "tools\.7z-exe-$token.prepared"
        }
        $siblingSource = if($writingKind -ceq 'exe'){Join-Path $projectRoot 'tools\7z.dll'}else{Join-Path $projectRoot 'tools\7z.exe'}
        Copy-Item -LiteralPath $siblingSource -Destination $preparedSibling
        [IO.File]::WriteAllBytes($writingPath,[byte[]](1,2,3,4))
        $rejected=$false
        try{Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload|Out-Null}catch{$rejected=$true}
        Assert-Test ($rejected -and -not (Test-Path -LiteralPath $writingPath) -and (Test-Path -LiteralPath $preparedSibling -PathType Leaf)) "Offline 7-Zip $writingKind writing recovery did not preserve the complete prepared sibling."
    }

    $fixture = New-SevenZipFixture -Name 'offline-partial-license-writing' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $licenseWriting=Join-Path $fixture 'licenses\.7zip-license-d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3.writing'
    [IO.File]::WriteAllBytes($licenseWriting,[byte[]](1,2,3))
    $rejected=$false
    try{Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload|Out-Null}catch{$rejected=$true}
    Assert-Test ($rejected -and -not (Test-Path -LiteralPath $licenseWriting) -and -not (Test-Path -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt'))) 'Offline 7-Zip license writing recovery created or retained untrusted license bytes.'

    # With a validated official repair source available, partial writing leaves
    # are reclaimed and the complete runtime/license set is rebuilt.
    $fixture = New-SevenZipFixture -Name 'online-partial-writing-repair'
    $onlineToken='d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4'
    foreach($relative in @("tools\.7z-exe-$onlineToken.writing","tools\.7z-dll-$onlineToken.writing","licenses\.7zip-license-$onlineToken.writing")){
        [IO.File]::WriteAllBytes((Join-Path $fixture $relative),[byte[]](9,8,7))
    }
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks)|Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Online 7-Zip repair did not recover partial writing payloads.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # Compatibility with the previous direct-to-prepared copy path. Invalid
    # exact-token remnants are evidence in offline mode, but a validated online
    # official-MSI path may discard them and rebuild the complete set.
    $fixture=New-SevenZipFixture -Name 'offline-invalid-prepared-runtime'
    $invalidToken='d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5'
    $invalidRuntimePrepared=@(
        (Join-Path $fixture "tools\.7z-exe-$invalidToken.prepared"),
        (Join-Path $fixture "tools\.7z-dll-$invalidToken.prepared")
    )
    foreach($path in $invalidRuntimePrepared){[IO.File]::WriteAllBytes($path,[byte[]](1,2,3))}
    $rejected=$false
    try{Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload|Out-Null}catch{$rejected=$true}
    Assert-Test ($rejected -and @($invalidRuntimePrepared|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}).Count -eq 2) 'Offline 7-Zip repair discarded malformed prepared runtime evidence.'

    $fixture=New-SevenZipFixture -Name 'online-invalid-prepared-runtime'
    foreach($path in @(
        (Join-Path $fixture "tools\.7z-exe-$invalidToken.prepared"),
        (Join-Path $fixture "tools\.7z-dll-$invalidToken.prepared")
    )){[IO.File]::WriteAllBytes($path,[byte[]](1,2,3))}
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks)|Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Online 7-Zip repair did not replace malformed prepared runtime remnants.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    $fixture=New-SevenZipFixture -Name 'offline-invalid-prepared-license' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $invalidLicensePrepared=Join-Path $fixture 'licenses\.7zip-license-d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6.prepared'
    [IO.File]::WriteAllBytes($invalidLicensePrepared,[byte[]](1,2,3))
    $rejected=$false
    try{Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload|Out-Null}catch{$rejected=$true}
    Assert-Test ($rejected -and (Test-Path -LiteralPath $invalidLicensePrepared -PathType Leaf)) 'Offline 7-Zip repair discarded malformed prepared license evidence.'

    $fixture=New-SevenZipFixture -Name 'online-invalid-prepared-license' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $invalidLicensePrepared=Join-Path $fixture 'licenses\.7zip-license-d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7.prepared'
    [IO.File]::WriteAllBytes($invalidLicensePrepared,[byte[]](1,2,3))
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -InternalTestHooks (New-SevenZipRepairHooks)|Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Online 7-Zip repair did not replace malformed prepared license remnants.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    # A complete exact-token license candidate is independently recoverable
    # offline, while a bad canonical license with no candidate fails closed.
    $fixture = New-SevenZipFixture -Name 'offline-license-prejournal' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $token = 'cccccccccccccccccccccccccccccccc'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses\7ZIP-LICENSE.txt') -Destination (Join-Path $fixture "licenses\.7zip-license-$token.prepared")
    Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload | Out-Null
    Assert-Test (Test-PinnedSevenZipRuntimePair -ExePath (Join-Path $fixture 'tools\7z.exe') -DllPath (Join-Path $fixture 'tools\7z.dll') -LicensePath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt')) 'Offline pre-journal recovery did not publish the pinned 7-Zip license.'
    Assert-NoSevenZipTemporaryDebris -Fixture $fixture

    $fixture = New-SevenZipFixture -Name 'offline-license-missing' -WithRuntime
    Remove-Item -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt') -Force
    $rejected = $false
    try { Ensure-PinnedSevenZipRuntime -ProjectRoot $fixture -NoDownload | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Offline 7-Zip repair accepted a missing license without a validated candidate.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture 'licenses\7ZIP-LICENSE.txt'))) 'Failed offline license repair created a canonical license.'

    Write-Host "7-Zip runtime tests passed: $passed"
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $testRoot
    }
}
