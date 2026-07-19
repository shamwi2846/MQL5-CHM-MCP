[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

# Load only the portable packager's function definitions. This keeps the test
# hermetic while exercising the real preflight and publication helpers without
# running the script's top-level packaging operation.
$packageTokens=$null;$packageParseErrors=$null
$packageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Package-Portable.ps1'),[ref]$packageTokens,[ref]$packageParseErrors)
if($packageParseErrors.Count){throw 'Could not parse Package-Portable.ps1 for packaging repair tests.'}
foreach($functionAst in $packageAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    Invoke-Expression $functionAst.Extent.Text
}

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
$nodeFixtureLicense = Join-Path $projectRoot 'licenses\NODE-LICENSE.txt'
$bundledNodeFixture = Join-Path $projectRoot 'runtime\node.exe'
$nodeFixtureSource = if (Test-PinnedNodeRuntimePair -NodePath $bundledNodeFixture -LicensePath $nodeFixtureLicense) {
    $bundledNodeFixture
} else {
    (Get-Command node -CommandType Application -ErrorAction Stop).Source
}
if (-not (Test-PinnedNodeRuntimePair -NodePath $nodeFixtureSource -LicensePath $nodeFixtureLicense)) {
    throw 'Packaging repair tests require the exact Node.js 24.17.0 x64 executable either in runtime or on PATH.'
}
$buildRoot = Join-Path $projectRoot 'build'
if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) { New-Item -ItemType Directory -Path $buildRoot | Out-Null }
$testRoot = Join-Path $buildRoot ('packaging-repair-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0

function Assert-Test {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Get-Descriptor {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Bytes=[int64]$item.Length
        Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-NodeBootstrapFixture {
    param([Parameter(Mandatory)][string]$Name)

    $fixtureRoot = Join-Path $testRoot $Name
    foreach ($directory in @($fixtureRoot,(Join-Path $fixtureRoot 'runtime'),(Join-Path $fixtureRoot 'licenses'),(Join-Path $fixtureRoot 'build'))) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Copy-FileDurable -Source (Join-Path $projectRoot 'licenses\NODE-LICENSE.txt') -Destination (Join-Path $fixtureRoot 'licenses\NODE-LICENSE.txt') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'runtime\node.exe'), "prior-node-$Name", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'runtime\LICENSE'), "prior-license-$Name", (New-Object Text.UTF8Encoding($false)))
    return $fixtureRoot
}

function New-NodeBootstrapTestHooks {
    param(
        [ValidateSet('valid','bad-hash')][string]$NodeMode = 'valid',
        [ValidateSet('valid','bad-hash')][string]$LicenseMode = 'valid',
        [scriptblock]$PeMachineTypeProbe,
        [scriptblock]$FileVersionProbe,
        [scriptblock]$NativeVersionProbe,
        [scriptblock]$PublicationCheckpoint
    )

    $archiveBytes = [Text.Encoding]::UTF8.GetBytes('deterministic-local-node-archive-fixture-v1')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $archiveSha256 = ([BitConverter]::ToString($sha.ComputeHash($archiveBytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $nodeSource = $nodeFixtureSource
    $licenseSource = $nodeFixtureLicense
    $downloadArchive = {
        param([Uri]$Uri, [string]$Destination, [int]$TimeoutSeconds, [int64]$MaximumBytes)
        if ($Uri.AbsoluteUri -cne 'https://nodejs.org/dist/v24.17.0/node-v24.17.0-win-x64.zip' -or
            $TimeoutSeconds -ne 300 -or $MaximumBytes -ne 67108864) {
            throw 'Bootstrap passed unexpected download constraints to the injected archive source.'
        }
        [IO.File]::WriteAllBytes($Destination, $archiveBytes)
        return [int64]$archiveBytes.Length
    }.GetNewClosure()
    $expandArchive = {
        param([string]$ArchivePath, [string]$DestinationPath)
        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw 'Injected expansion did not receive the downloaded archive.' }
        $distribution = Join-Path $DestinationPath 'node-v24.17.0-win-x64'
        New-Item -ItemType Directory -Path $distribution | Out-Null
        [IO.File]::Copy($nodeSource, (Join-Path $distribution 'node.exe'), $false)
        [IO.File]::Copy($licenseSource, (Join-Path $distribution 'LICENSE'), $false)
        if ($NodeMode -ceq 'bad-hash') {
            $stream = [IO.File]::Open((Join-Path $distribution 'node.exe'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $original = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte($original -bxor 1); $stream.Flush($true) }
            finally { $stream.Dispose() }
        }
        if ($LicenseMode -ceq 'bad-hash') {
            $stream = [IO.File]::Open((Join-Path $distribution 'LICENSE'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $original = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte($original -bxor 1); $stream.Flush($true) }
            finally { $stream.Dispose() }
        }
    }.GetNewClosure()
    $hooks = @{
        ExpectedArchiveSha256 = $archiveSha256
        DownloadArchive = $downloadArchive
        ExpandArchive = $expandArchive
    }
    if ($null -ne $PeMachineTypeProbe) { $hooks.PeMachineTypeProbe = $PeMachineTypeProbe }
    if ($null -ne $FileVersionProbe) { $hooks.FileVersionProbe = $FileVersionProbe }
    if ($null -ne $NativeVersionProbe) { $hooks.NativeVersionProbe = $NativeVersionProbe }
    if ($null -ne $PublicationCheckpoint) { $hooks.PublicationCheckpoint = $PublicationCheckpoint }
    return $hooks
}

function Assert-NodeBootstrapFailurePreservesRuntime {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][hashtable]$Hooks,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )

    $nodePath = Join-Path $FixtureRoot 'runtime\node.exe'
    $licensePath = Join-Path $FixtureRoot 'runtime\LICENSE'
    $beforeNode = Get-Descriptor $nodePath
    $beforeLicense = Get-Descriptor $licensePath
    $message = $null
    try { Ensure-PinnedNodeRuntime -ProjectRoot $FixtureRoot -InternalTestHooks $Hooks | Out-Null }
    catch { $message = $_.Exception.Message }
    Assert-Test ($null -ne $message -and $message.Contains($ExpectedMessage)) "Node bootstrap did not reject the fixture as expected. Actual error: $message"
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or -not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        $remaining = @((Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'runtime') -Force | ForEach-Object Name) -join ', ')
        throw "Failed Node bootstrap lost a canonical runtime file. Error: $message Remaining: $remaining"
    }
    $afterNode = Get-Descriptor $nodePath
    $afterLicense = Get-Descriptor $licensePath
    Assert-Test ($afterNode.Bytes -eq $beforeNode.Bytes -and $afterNode.Sha256 -ceq $beforeNode.Sha256 -and
        $afterLicense.Bytes -eq $beforeLicense.Bytes -and $afterLicense.Sha256 -ceq $beforeLicense.Sha256) 'Failed Node bootstrap changed the preexisting runtime pair.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'runtime\.node-runtime-transaction.json'))) 'Failed Node bootstrap retained a transaction journal.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'runtime') -Force).Count -eq 2) 'Failed Node bootstrap retained prepared or backup debris.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'build') -Force).Count -eq 0) 'Failed Node bootstrap retained download or expansion debris.'
}

function Invoke-ExpectedPortablePackagingFailure {
    param([Parameter(Mandatory)][string]$OutputDirectory, [Parameter(Mandatory)][string]$ReleaseName)
    $shellPath = (Get-Process -Id $PID).Path
    return Invoke-NativeCapture -FilePath $shellPath -Arguments @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $projectRoot 'scripts\Package-Portable.ps1'),
        '-ProjectRoot',$projectRoot,'-OutputDirectory',$OutputDirectory,'-ReleaseName',$ReleaseName,
        '-CandidateRevision',('0' * 64)
    )
}

function New-TestZipAndSidecar {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ExpectedFile
    )
    $source = Join-Path $Root ('zip-source-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $source | Out-Null
    $payloadPath = Join-Path $source 'payload.txt'
    [IO.File]::WriteAllText($payloadPath, 'transaction-recovery-payload', (New-Object Text.UTF8Encoding($false)))
    $payloadHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $source 'checksums.sha256'), "$payloadHash *payload.txt`n", (New-Object Text.UTF8Encoding($false)))
    Compress-Archive -LiteralPath $source -DestinationPath $ZipPath -CompressionLevel Optimal
    Remove-SafeDirectory -ConfinementRoot $Root -Path $source
    $zip = Get-Descriptor -Path $ZipPath
    Write-JsonAtomic -Path $ManifestPath -ConfinementRoot $Root -Value ([ordered]@{
        schema_version=1;file=$ExpectedFile;bytes=$zip.Bytes;sha256=$zip.Sha256
    })
}

try {
    $metadataProbe = Invoke-NativeCapture -FilePath $nodeFixtureSource -Arguments @(
        '-e',
        "const fs=require('node:fs'),p=require('node:path'),r=process.argv[1],a=JSON.parse(fs.readFileSync(p.join(r,'package.json'),'utf8')),b=JSON.parse(fs.readFileSync(p.join(r,'package-lock.json'),'utf8')),c=b.packages[''];if(a.version!=='1.2.3'||b.version!=='1.2.3'||c.version!=='1.2.3'||a.engines.node!=='24.17.0'||c.engines.node!=='24.17.0')process.exit(2)",
        $projectRoot
    )
    Assert-Test ($metadataProbe.ExitCode -eq 0) 'Package version or exact Node engine metadata is inconsistent.'

    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $nodeFixtureSource -LicensePath $nodeFixtureLicense) 'Available Node runtime fixture is not the pinned distribution.'
    Assert-SevenZipProvenance -ProjectRoot $projectRoot | Out-Null
    Assert-Test $true 'Pinned 7-Zip provenance validation failed.'

    $successfulNodeFixture = New-NodeBootstrapFixture -Name 'successful-truncated-runtime-repair'
    $repairedNode = Ensure-PinnedNodeRuntime -ProjectRoot $successfulNodeFixture -InternalTestHooks (New-NodeBootstrapTestHooks)
    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $repairedNode -LicensePath (Join-Path $successfulNodeFixture 'runtime\LICENSE')) 'Normal Node bootstrap did not repair a truncated/wrong runtime pair.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $successfulNodeFixture 'runtime') -Force).Count -eq 2) 'Normal Node bootstrap retained runtime transaction debris.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $successfulNodeFixture 'build') -Force).Count -eq 0) 'Normal Node bootstrap retained download or expansion debris.'

    $preparedJournalFixture = New-NodeBootstrapFixture -Name 'node-journal-prepared-cut'
    $preparedJournalHooks = New-NodeBootstrapTestHooks -PublicationCheckpoint {
        param([string]$Phase)
        if ($Phase -ceq 'journal-prepared') { throw 'synthetic Node prepared-journal interruption' }
    }
    $preparedJournalInterrupted = $false
    try { Ensure-PinnedNodeRuntime -ProjectRoot $preparedJournalFixture -InternalTestHooks $preparedJournalHooks | Out-Null }
    catch { $preparedJournalInterrupted = $_.Exception.Message -match 'synthetic Node prepared-journal interruption' }
    Assert-Test $preparedJournalInterrupted 'Node journal-prepared cut did not interrupt publication.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $preparedJournalFixture 'runtime') -Force | Where-Object Name -like '.node-runtime-transaction.json.prepared-*').Count -eq 1) 'Node journal-prepared cut did not retain one bound recovery journal.'
    $repairedNode = Ensure-PinnedNodeRuntime -ProjectRoot $preparedJournalFixture -InternalTestHooks (New-NodeBootstrapTestHooks)
    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $repairedNode -LicensePath (Join-Path $preparedJournalFixture 'runtime\LICENSE')) 'Node journal-prepared recovery did not repair the runtime pair.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $preparedJournalFixture 'runtime') -Force).Count -eq 2) 'Node journal-prepared recovery retained transaction debris.'

    # Hard-kill payloads retain only .writing names. They are never referenced
    # by a journal, so startup reclaims them before a normal online repair.
    foreach($kind in @('node','node-license')) {
        $writingFixture = New-NodeBootstrapFixture -Name "node-partial-$kind-writing"
        $writingToken = if($kind -ceq 'node'){'61616161616161616161616161616161'}else{'62626262626262626262626262626262'}
        $writingPath = if($kind -ceq 'node'){
            Join-Path $writingFixture "runtime\.node-$writingToken.writing"
        }else{
            Join-Path $writingFixture "runtime\.node-license-$writingToken.writing"
        }
        [IO.File]::WriteAllBytes($writingPath,[byte[]](1,2,3,4,5))
        $repairedNode = Ensure-PinnedNodeRuntime -ProjectRoot $writingFixture -InternalTestHooks (New-NodeBootstrapTestHooks)
        Assert-Test (Test-PinnedNodeRuntimePair -NodePath $repairedNode -LicensePath (Join-Path $writingFixture 'runtime\LICENSE')) "Node bootstrap did not recover a partial $kind writing payload."
        Assert-Test (-not (Test-Path -LiteralPath $writingPath)) "Node bootstrap retained a partial $kind writing payload."
        Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $writingFixture 'runtime') -Force).Count -eq 2) "Node $kind writing recovery retained transaction debris."
    }

    # If one item crossed the prepared boundary before termination, offline
    # recovery drops only the incomplete writing sibling and preserves the
    # complete prepared evidence.
    $mixedWritingFixture = New-NodeBootstrapFixture -Name 'node-writing-with-prepared-sibling'
    $mixedWritingToken = '63636363636363636363636363636363'
    $mixedPreparedLicense = Join-Path $mixedWritingFixture "runtime\.node-license-$mixedWritingToken.prepared"
    $mixedWritingNode = Join-Path $mixedWritingFixture "runtime\.node-$mixedWritingToken.writing"
    Copy-FileDurable -Source $nodeFixtureLicense -Destination $mixedPreparedLicense | Out-Null
    [IO.File]::WriteAllBytes($mixedWritingNode,[byte[]](1,2,3))
    $mixedRejected=$false
    try{Ensure-PinnedNodeRuntime -ProjectRoot $mixedWritingFixture -NoDownload|Out-Null}catch{$mixedRejected=$true}
    Assert-Test ($mixedRejected -and -not (Test-Path -LiteralPath $mixedWritingNode) -and (Test-Path -LiteralPath $mixedPreparedLicense -PathType Leaf)) 'Offline Node writing recovery did not preserve its complete prepared sibling.'

    # Compatibility with the previous direct-to-prepared writer: malformed
    # exact-token candidates are preserved offline but discarded when a
    # validated official rebuild path is available.
    $invalidPreparedOffline=New-NodeBootstrapFixture -Name 'node-invalid-prepared-offline'
    $invalidPreparedToken='64646464646464646464646464646464'
    $invalidPreparedOfflinePaths=@(
        (Join-Path $invalidPreparedOffline "runtime\.node-$invalidPreparedToken.prepared"),
        (Join-Path $invalidPreparedOffline "runtime\.node-license-$invalidPreparedToken.prepared")
    )
    foreach($path in $invalidPreparedOfflinePaths){[IO.File]::WriteAllBytes($path,[byte[]](1,2,3))}
    $invalidPreparedOfflineRejected=$false
    try{Ensure-PinnedNodeRuntime -ProjectRoot $invalidPreparedOffline -NoDownload|Out-Null}catch{$invalidPreparedOfflineRejected=$true}
    Assert-Test ($invalidPreparedOfflineRejected -and @($invalidPreparedOfflinePaths|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}).Count -eq 2) 'Offline Node repair did not preserve malformed prepared evidence.'
    $invalidPreparedOnline=New-NodeBootstrapFixture -Name 'node-invalid-prepared-online'
    foreach($path in @(
        (Join-Path $invalidPreparedOnline "runtime\.node-$invalidPreparedToken.prepared"),
        (Join-Path $invalidPreparedOnline "runtime\.node-license-$invalidPreparedToken.prepared")
    )){[IO.File]::WriteAllBytes($path,[byte[]](1,2,3))}
    $invalidPreparedNode=Ensure-PinnedNodeRuntime -ProjectRoot $invalidPreparedOnline -InternalTestHooks (New-NodeBootstrapTestHooks)
    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $invalidPreparedNode -LicensePath (Join-Path $invalidPreparedOnline 'runtime\LICENSE')) 'Online Node repair did not replace malformed prepared remnants.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $invalidPreparedOnline 'runtime') -Force).Count -eq 2) 'Online malformed-prepared Node repair retained transaction debris.'

    $sevenZipFixture = Join-Path $testRoot 'sevenzip-fixture'
    New-Item -ItemType Directory -Path (Join-Path $sevenZipFixture 'tools') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sevenZipFixture 'licenses') -Force | Out-Null
    foreach ($relative in @('tools\7z.exe','tools\7z.dll','tools\7zip.provenance.json','licenses\7ZIP-LICENSE.txt')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination (Join-Path $sevenZipFixture $relative)
    }
    $fixtureProvenancePath = Join-Path $sevenZipFixture 'tools\7zip.provenance.json'
    $fixtureProvenance = [IO.File]::ReadAllText($fixtureProvenancePath)
    foreach ($mutation in @(
        [pscustomobject]@{Name='version';Text=$fixtureProvenance.Replace('"version": "26.02"','"version": "25.01"')},
        [pscustomobject]@{Name='architecture';Text=$fixtureProvenance.Replace('"architecture": "x64"','"architecture": "x86"')}
    )) {
        [IO.File]::WriteAllText($fixtureProvenancePath, $mutation.Text, (New-Object Text.UTF8Encoding($false)))
        $rejected = $false
        try { Assert-SevenZipProvenance -ProjectRoot $sevenZipFixture | Out-Null } catch { $rejected = $true }
        Assert-Test $rejected "7-Zip provenance accepted the wrong $($mutation.Name)."
    }
    [IO.File]::WriteAllText($fixtureProvenancePath, $fixtureProvenance, (New-Object Text.UTF8Encoding($false)))
    $tamperedSevenZip = Join-Path $sevenZipFixture 'tools\7z.exe'
    $tamperedStream = [IO.File]::Open($tamperedSevenZip, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $tamperedStream.Position = 0; $tamperedStream.WriteByte(0) } finally { $tamperedStream.Dispose() }
    $tamperedRejected = $false
    try { Assert-SevenZipProvenance -ProjectRoot $sevenZipFixture | Out-Null } catch { $tamperedRejected = $true }
    Assert-Test $tamperedRejected '7-Zip provenance accepted a hash-mismatched executable.'

    foreach ($invalidUri in @('http://nodejs.org/dist/file.zip','https://example.com/file.zip','https://user@nodejs.org/file.zip')) {
        $rejected = $false
        try { Invoke-BoundedNodeJsDownload -Uri ([Uri]$invalidUri) -Destination (Join-Path $testRoot 'unexpected.bin') -TimeoutSeconds 1 -MaximumBytes 16 | Out-Null }
        catch { $rejected = $true }
        Assert-Test $rejected "Unsafe Node.js download URI was accepted: $invalidUri"
    }

    $overflowPath = Join-Path $testRoot 'overflow.bin'
    $overflowStream = [IO.MemoryStream]::new((New-Object byte[] 32), $false)
    $overflowToken = [Threading.CancellationToken]::None
    $overflowRejected = $false
    try { Copy-StreamToFileBounded -Stream $overflowStream -Destination $overflowPath -MaximumBytes 16 -CancellationToken $overflowToken | Out-Null }
    catch { $overflowRejected = $true }
    finally { $overflowStream.Dispose() }
    Assert-Test $overflowRejected 'Oversized download stream was accepted.'
    Assert-Test (-not (Test-Path -LiteralPath $overflowPath)) 'Oversized download left a partial file.'

    $timeoutPath = Join-Path $testRoot 'timeout.bin'
    $timeoutStream = [IO.MemoryStream]::new((New-Object byte[] 1), $false)
    $deadline = New-Object Threading.CancellationTokenSource
    $deadline.Cancel()
    $timeoutRejected = $false
    try { Copy-StreamToFileBounded -Stream $timeoutStream -Destination $timeoutPath -MaximumBytes 16 -CancellationToken $deadline.Token | Out-Null }
    catch { $timeoutRejected = $true }
    finally { $deadline.Dispose(); $timeoutStream.Dispose() }
    Assert-Test $timeoutRejected 'Cancelled download stream was accepted.'
    Assert-Test (-not (Test-Path -LiteralPath $timeoutPath)) 'Cancelled download left a partial file.'

    $badArchiveFixture = New-NodeBootstrapFixture -Name 'bad-archive-hash'
    $badArchiveHooks = New-NodeBootstrapTestHooks
    $badArchiveBytes = [Text.Encoding]::UTF8.GetBytes('wrong-local-archive-bytes')
    $badArchiveHooks.DownloadArchive = {
        param([Uri]$Uri, [string]$Destination, [int]$TimeoutSeconds, [int64]$MaximumBytes)
        [IO.File]::WriteAllBytes($Destination, $badArchiveBytes)
        return [int64]$badArchiveBytes.Length
    }.GetNewClosure()
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $badArchiveFixture -Hooks $badArchiveHooks -ExpectedMessage 'SHA-256 mismatch'

    $badNodeFixture = New-NodeBootstrapFixture -Name 'bad-extracted-node-hash'
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $badNodeFixture -Hooks (New-NodeBootstrapTestHooks -NodeMode bad-hash) -ExpectedMessage 'Extracted Node.js files do not match'

    $badLicenseFixture = New-NodeBootstrapFixture -Name 'bad-extracted-license-hash'
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $badLicenseFixture -Hooks (New-NodeBootstrapTestHooks -LicenseMode bad-hash) -ExpectedMessage 'Extracted Node.js files do not match'

    $wrongArchitectureFixture = New-NodeBootstrapFixture -Name 'wrong-extracted-architecture'
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $wrongArchitectureFixture -Hooks (New-NodeBootstrapTestHooks -PeMachineTypeProbe { param($Path) return 0x014c }) -ExpectedMessage 'Extracted Node.js files do not match'

    $wrongVersionFixture = New-NodeBootstrapFixture -Name 'wrong-extracted-version'
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $wrongVersionFixture -Hooks (New-NodeBootstrapTestHooks -FileVersionProbe { param($Path) return '0.0.0.0' }) -ExpectedMessage 'Extracted Node.js files do not match'

    $wrongRuntimeVersionFixture = New-NodeBootstrapFixture -Name 'wrong-runtime-version-output'
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $wrongRuntimeVersionFixture -Hooks (New-NodeBootstrapTestHooks -NativeVersionProbe {
        param($Path)
        return [pscustomobject]@{ ExitCode=0; Text='v0.0.0'; Lines=@('v0.0.0') }
    }) -ExpectedMessage 'Extracted Node.js files do not match'

    $sourceLicenseFixture = New-NodeBootstrapFixture -Name 'bad-source-license'
    $sourceLicensePath = Join-Path $sourceLicenseFixture 'licenses\NODE-LICENSE.txt'
    $sourceLicenseStream = [IO.File]::Open($sourceLicensePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $original = $sourceLicenseStream.ReadByte(); $sourceLicenseStream.Position = 0; $sourceLicenseStream.WriteByte($original -bxor 1); $sourceLicenseStream.Flush($true) }
    finally { $sourceLicenseStream.Dispose() }
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $sourceLicenseFixture -Hooks (New-NodeBootstrapTestHooks) -ExpectedMessage 'checked-in Node.js license does not match'

    $publicationFixture = New-NodeBootstrapFixture -Name 'publication-rollback'
    $publicationHooks = New-NodeBootstrapTestHooks -PublicationCheckpoint {
        param([string]$Phase, [int]$Index, [string]$TargetPath, [string]$PreparedPath)
        if ($Phase -ceq 'before-candidate-publish' -and $Index -eq 1) {
            Remove-Item -LiteralPath $PreparedPath -Force
            throw 'Injected Node runtime publication failure.'
        }
    }
    Assert-NodeBootstrapFailurePreservesRuntime -FixtureRoot $publicationFixture -Hooks $publicationHooks -ExpectedMessage 'Injected Node runtime publication failure.'

    # Model a crash after the durable journal but before either runtime target
    # was replaced. Startup must finish the complete candidate, with Node last.
    $fixture = Join-Path $testRoot 'runtime-fixture'
    foreach ($directory in @($fixture,(Join-Path $fixture 'runtime'),(Join-Path $fixture 'licenses'),(Join-Path $fixture 'build'))) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Copy-FileDurable -Source (Join-Path $projectRoot 'licenses\NODE-LICENSE.txt') -Destination (Join-Path $fixture 'licenses\NODE-LICENSE.txt') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'runtime\node.exe'), 'truncated')
    [IO.File]::WriteAllText((Join-Path $fixture 'runtime\LICENSE'), 'wrong-license')
    $runtimeToken = 'abcdefabcdefabcdefabcdefabcdefab'
    $preparedNode = Join-Path $fixture "runtime\.node-$runtimeToken.prepared"
    $preparedLicense = Join-Path $fixture "runtime\.node-license-$runtimeToken.prepared"
    Copy-FileDurable -Source $nodeFixtureSource -Destination $preparedNode | Out-Null
    Copy-FileDurable -Source $nodeFixtureLicense -Destination $preparedLicense | Out-Null
    $oldNode = Get-Descriptor (Join-Path $fixture 'runtime\node.exe')
    $oldLicense = Get-Descriptor (Join-Path $fixture 'runtime\LICENSE')
    $newNode = Get-Descriptor $preparedNode
    $newLicense = Get-Descriptor $preparedLicense
    $journal = [ordered]@{
        schema_version=2
        operation='publish-prepared-file-set'
        transaction_id='fedcba9876543210fedcba9876543210'
        role='node-runtime'
        items=@(
            [ordered]@{target='LICENSE';prepared=".node-license-$runtimeToken.prepared";backup='.LICENSE.backup-fedcba9876543210fedcba9876543210';old_present=$true;old_bytes=$oldLicense.Bytes;old_sha256=$oldLicense.Sha256;new_bytes=$newLicense.Bytes;new_sha256=$newLicense.Sha256},
            [ordered]@{target='node.exe';prepared=".node-$runtimeToken.prepared";backup='.node.exe.backup-fedcba9876543210fedcba9876543210';old_present=$true;old_bytes=$oldNode.Bytes;old_sha256=$oldNode.Sha256;new_bytes=$newNode.Bytes;new_sha256=$newNode.Sha256}
        )
    }
    Write-JsonAtomic -Path (Join-Path $fixture 'runtime\.node-runtime-transaction.json') -Value $journal -ConfinementRoot (Join-Path $fixture 'runtime')
    $recoveredNode = Ensure-PinnedNodeRuntime -ProjectRoot $fixture -NoDownload
    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $recoveredNode -LicensePath (Join-Path $fixture 'runtime\LICENSE')) 'Interrupted Node runtime publication was not recovered.'
    Assert-Test (-not (Test-Path (Join-Path $fixture 'runtime\.node-runtime-transaction.json'))) 'Recovered Node runtime retained its journal.'
    Assert-Test (@(Get-ChildItem (Join-Path $fixture 'runtime') -Force).Count -eq 2) 'Recovered Node runtime retained transaction debris.'

    # Model process termination after both durable prepared copies but before
    # journal creation. In offline mode, the exact complete token pair is
    # promoted through a fresh context-bound transaction.
    $orphanFixture = New-NodeBootstrapFixture -Name 'pre-journal-complete-orphan'
    $orphanToken = '11111111111111111111111111111111'
    Copy-FileDurable -Source $nodeFixtureSource -Destination (Join-Path $orphanFixture "runtime\.node-$orphanToken.prepared") | Out-Null
    Copy-FileDurable -Source $nodeFixtureLicense -Destination (Join-Path $orphanFixture "runtime\.node-license-$orphanToken.prepared") | Out-Null
    $orphanNode = Ensure-PinnedNodeRuntime -ProjectRoot $orphanFixture -NoDownload
    Assert-Test (Test-PinnedNodeRuntimePair -NodePath $orphanNode -LicensePath (Join-Path $orphanFixture 'runtime\LICENSE')) 'Complete pre-journal Node candidate was not recovered offline.'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $orphanFixture 'runtime') -Force).Count -eq 2) 'Complete pre-journal Node recovery retained reserved debris.'

    # A partial candidate is safe to discard only when the canonical runtime is
    # already valid. This also proves early-return paths cannot ignore debris.
    $validOrphanFixture = New-NodeBootstrapFixture -Name 'pre-journal-partial-valid-canonical'
    Copy-Item -LiteralPath $nodeFixtureSource -Destination (Join-Path $validOrphanFixture 'runtime\node.exe') -Force
    Copy-Item -LiteralPath $nodeFixtureLicense -Destination (Join-Path $validOrphanFixture 'runtime\LICENSE') -Force
    $validOrphanToken = '22222222222222222222222222222222'
    Copy-FileDurable -Source $nodeFixtureSource -Destination (Join-Path $validOrphanFixture "runtime\.node-$validOrphanToken.prepared") | Out-Null
    Ensure-PinnedNodeRuntime -ProjectRoot $validOrphanFixture -NoDownload | Out-Null
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $validOrphanFixture 'runtime') -Force).Count -eq 2) 'Valid canonical runtime retained a partial prepared orphan.'

    # Incomplete offline repair and cross-token candidates remain untouched and
    # fail closed because their intended publication cannot be proven.
    $partialOrphanFixture = New-NodeBootstrapFixture -Name 'pre-journal-partial-damaged-canonical'
    $partialOrphanPath = Join-Path $partialOrphanFixture 'runtime\.node-license-33333333333333333333333333333333.prepared'
    Copy-FileDurable -Source $nodeFixtureLicense -Destination $partialOrphanPath | Out-Null
    $partialRejected = $false
    try { Ensure-PinnedNodeRuntime -ProjectRoot $partialOrphanFixture -NoDownload | Out-Null } catch { $partialRejected = $true }
    Assert-Test $partialRejected 'Incomplete offline pre-journal Node candidate was accepted.'
    Assert-Test (Test-Path -LiteralPath $partialOrphanPath -PathType Leaf) 'Incomplete offline candidate evidence was removed.'

    $ambiguousOrphanFixture = New-NodeBootstrapFixture -Name 'pre-journal-cross-token'
    $ambiguousNode = Join-Path $ambiguousOrphanFixture 'runtime\.node-44444444444444444444444444444444.prepared'
    $ambiguousLicense = Join-Path $ambiguousOrphanFixture 'runtime\.node-license-55555555555555555555555555555555.prepared'
    Copy-FileDurable -Source $nodeFixtureSource -Destination $ambiguousNode | Out-Null
    Copy-FileDurable -Source $nodeFixtureLicense -Destination $ambiguousLicense | Out-Null
    $ambiguousRejected = $false
    try { Ensure-PinnedNodeRuntime -ProjectRoot $ambiguousOrphanFixture -NoDownload | Out-Null } catch { $ambiguousRejected = $true }
    Assert-Test $ambiguousRejected 'Cross-token Node candidates were accepted.'
    Assert-Test ((Test-Path -LiteralPath $ambiguousNode -PathType Leaf) -and (Test-Path -LiteralPath $ambiguousLicense -PathType Leaf)) 'Cross-token rejection removed candidate evidence.'

    $malformedOrphanFixture = New-NodeBootstrapFixture -Name 'pre-journal-malformed-name'
    $malformedOrphanPath = Join-Path $malformedOrphanFixture 'runtime\.node-not-a-token.prepared'
    [IO.File]::WriteAllText($malformedOrphanPath, 'reserved-but-unbound', (New-Object Text.UTF8Encoding($false)))
    $malformedRejected = $false
    try { Ensure-PinnedNodeRuntime -ProjectRoot $malformedOrphanFixture -NoDownload | Out-Null } catch { $malformedRejected = $true }
    Assert-Test $malformedRejected 'Malformed reserved Node candidate name was accepted.'
    Assert-Test (Test-Path -LiteralPath $malformedOrphanPath -PathType Leaf) 'Malformed reserved Node evidence was removed.'

    [IO.File]::WriteAllText((Join-Path $fixture 'runtime\node.exe'), 'truncated-again')
    Assert-Test (-not (Test-PinnedNodeRuntimePair -NodePath (Join-Path $fixture 'runtime\node.exe') -LicensePath (Join-Path $fixture 'runtime\LICENSE'))) 'Truncated Node runtime unexpectedly validated.'
    $noDownloadFailed = $false
    try { Ensure-PinnedNodeRuntime -ProjectRoot $fixture -NoDownload | Out-Null }
    catch { $noDownloadFailed = $true }
    Assert-Test $noDownloadFailed 'Portable no-download mode accepted a damaged runtime.'

    # Package startup must repair a context-bound ZIP/sidecar publication before
    # a later revision validation failure. This models a crash after the
    # journal was durable and proves recovery is not deferred until final build.
    $earlyReleaseRoot = Join-Path $testRoot 'portable-early-recovery'
    New-Item -ItemType Directory -Path $earlyReleaseRoot | Out-Null
    $earlyName = 'early-recovery-test'
    $earlyZipLeaf = "$earlyName.zip"
    $earlyManifestLeaf = "$earlyZipLeaf.manifest.json"
    $earlyToken = '66666666666666666666666666666666'
    $earlyTransaction = '77777777777777777777777777777777'
    $earlyPreparedZip = Join-Path $earlyReleaseRoot ".package-$earlyToken.prepared.zip"
    $earlyPreparedManifest = Join-Path $earlyReleaseRoot ".package-$earlyToken.prepared.manifest.json"
    New-TestZipAndSidecar -Root $earlyReleaseRoot -ZipPath $earlyPreparedZip -ManifestPath $earlyPreparedManifest -ExpectedFile $earlyZipLeaf
    $earlyZipDescriptor = Get-Descriptor $earlyPreparedZip
    $earlyManifestDescriptor = Get-Descriptor $earlyPreparedManifest
    $earlyJournalName = ".$earlyZipLeaf.publication-transaction.json"
    Write-JsonAtomic -Path (Join-Path $earlyReleaseRoot $earlyJournalName) -ConfinementRoot $earlyReleaseRoot -Value ([ordered]@{
        schema_version=2;operation='publish-prepared-file-set';transaction_id=$earlyTransaction;role='portable-zip';items=@(
            [ordered]@{target=$earlyZipLeaf;prepared=[IO.Path]::GetFileName($earlyPreparedZip);backup=".$earlyZipLeaf.backup-$earlyTransaction";old_present=$false;old_bytes=$null;old_sha256=$null;new_bytes=$earlyZipDescriptor.Bytes;new_sha256=$earlyZipDescriptor.Sha256},
            [ordered]@{target=$earlyManifestLeaf;prepared=[IO.Path]::GetFileName($earlyPreparedManifest);backup=".$earlyManifestLeaf.backup-$earlyTransaction";old_present=$false;old_bytes=$null;old_sha256=$null;new_bytes=$earlyManifestDescriptor.Bytes;new_sha256=$earlyManifestDescriptor.Sha256}
        )
    })
    $earlyResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $earlyReleaseRoot -ReleaseName $earlyName
    Assert-Test ($earlyResult.ExitCode -ne 0) 'Portable early-recovery fixture unexpectedly completed packaging.'
    Assert-Test ((Test-Path -LiteralPath (Join-Path $earlyReleaseRoot $earlyZipLeaf) -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $earlyReleaseRoot $earlyManifestLeaf) -PathType Leaf)) "Portable transaction was not recovered before the later failure. Child output: $($earlyResult.Text)"
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $earlyReleaseRoot $earlyJournalName))) 'Portable early recovery retained its journal.'
    $earlyCanonicalZip = Get-Descriptor (Join-Path $earlyReleaseRoot $earlyZipLeaf)
    Assert-Test ($earlyCanonicalZip.Bytes -eq $earlyZipDescriptor.Bytes -and $earlyCanonicalZip.Sha256 -ceq $earlyZipDescriptor.Sha256) 'Portable early recovery changed the prepared ZIP bytes.'

    # A journal for another role substituted under the selected release journal
    # name fails before its unrelated target can be replaced.
    $crossReleaseRoot = Join-Path $testRoot 'portable-cross-context'
    New-Item -ItemType Directory -Path $crossReleaseRoot | Out-Null
    $crossName = 'cross-context-test'
    $crossJournalName = ".$crossName.zip.publication-transaction.json"
    [IO.File]::WriteAllText((Join-Path $crossReleaseRoot 'unrelated.txt'), 'keep-old', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $crossReleaseRoot '.node-88888888888888888888888888888888.prepared'), 'replace-new', (New-Object Text.UTF8Encoding($false)))
    $crossOld = Get-Descriptor (Join-Path $crossReleaseRoot 'unrelated.txt')
    $crossNew = Get-Descriptor (Join-Path $crossReleaseRoot '.node-88888888888888888888888888888888.prepared')
    Write-JsonAtomic -Path (Join-Path $crossReleaseRoot $crossJournalName) -ConfinementRoot $crossReleaseRoot -Value ([ordered]@{
        schema_version=2;operation='publish-prepared-file-set';transaction_id='99999999999999999999999999999999';role='node-runtime';items=@(
            [ordered]@{target='unrelated.txt';prepared='.node-88888888888888888888888888888888.prepared';backup='.unrelated.txt.backup-99999999999999999999999999999999';old_present=$true;old_bytes=$crossOld.Bytes;old_sha256=$crossOld.Sha256;new_bytes=$crossNew.Bytes;new_sha256=$crossNew.Sha256}
        )
    })
    $crossResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $crossReleaseRoot -ReleaseName $crossName
    Assert-Test ($crossResult.ExitCode -ne 0) 'Cross-context portable journal was accepted.'
    Assert-Test ((Get-Content -Raw (Join-Path $crossReleaseRoot 'unrelated.txt')) -ceq 'keep-old') 'Cross-context portable recovery changed an unrelated target.'
    Assert-Test (Test-Path -LiteralPath (Join-Path $crossReleaseRoot '.node-88888888888888888888888888888888.prepared') -PathType Leaf) 'Cross-context portable recovery removed unrelated prepared bytes.'
    Assert-Test (Test-Path -LiteralPath (Join-Path $crossReleaseRoot $crossJournalName) -PathType Leaf) 'Cross-context portable recovery removed its evidence journal.'

    # Without proven rebuildability, partial pre-journal ZIP debris is
    # preserved across a later validation failure. Malformed names also fail
    # closed without losing evidence.
    $zipOrphanRoot = Join-Path $testRoot 'portable-pre-journal-orphan'
    New-Item -ItemType Directory -Path $zipOrphanRoot | Out-Null
    $zipOrphanName = 'zip-orphan-test'
    $zipOrphanPath = Join-Path $zipOrphanRoot '.package-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.prepared.zip'
    New-TestZipAndSidecar -Root $zipOrphanRoot -ZipPath $zipOrphanPath -ManifestPath (Join-Path $zipOrphanRoot '.discard-sidecar.json') -ExpectedFile "$zipOrphanName.zip"
    Remove-Item -LiteralPath (Join-Path $zipOrphanRoot '.discard-sidecar.json') -Force
    $zipOrphanResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $zipOrphanRoot -ReleaseName $zipOrphanName
    Assert-Test ($zipOrphanResult.ExitCode -ne 0) 'Pre-journal ZIP orphan fixture unexpectedly completed packaging.'
    Assert-Test (Test-Path -LiteralPath $zipOrphanPath -PathType Leaf) 'Unrebuildable pre-journal ZIP orphan evidence was removed.'

    $completeOrphanRoot = Join-Path $testRoot 'portable-complete-pre-journal-orphan'
    New-Item -ItemType Directory -Path $completeOrphanRoot | Out-Null
    $completeOrphanName = 'complete-orphan-test'
    $completeToken = 'abababababababababababababababab'
    $completeZip = Join-Path $completeOrphanRoot ".package-$completeToken.prepared.zip"
    $completeManifest = Join-Path $completeOrphanRoot ".package-$completeToken.prepared.manifest.json"
    New-TestZipAndSidecar -Root $completeOrphanRoot -ZipPath $completeZip -ManifestPath $completeManifest -ExpectedFile "$completeOrphanName.zip"
    $completeResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $completeOrphanRoot -ReleaseName $completeOrphanName
    Assert-Test ($completeResult.ExitCode -ne 0) 'Complete pre-journal ZIP fixture unexpectedly completed packaging.'
    Assert-Test ((Test-Path -LiteralPath $completeZip -PathType Leaf) -and (Test-Path -LiteralPath $completeManifest -PathType Leaf)) 'A complete recoverable pre-journal ZIP pair was discarded before rebuildability was proven.'

    # Compress-Archive and sidecar bytes are first written under .writing
    # names. Early preflight preserves a hard-kill pair; proven rebuildability
    # reclaims it and publishes a fresh, fully verified ZIP/sidecar pair.
    $writingPackageRoot=Join-Path $testRoot 'portable-writing-recovery'
    New-Item -ItemType Directory -Path $writingPackageRoot|Out-Null
    $writingStage=Join-Path $writingPackageRoot '.stage-fixture'
    New-Item -ItemType Directory -Path $writingStage|Out-Null
    $writingPayload=Join-Path $writingStage 'payload.txt'
    [IO.File]::WriteAllText($writingPayload,'portable writing recovery',(New-Object Text.UTF8Encoding($false)))
    $writingPayloadHash=(Get-FileHash -LiteralPath $writingPayload -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $writingStage 'checksums.sha256'),"$writingPayloadHash *payload.txt`n",(New-Object Text.UTF8Encoding($false)))
    $writingPackageName='writing-recovery.zip'
    $writingPackageZip=Join-Path $writingPackageRoot $writingPackageName
    $writingPackageManifest="$writingPackageZip.manifest.json"
    $writingPackageToken='cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'
    $partialWritingZip=Join-Path $writingPackageRoot ".package-$writingPackageToken.writing.zip"
    $partialWritingManifest=Join-Path $writingPackageRoot ".package-$writingPackageToken.writing.manifest.json"
    [IO.File]::WriteAllBytes($partialWritingZip,[byte[]](80,75,3))
    [IO.File]::WriteAllText($partialWritingManifest,'{"schema_version":',(New-Object Text.UTF8Encoding($false)))
    $earlyWritingRejected=$false
    try{Repair-PackageZipPublicationContext -ReleaseRoot $writingPackageRoot -ZipPath $writingPackageZip -ManifestPath $writingPackageManifest|Out-Null}catch{$earlyWritingRejected=$true}
    Assert-Test ($earlyWritingRejected -and (Test-Path -LiteralPath $partialWritingZip) -and (Test-Path -LiteralPath $partialWritingManifest)) 'Early portable preflight discarded incomplete writing payloads.'
    $writingPublication=Publish-PackageZipAtomically -ReleaseRoot $writingPackageRoot -StageRoot $writingStage -ZipPath $writingPackageZip -ManifestPath $writingPackageManifest
    Assert-Test ((Test-Path -LiteralPath $writingPublication.ZipPath -PathType Leaf) -and (Test-Path -LiteralPath $writingPublication.ManifestPath -PathType Leaf)) 'Proven portable rebuild did not publish the ZIP/sidecar pair.'
    Assert-Test (-not (Test-Path -LiteralPath $partialWritingZip) -and -not (Test-Path -LiteralPath $partialWritingManifest)) 'Proven portable rebuild retained partial writing payloads.'
    Assert-Test (@(Get-ChildItem -LiteralPath $writingPackageRoot -Force | Where-Object Name -like '.package-*').Count -eq 0) 'Portable writing recovery retained reserved payload debris.'

    $preparedCompatRoot=Join-Path $testRoot 'portable-invalid-prepared-recovery'
    New-Item -ItemType Directory -Path $preparedCompatRoot|Out-Null
    $preparedCompatStage=Join-Path $preparedCompatRoot '.stage-fixture'
    Copy-Item -LiteralPath $writingStage -Destination $preparedCompatStage -Recurse
    $preparedCompatZip=Join-Path $preparedCompatRoot 'prepared-recovery.zip'
    $preparedCompatManifest="$preparedCompatZip.manifest.json"
    $preparedCompatToken='dededededededededededededededede'
    $invalidPreparedZip=Join-Path $preparedCompatRoot ".package-$preparedCompatToken.prepared.zip"
    $invalidPreparedManifest=Join-Path $preparedCompatRoot ".package-$preparedCompatToken.prepared.manifest.json"
    [IO.File]::WriteAllBytes($invalidPreparedZip,[byte[]](80,75,3))
    [IO.File]::WriteAllText($invalidPreparedManifest,'{"schema_version":',(New-Object Text.UTF8Encoding($false)))
    $invalidPreparedEarlyRejected=$false
    try{Repair-PackageZipPublicationContext -ReleaseRoot $preparedCompatRoot -ZipPath $preparedCompatZip -ManifestPath $preparedCompatManifest|Out-Null}catch{$invalidPreparedEarlyRejected=$true}
    Assert-Test ($invalidPreparedEarlyRejected -and (Test-Path -LiteralPath $invalidPreparedZip) -and (Test-Path -LiteralPath $invalidPreparedManifest)) 'Early portable recovery discarded malformed prepared evidence without rebuild proof.'
    $preparedCompatPublication=Publish-PackageZipAtomically -ReleaseRoot $preparedCompatRoot -StageRoot $preparedCompatStage -ZipPath $preparedCompatZip -ManifestPath $preparedCompatManifest
    Assert-Test ((Test-Path -LiteralPath $preparedCompatPublication.ZipPath -PathType Leaf) -and (Test-Path -LiteralPath $preparedCompatPublication.ManifestPath -PathType Leaf)) 'Proven portable rebuild did not replace malformed prepared remnants.'
    Assert-Test (@(Get-ChildItem -LiteralPath $preparedCompatRoot -Force|Where-Object Name -like '.package-*').Count -eq 0) 'Portable malformed-prepared recovery retained reserved debris.'

    $corruptPairRoot = Join-Path $testRoot 'portable-hash-consistent-corrupt-pair'
    New-Item -ItemType Directory -Path $corruptPairRoot | Out-Null
    $corruptName = 'corrupt-pair-test'
    $corruptZip = Join-Path $corruptPairRoot "$corruptName.zip"
    $corruptManifest = "$corruptZip.manifest.json"
    [IO.File]::WriteAllText($corruptZip,'not-a-zip',(New-Object Text.UTF8Encoding($false)))
    $corruptDescriptor = Get-Descriptor $corruptZip
    Write-JsonAtomic -Path $corruptManifest -ConfinementRoot $corruptPairRoot -Value ([ordered]@{schema_version=1;file="$corruptName.zip";bytes=$corruptDescriptor.Bytes;sha256=$corruptDescriptor.Sha256})
    $corruptResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $corruptPairRoot -ReleaseName $corruptName
    Assert-Test ($corruptResult.ExitCode -ne 0 -and $corruptResult.Text -match 'ZIP|archive|central directory') 'A hash-consistent unreadable existing ZIP pair was accepted.'
    Assert-Test ((Get-Descriptor $corruptZip).Sha256 -ceq $corruptDescriptor.Sha256) 'Unreadable ZIP rejection changed canonical bytes.'

    $malformedZipRoot = Join-Path $testRoot 'portable-malformed-orphan'
    New-Item -ItemType Directory -Path $malformedZipRoot | Out-Null
    $malformedZipPath = Join-Path $malformedZipRoot '.package-not-a-token.prepared.zip'
    [IO.File]::WriteAllText($malformedZipPath, 'preserve-me', (New-Object Text.UTF8Encoding($false)))
    $malformedZipResult = Invoke-ExpectedPortablePackagingFailure -OutputDirectory $malformedZipRoot -ReleaseName 'malformed-zip-test'
    Assert-Test ($malformedZipResult.ExitCode -ne 0) 'Malformed reserved ZIP name was accepted.'
    Assert-Test (Test-Path -LiteralPath $malformedZipPath -PathType Leaf) 'Malformed reserved ZIP evidence was removed.'

    Write-Host "Packaging repair tests passed: $passed"
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $testRoot
    }
}
