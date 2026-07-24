Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

function Assert-RepairFixture {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-RepairThrows {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if ($null -eq $caught -or [string]$caught.Exception.Message -notmatch $Pattern) { throw $Message }
}

function New-SltFixture {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Records, [switch]$TailWarning)
    $header = @(
        '7-Zip test fixture',
        '',
        'Path = C:\fixture\manual.chm',
        'Type = Chm'
    )
    if ($TailWarning) { $header += @('WARNINGS:','There are data after the end of archive','Physical Size = 100','Tail Size = 16') }
    return $header + @('','----------') + $Records
}

function New-InventoryFixture {
    return [pscustomobject]@{
        Entries = @(
            [pscustomobject]@{ Path='topic.htm'; Size=[int64]4 },
            [pscustomobject]@{ Path='manual.hhc'; Size=[int64]3 },
            [pscustomobject]@{ Path='manual.hhk'; Size=[int64]3 },
            [pscustomobject]@{ Path='images/pic.png'; Size=[int64]4 }
        )
        Extensions = @('.htm','.html','.hhc','.hhk','.png')
        HtmlCount = 1
    }
}

function Write-InventoryFixtureFiles {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root 'images') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'topic.htm') -Value 'HTML' -NoNewline -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $Root 'manual.hhc') -Value 'TOC' -NoNewline -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $Root 'manual.hhk') -Value 'IDX' -NoNewline -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $Root 'images\pic.png') -Value 'AAAA' -NoNewline -Encoding Ascii
}

$extensions = @('.htm','.html','.hhc','.hhk','.png')
$validListing = New-SltFixture -Records @(
    'Path = topic.htm','Size = 4','Method = LZX','',
    'Path = Manual.hhc','Size = 3','Method = LZX','',
    'Path = search.hhk','Size = 3','Method = LZX','',
    'Path = images\pic.PNG','Size = 4','Method = LZX','',
    'Path = styles\site.css','Size = 7','Method = LZX','','Warnings: 0'
)
$inventory = ConvertFrom-SevenZipSltInventory -Lines $validListing -IndexExtensions $extensions -Context 'valid fixture'
Assert-RepairFixture -Condition ($inventory -isnot [array]) -Message 'The inventory parser leaked intermediate collection output.'
Assert-RepairFixture -Condition ($inventory.HtmlCount -eq 1) -Message 'The inventory did not count HTML inputs exactly.'
Assert-RepairFixture -Condition (@($inventory.Entries).Count -eq 4) -Message 'The inventory did not include HTML, HHC, HHK, and policy image inputs only.'
Assert-RepairFixture -Condition (@($inventory.Entries | Where-Object Path -ceq 'images/pic.PNG').Count -eq 1) -Message 'The inventory did not normalize separators while preserving archive path case.'

$invalidListings = @(
    @{ Pattern='rooted'; Lines=(New-SltFixture -Records @('Path = C:\escape.htm','Size = 1','')) },
    @{ Pattern='traversal'; Lines=(New-SltFixture -Records @('Path = docs\..\escape.htm','Size = 1','')) },
    @{ Pattern='duplicate'; Lines=(New-SltFixture -Records @('Path = topic.htm','Size = 1','','Path = topic.htm','Size = 1','')) },
    @{ Pattern='case collision'; Lines=(New-SltFixture -Records @('Path = Topic.htm','Size = 1','','Path = topic.htm','Size = 1','')) },
    @{ Pattern='invalid archive path'; Lines=(New-SltFixture -Records @('Path = bad<name>.htm','Size = 1','')) },
    @{ Pattern='size'; Lines=(New-SltFixture -Records @('Path = topic.htm','Size = -1','')) },
    @{ Pattern='without Path and Size'; Lines=(New-SltFixture -Records @('Path = topic.htm','Method = LZX','')) }
    @{ Pattern='unsupported archive-listing warning'; Lines=(New-SltFixture -Records @('Path = topic.htm','Size = 1','','Warnings: 1')) }
)
foreach ($case in $invalidListings) {
    Assert-RepairThrows -Action { ConvertFrom-SevenZipSltInventory -Lines $case.Lines -IndexExtensions $extensions -Context 'invalid fixture' | Out-Null } -Pattern $case.Pattern -Message "The inventory parser accepted an invalid $($case.Pattern) record."
}
$tailWarningListing = New-SltFixture -TailWarning -Records @('Path = topic.htm','Size = 1','','Warnings: 1')
$tailWarningInventory = ConvertFrom-SevenZipSltInventory -Lines $tailWarningListing -IndexExtensions $extensions -Context 'tail warning fixture'
Assert-RepairFixture -Condition ($tailWarningInventory.HtmlCount -eq 1) -Message 'The exact bounded CHM tail warning was not accepted.'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempBase ('mql5-chm-index-maintenance-repairs-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $closureInventory = New-InventoryFixture
    $positiveClosureTimeoutSeconds = 10
    $candidateA = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'closure-a')
    Write-InventoryFixtureFiles -Root $candidateA.FullName
    $stateA = Get-ExtractionClosureState -Path $candidateA.FullName -Inventory $closureInventory
    Assert-RepairFixture -Condition $stateA.Complete -Message 'A complete exact extraction closure was rejected.'
    Set-Content -LiteralPath (Join-Path $candidateA.FullName 'unexpected.html') -Value 'X' -NoNewline -Encoding Ascii
    $unexpectedState = Get-ExtractionClosureState -Path $candidateA.FullName -Inventory $closureInventory
    Assert-RepairFixture -Condition (-not $unexpectedState.Complete -and [string]$unexpectedState.Reason -match 'unexpected') -Message 'An unexpected index input was accepted into the extraction closure.'
    Remove-Item -LiteralPath (Join-Path $candidateA.FullName 'unexpected.html') -Force
    Set-Content -LiteralPath (Join-Path $candidateA.FullName 'images\pic.png') -Value 'BBBB' -NoNewline -Encoding Ascii
    $stateB = Get-ExtractionClosureState -Path $candidateA.FullName -Inventory $closureInventory
    Assert-RepairFixture -Condition ($stateB.Complete -and $stateA.Digest -cne $stateB.Digest) -Message 'A same-size content rewrite did not change the closure digest.'

    $htmlOnly = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'html-only')
    Set-Content -LiteralPath (Join-Path $htmlOnly.FullName 'topic.htm') -Value 'HTML' -NoNewline -Encoding Ascii
    Assert-RepairThrows -Action { Wait-ExtractionStable -Path $htmlOnly.FullName -Inventory $closureInventory -TimeoutSeconds 1 -StablePolls 2 -PollMilliseconds 10 | Out-Null } -Pattern 'did not reach' -Message 'HTML-only extraction was incorrectly accepted as complete.'
    Write-InventoryFixtureFiles -Root $htmlOnly.FullName
    $stable = Wait-ExtractionStable -Path $htmlOnly.FullName -Inventory $closureInventory -TimeoutSeconds $positiveClosureTimeoutSeconds -StablePolls 2 -PollMilliseconds 10
    Assert-RepairFixture -Condition ($stable.Complete -and $stable.HtmlCount -eq 1) -Message 'The exact input closure did not reach a stable state.'

    $delayed = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'delayed-inputs')
    Set-Content -LiteralPath (Join-Path $delayed.FullName 'topic.htm') -Value 'HTML' -NoNewline -Encoding Ascii
    $delayWriterPath = Join-Path $fixtureRoot 'write-delayed-inputs.ps1'
    [IO.File]::WriteAllText($delayWriterPath, @'
param([string]$Root)
Start-Sleep -Milliseconds 100
[IO.File]::WriteAllText((Join-Path $Root 'manual.hhc'),'TOC',[Text.Encoding]::ASCII)
Start-Sleep -Milliseconds 100
[IO.File]::WriteAllText((Join-Path $Root 'manual.hhk'),'IDX',[Text.Encoding]::ASCII)
Start-Sleep -Milliseconds 100
[IO.Directory]::CreateDirectory((Join-Path $Root 'images')) | Out-Null
[IO.File]::WriteAllText((Join-Path $Root 'images\pic.png'),'AAAA',[Text.Encoding]::ASCII)
'@, (New-Object Text.UTF8Encoding($false)))
    $delayedWriter = Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -ArgumentList @('-NoProfile','-File',$delayWriterPath,$delayed.FullName) -PassThru -WindowStyle Hidden
    try {
        $delayedStable = Wait-ExtractionStable -Path $delayed.FullName -Inventory $closureInventory -TimeoutSeconds $positiveClosureTimeoutSeconds -StablePolls 3 -PollMilliseconds 20
        $delayedWriter.WaitForExit()
        Assert-RepairFixture -Condition ($delayedWriter.ExitCode -eq 0 -and $delayedStable.Complete) -Message 'Polling did not wait for delayed HHC, HHK, and image inputs.'
    } finally {
        if (-not $delayedWriter.HasExited) { $delayedWriter.Kill(); $delayedWriter.WaitForExit() }
        $delayedWriter.Dispose()
    }

    $snapshotRoot = Join-Path $fixtureRoot 'snapshots'
    New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
    $snapshot = New-VerifiedExtractionSnapshot -CandidatePath $htmlOnly.FullName -SnapshotRoot $snapshotRoot -Inventory $closureInventory -TimeoutSeconds $positiveClosureTimeoutSeconds -StablePolls 2 -PollMilliseconds 10
    Set-Content -LiteralPath (Join-Path $htmlOnly.FullName 'topic.htm') -Value 'LATE' -NoNewline -Encoding Ascii
    Assert-RepairFixture -Condition ((Get-Content -LiteralPath (Join-Path $snapshot.Path 'topic.htm') -Raw) -ceq 'HTML') -Message 'A late source write contaminated the verified extraction snapshot.'
    Set-Content -LiteralPath (Join-Path $htmlOnly.FullName 'topic.htm') -Value 'HTML' -NoNewline -Encoding Ascii
    $raceRejected = $false
    try {
        New-VerifiedExtractionSnapshot -CandidatePath $htmlOnly.FullName -SnapshotRoot $snapshotRoot -Inventory $closureInventory -TimeoutSeconds $positiveClosureTimeoutSeconds -StablePolls 2 -PollMilliseconds 10 -AfterCopyHook {
            param($source,$target,$entry)
            if ([string]$entry.Path -ceq 'images/pic.png') {
                Set-Content -LiteralPath (Join-Path $htmlOnly.FullName 'topic.htm') -Value 'RACE' -NoNewline -Encoding Ascii
            }
        } | Out-Null
    } catch { $raceRejected = [string]$_.Exception.Message -match 'changed while' }
    Assert-RepairFixture -Condition $raceRejected -Message 'A same-size source mutation during snapshot copying was not rejected.'

    $nativeHelper = Join-Path $fixtureRoot 'native timeout helper.ps1'
    [IO.File]::WriteAllText($nativeHelper, @'
param([string]$Mode,[string]$OutputPath)
if ($Mode -ceq 'sleep') { Start-Sleep -Seconds 30; exit 0 }
[IO.File]::WriteAllText($OutputPath,'argument-preserved',[Text.Encoding]::UTF8)
'@, (New-Object Text.UTF8Encoding($false)))
    $hostExecutable = (Get-Process -Id $PID).Path
    $timeoutTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-RepairThrows -Action {
        Invoke-NativeProcessWithTimeout -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'sleep','unused') -TimeoutSeconds 1 | Out-Null
    } -Pattern 'deadline' -Message 'A hung native extractor was not terminated at its deadline.'
    Assert-RepairFixture -Condition ($timeoutTimer.Elapsed.TotalSeconds -lt 8) -Message 'Native extraction timeout did not return promptly.'
    $argumentOutput = Join-Path $fixtureRoot 'path containing spaces\argument output.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $argumentOutput) | Out-Null
    Invoke-NativeProcessWithTimeout -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'write',$argumentOutput) -TimeoutSeconds 10 | Out-Null
    Assert-RepairFixture -Condition ((Get-Content -LiteralPath $argumentOutput -Raw) -ceq 'argument-preserved') -Message 'Native extractor argument quoting corrupted a path containing spaces.'

    $projectRoot = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'project')
    $workRoot = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'work')
    New-Item -ItemType Directory -Path (Join-Path $workRoot.FullName 'sources') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workRoot.FullName 'extracted') | Out-Null
    Set-Content -LiteralPath (Join-Path $workRoot.FullName 'sources\manual.chm') -Value 'fixture' -NoNewline -Encoding Ascii
    $sourceRecord = [pscustomobject]@{ Id='manual'; FileName='manual.chm'; TopicCount=1 }
    $script:hhCandidate = $null; $script:sevenZipCandidate = $null
    $originalInventoryCommand = (Get-Command Get-ChmIndexInputInventory -CommandType Function).ScriptBlock
    $originalHtmlHelpCommand = (Get-Command Invoke-HtmlHelpExtraction -CommandType Function).ScriptBlock
    $originalSevenZipCommand = (Get-Command Invoke-SevenZipExtraction -CommandType Function).ScriptBlock
    try {
        function Get-ChmIndexInputInventory { param([string]$ProjectRoot,[string]$SevenZip,[string]$ChmPath) return (New-InventoryFixture) }
        function Invoke-HtmlHelpExtraction { param([string]$HtmlHelpPath,[string]$Destination,[string]$ArchivePath,[int]$TimeoutSeconds) $script:hhCandidate=$Destination; New-Item -ItemType Directory -Path $Destination -Force | Out-Null; throw 'simulated hh failure' }
        function Invoke-SevenZipExtraction { param([string]$SevenZip,[string]$Destination,[string]$ArchivePath,[string]$SourceName,[int]$TimeoutSeconds) $script:sevenZipCandidate=$Destination; New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Write-InventoryFixtureFiles -Root $Destination }
        $count = Invoke-ChmExtraction -ProjectRoot $projectRoot.FullName -WorkingRoot $workRoot.FullName -SourceRecord $sourceRecord -SevenZip 'fixture-7z.exe' -ExtractionTimeoutSeconds 10 -HhTimeoutSeconds 10
        $published = Join-Path $workRoot.FullName 'extracted\manual'
        Assert-RepairFixture -Condition ($count -eq 1 -and (Test-Path -LiteralPath (Join-Path $published 'manual.hhc') -PathType Leaf)) -Message 'The verified 7-Zip fallback was not published.'
        Assert-RepairFixture -Condition ($script:hhCandidate -cne $script:sevenZipCandidate -and $published -cne $script:hhCandidate -and $published -cne $script:sevenZipCandidate) -Message 'hh.exe, 7-Zip, and published extraction directories were not isolated.'

        Remove-SafeDirectory -ConfinementRoot (Join-Path $workRoot.FullName 'extracted') -Path $published
        function Invoke-SevenZipExtraction { param([string]$SevenZip,[string]$Destination,[string]$ArchivePath,[string]$SourceName,[int]$TimeoutSeconds) New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Set-Content -LiteralPath (Join-Path $Destination 'topic.htm') -Value 'HTML' -NoNewline -Encoding Ascii; throw 'simulated 7-Zip failure' }
        Assert-RepairThrows -Action { Invoke-ChmExtraction -ProjectRoot $projectRoot.FullName -WorkingRoot $workRoot.FullName -SourceRecord $sourceRecord -SevenZip 'fixture-7z.exe' -ExtractionTimeoutSeconds 10 -HhTimeoutSeconds 10 | Out-Null } -Pattern 'simulated 7-Zip failure' -Message 'A failed fallback did not fail extraction.'
        Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath $published)) -Message 'A failed fallback exposed a partial destination.'
    } finally {
        Set-Item -Path Function:Get-ChmIndexInputInventory -Value $originalInventoryCommand
        Set-Item -Path Function:Invoke-HtmlHelpExtraction -Value $originalHtmlHelpCommand
        Set-Item -Path Function:Invoke-SevenZipExtraction -Value $originalSevenZipCommand
    }

    $hashA = 'a' * 64; $hashB = 'b' * 64; $corpusA = 'c' * 64; $policyA = 'd' * 64; $policyB = 'e' * 64
    function New-RebuildFixture {
        param([string]$IndexRevision=$hashA,[string]$CorpusRevision=$corpusA,[int]$SchemaVersion=$script:ManifestSchemaVersion,[string]$Contract=$script:IndexContract,[string]$Policy=$policyA)
        return [pscustomobject]@{
            IndexRevision=$IndexRevision; CorpusRevision=$CorpusRevision; ManifestSchemaVersion=$SchemaVersion
            Manifest=[pscustomobject]@{ index_contract=$Contract; assets=[pscustomobject]@{ policy_sha256=$Policy } }
        }
    }
    $base = New-RebuildFixture
    Assert-RepairFixture -Condition (Assert-DeterministicRebuildResult -BaseRevision $base -CandidateRevision (New-RebuildFixture)) -Message 'Equal same-input rebuild was not recognized as already current.'
    Assert-RepairThrows -Action { Assert-DeterministicRebuildResult -BaseRevision $base -CandidateRevision (New-RebuildFixture -IndexRevision $hashB) | Out-Null } -Pattern 'determin' -Message 'Same-input index hash drift was not rejected.'
    $script:postDeterminismSemanticHelperReached=$false
    $originalTopicChangeHelper=(Get-Item Function:\Get-TopicChangeReport).ScriptBlock
    try{
        function Get-TopicChangeReport{$script:postDeterminismSemanticHelperReached=$true;throw 'semantic helper should not run'}
        Assert-RepairThrows -Action {
            Assert-StagedReportMatchesVerification -Report ([pscustomobject]@{}) -BaseRevision $base -CandidateRevision (New-RebuildFixture -IndexRevision $hashB) -BaseInspection ([pscustomobject]@{}) -CandidateInspection ([pscustomobject]@{})|Out-Null
        } -Pattern 'determin' -Message 'Shared Apply/stage-recovery acceptance did not reject same-input drift.'
    }finally{Set-Item Function:\Get-TopicChangeReport -Value $originalTopicChangeHelper}
    Assert-RepairFixture -Condition (-not $script:postDeterminismSemanticHelperReached) -Message 'Shared semantic acceptance performed post-gate work before rejecting deterministic drift.'
    Assert-RepairFixture -Condition (-not (Assert-DeterministicRebuildResult -BaseRevision $base -CandidateRevision (New-RebuildFixture -CorpusRevision ('f' * 64)))) -Message 'A corpus change was incorrectly treated as deterministic drift.'
    Assert-RepairFixture -Condition (-not (Assert-DeterministicRebuildResult -BaseRevision $base -CandidateRevision (New-RebuildFixture -Policy $policyB))) -Message 'A policy change was incorrectly treated as deterministic drift.'
    Assert-RepairFixture -Condition (-not (Assert-DeterministicRebuildResult -BaseRevision (New-RebuildFixture -Contract 'mql5-chm-index-v3-assets-v1') -CandidateRevision (New-RebuildFixture))) -Message 'A contract upgrade was incorrectly treated as deterministic drift.'
    Assert-RepairFixture -Condition (-not (Assert-DeterministicRebuildResult -BaseRevision (New-RebuildFixture -SchemaVersion $script:LegacyManifestSchemaVersion) -CandidateRevision (New-RebuildFixture))) -Message 'A schema upgrade was incorrectly treated as deterministic drift.'

    $activationBase = [pscustomobject]@{
        IndexRevision=$hashA
        CorpusRevision=$corpusA
        DatabasePath='base.sqlite'
    }
    $activationCandidate = [pscustomobject]@{
        IndexRevision=$hashB
        CorpusRevision=('f' * 64)
        DatabasePath='candidate.sqlite'
        Root='candidate-root'
    }
    $script:activationReport = [pscustomobject]@{
        base_index_revision=$hashA
        base_corpus_revision=$corpusA
        corpus_revision=$activationCandidate.CorpusRevision
    }
    $script:activationRequiresReduction = $false
    $script:activationRevisionFlags = $null
    $script:activationInspections = @()
    $script:activationResolveCalls = 0
    $originalAssertRevision = (Get-Item Function:\Assert-Revision).ScriptBlock
    $originalAssertStagedRevisionReport = (Get-Item Function:\Assert-StagedRevisionReport).ScriptBlock
    $originalResolveNodeExecutable = (Get-Item Function:\Resolve-NodeExecutable).ScriptBlock
    $originalInvokeDatabaseInspection = (Get-Item Function:\Invoke-DatabaseInspection).ScriptBlock
    $originalAssertStagedReportMatchesVerification = (Get-Item Function:\Assert-StagedReportMatchesVerification).ScriptBlock
    try {
        function Assert-Revision {
            param(
                [string]$ProjectRoot,
                [string]$Revision,
                [string]$IdentityMode,
                [switch]$RequireCurrent,
                [switch]$RequireCurrentSources,
                [switch]$RequireCurrentPolicy
            )
            $script:activationRevisionFlags = [pscustomobject]@{
                RequireCurrent=[bool]$RequireCurrent
                RequireCurrentSources=[bool]$RequireCurrentSources
                RequireCurrentPolicy=[bool]$RequireCurrentPolicy
            }
            return $activationCandidate
        }
        function Assert-StagedRevisionReport {
            param([string]$Path,[string]$ExpectedRevision)
            return $script:activationReport
        }
        function Resolve-NodeExecutable {
            param([string]$ProjectRoot)
            $script:activationResolveCalls++
            return 'fixture-node.exe'
        }
        function Invoke-DatabaseInspection {
            param([string]$NodePath,[string]$DatabasePath,[switch]$RequireAssets)
            $script:activationInspections += [pscustomobject]@{
                NodePath=$NodePath
                DatabasePath=$DatabasePath
                RequireAssets=[bool]$RequireAssets
            }
            return [pscustomobject]@{ DatabasePath=$DatabasePath }
        }
        function Assert-StagedReportMatchesVerification {
            param(
                [object]$Report,
                [object]$BaseRevision,
                [object]$CandidateRevision,
                [object]$BaseInspection,
                [object]$CandidateInspection,
                [switch]$AcceptAssetReduction
            )
            if ($script:activationRequiresReduction -and -not $AcceptAssetReduction) {
                throw 'The candidate reduces cataloged/exposed image or exposed-occurrence coverage. Review the stage report and retry with -AcceptAssetReduction.'
            }
            return [pscustomobject]@{ TopicChanges=[pscustomobject]@{ changed_count=1 } }
        }

        $script:activationReport = [pscustomobject]@{
            base_index_revision=('0' * 64)
            base_corpus_revision=$corpusA
            corpus_revision=$activationCandidate.CorpusRevision
        }
        Assert-RepairThrows -Action {
            Assert-CandidateActivationAccepted -ProjectRoot $fixtureRoot -CandidateIndexRevision $hashB -BaseRevision $activationBase | Out-Null
        } -Pattern 'different active base' -Message 'Shared candidate acceptance did not reject a report staged against a stale active base.'

        $script:activationReport = [pscustomobject]@{
            base_index_revision=$hashA
            base_corpus_revision=$corpusA
            corpus_revision=$activationCandidate.CorpusRevision
        }
        $script:activationRequiresReduction = $true
        Assert-RepairThrows -Action {
            Assert-CandidateActivationAccepted -ProjectRoot $fixtureRoot -CandidateIndexRevision $hashB -BaseRevision $activationBase | Out-Null
        } -Pattern 'AcceptAssetReduction' -Message 'Shared candidate acceptance allowed an asset reduction without explicit review.'

        $script:activationInspections = @()
        $resolveCallsBeforeVerifiedPath = $script:activationResolveCalls
        $acceptedActivation = Assert-CandidateActivationAccepted `
            -ProjectRoot $fixtureRoot `
            -CandidateIndexRevision $hashB `
            -BaseRevision $activationBase `
            -NodePath 'verified-node.exe' `
            -AcceptAssetReduction `
            -RequireCurrentSources `
            -RequireCurrentPolicy
        Assert-RepairFixture -Condition (
            [string]$acceptedActivation.Candidate.IndexRevision -ceq $hashB -and
            [bool]$script:activationRevisionFlags.RequireCurrent -and
            [bool]$script:activationRevisionFlags.RequireCurrentSources -and
            [bool]$script:activationRevisionFlags.RequireCurrentPolicy
        ) -Message 'Shared candidate acceptance did not preserve strict candidate identity checks.'
        Assert-RepairFixture -Condition (
            @($script:activationInspections).Count -eq 2 -and
            $script:activationResolveCalls -eq $resolveCallsBeforeVerifiedPath -and
            [string]$script:activationInspections[0].NodePath -ceq 'verified-node.exe' -and
            [string]$script:activationInspections[0].DatabasePath -ceq 'base.sqlite' -and
            -not [bool]$script:activationInspections[0].RequireAssets -and
            [string]$script:activationInspections[1].NodePath -ceq 'verified-node.exe' -and
            [string]$script:activationInspections[1].DatabasePath -ceq 'candidate.sqlite' -and
            [bool]$script:activationInspections[1].RequireAssets
        ) -Message 'Shared candidate acceptance did not bind the preverified Node path while freshly inspecting the active and candidate databases.'
    } finally {
        Set-Item Function:\Assert-Revision -Value $originalAssertRevision
        Set-Item Function:\Assert-StagedRevisionReport -Value $originalAssertStagedRevisionReport
        Set-Item Function:\Resolve-NodeExecutable -Value $originalResolveNodeExecutable
        Set-Item Function:\Invoke-DatabaseInspection -Value $originalInvokeDatabaseInspection
        Set-Item Function:\Assert-StagedReportMatchesVerification -Value $originalAssertStagedReportMatchesVerification
    }

    $rebuildText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Rebuild-Index.ps1') -Raw
    $guardIndex = $rebuildText.IndexOf('Assert-DeterministicRebuildResult',[StringComparison]::Ordinal)
    $stageIndex = $rebuildText.IndexOf('Start-RevisionStageInstall',[StringComparison]::Ordinal)
    Assert-RepairFixture -Condition ($guardIndex -ge 0 -and $stageIndex -gt $guardIndex) -Message 'The rebuild determinism guard is not wired before staging.'

    # Execute the real rebuild control flow against a mocked maintenance
    # boundary. Any path past the determinism gate deliberately mutates a
    # protected status file, so byte-identical snapshots prove rejection
    # occurs before revision/checksum/report/status/release state changes.
    $probeRoot = Join-Path $fixtureRoot 'determinism integration probe'
    $probeScripts = Join-Path $probeRoot 'scripts'
    $probeProject = Join-Path $probeRoot 'project'
    foreach ($directory in @($probeScripts,$probeProject,(Join-Path $probeProject 'data'),(Join-Path $probeProject 'maintenance'),(Join-Path $probeProject 'revisions\base'),(Join-Path $probeProject 'revisions\candidate'),(Join-Path $probeProject 'release'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Rebuild-Index.ps1') -Destination (Join-Path $probeScripts 'Rebuild-Index.ps1')
    foreach ($relative in @('data\active.json','maintenance\update-status.json','revisions\base\manifest.json','revisions\candidate\stage-report.json','release\package.zip','release\package.zip.manifest.json','checksums.sha256')) {
        [IO.File]::WriteAllText((Join-Path $probeProject $relative),"protected-$relative`n",(New-Object Text.UTF8Encoding($false)))
    }
    $tokens=$null;$parseErrors=$null
    $indexAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'IndexMaintenance.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Could not parse IndexMaintenance.ps1 for the determinism integration probe.'}
    $determinismAst=$indexAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-DeterministicRebuildResult'},$true)
    if($null -eq $determinismAst){throw 'Determinism guard definition is missing.'}
    $mockMaintenance = @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:ManifestSchemaVersion=3
$script:IndexContract='mql5-chm-index-v3-assets-v2'
function Resolve-FullPath { param([string]$Path,[switch]$MustExist,[string]$PathType) return [IO.Path]::GetFullPath($Path) }
function Assert-NoReparsePoint { param([string]$Root,[string]$Path) }
function Enter-ExclusiveFileLock { param([string]$Path,[string]$IdentityRoot,[int]$TimeoutSeconds) $lease=[pscustomobject]@{};$lease|Add-Member ScriptMethod Dispose {};return $lease }
function Repair-InterruptedMaintenanceArtifacts { param([string]$ProjectRoot) }
function Convert-DevelopmentLegacyActivePointerForStageRecovery { param([string]$ProjectRoot) return $null }
function Repair-InterruptedRevisionStageInstall { param([string]$ProjectRoot) return [pscustomobject]@{State='none'} }
function Get-RevisionTransition { param([string]$ProjectRoot,[switch]$AllowMissing) return $null }
function Assert-MaintenancePackageIntegrity { param([string]$ProjectRoot,[switch]$AllowPendingTransition) return $true }
function Get-ActiveRevisionPointer { param([string]$ProjectRoot,[switch]$AllowMissing) return [pscustomobject]@{schema_version=2;active_revision=('a'*64)} }
function Assert-NoPendingRevisionTransition { param([string]$ProjectRoot) }
function Assert-ManifestAndCorpus { param([string]$ProjectRoot) return [pscustomobject]@{IndexRevision=('a'*64);CorpusRevision=('c'*64);ManifestSchemaVersion=3;Manifest=[pscustomobject]@{index_contract='mql5-chm-index-v3-assets-v2';assets=[pscustomobject]@{policy_sha256=('d'*64)}}} }
function Get-SourceRecordsFromActiveRevision { param([string]$ProjectRoot) return @([pscustomobject]@{Id='fixture'}) }
function New-RevisionCandidate { param([string]$ProjectRoot,[object[]]$SourceRecords,[string]$WorkingRoot,[int]$ExtractionTimeoutSeconds,[int]$HhTimeoutSeconds) return [pscustomobject]@{IndexRevision=('b'*64);CorpusRevision=('c'*64);ManifestSchemaVersion=3;Manifest=[pscustomobject]@{index_contract='mql5-chm-index-v3-assets-v2';assets=[pscustomobject]@{policy_sha256=('d'*64)}};Inspection=[pscustomobject]@{}} }
function Resolve-NodeExecutable { param([string]$ProjectRoot) [IO.File]::AppendAllText((Join-Path $ProjectRoot 'maintenance\update-status.json'),'MUTATED');throw 'determinism gate was bypassed' }
function Remove-SafeDirectory { param([string]$ConfinementRoot,[string]$Path) }
'@
    $mockMaintenance += "`n" + $determinismAst.Extent.Text + "`n"
    [IO.File]::WriteAllText((Join-Path $probeScripts 'IndexMaintenance.ps1'),$mockMaintenance,(New-Object Text.UTF8Encoding($false)))
    $beforeProbe = @(
        Get-ChildItem -LiteralPath $probeProject -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($probeProject.Length).Replace('\','/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    )
    $probeResult = Invoke-NativeCapture -FilePath (Get-Process -Id $PID).Path -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $probeScripts 'Rebuild-Index.ps1'),'-Stage','-ProjectRoot',$probeProject,'-ExtractionTimeoutSeconds','10','-HhTimeoutSeconds','10')
    $afterProbe = @(
        Get-ChildItem -LiteralPath $probeProject -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($probeProject.Length).Replace('\','/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    )
    Assert-RepairFixture -Condition ($probeResult.ExitCode -ne 0 -and $probeResult.Text -match 'Deterministic rebuild failure') -Message "Executed rebuild path did not reject same-input index drift. $($probeResult.Text)"
    Assert-RepairFixture -Condition (($beforeProbe -join "`n") -ceq ($afterProbe -join "`n")) -Message 'Rejected deterministic drift changed protected revision/checksum/report/status/release state.'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $fixtureRoot }
}

Write-Host 'Index maintenance repair fixtures passed.'
