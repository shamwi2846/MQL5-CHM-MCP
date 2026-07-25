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
param(
    [string]$Mode,
    [string]$OutputPath,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$RemainingArguments
)
if ($Mode -ceq 'sleep') { Start-Sleep -Seconds 30; exit 0 }
if ($Mode -ceq 'spawn-child') {
    $escapedOutput = $OutputPath.Replace("'","''")
    $childCommand = "Start-Sleep -Seconds 2; [IO.File]::WriteAllText('$escapedOutput','descendant-survived',[Text.Encoding]::UTF8)"
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-EncodedCommand',$encodedChild) -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 30
    exit 0
}
if ($Mode -ceq 'capture') {
    [Console]::Out.WriteLine('captured-stdout')
    [Console]::Error.WriteLine('captured-stderr')
    exit 7
}
if ($Mode -ceq 'cwd') {
    [Console]::Out.Write([Environment]::CurrentDirectory)
    exit 0
}
if ($Mode -ceq 'arguments') {
    $values = @($OutputPath) + @($RemainingArguments)
    $json = ConvertTo-Json -InputObject ([pscustomobject]@{ arguments=[string[]]$values }) -Compress
    [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    exit 0
}
[IO.File]::WriteAllText($OutputPath,'argument-preserved',[Text.Encoding]::UTF8)
'@, (New-Object Text.UTF8Encoding($false)))
    $hostExecutable = (Get-Process -Id $PID).Path
    $timeoutTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-RepairThrows -Action {
        Invoke-NativeProcessWithTimeout -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'sleep','unused') -TimeoutSeconds 1 | Out-Null
    } -Pattern 'deadline' -Message 'A hung native extractor was not terminated at its deadline.'
    Assert-RepairFixture -Condition ($timeoutTimer.Elapsed.TotalSeconds -lt 8) -Message 'Native extraction timeout did not return promptly.'
    $descendantOutput = Join-Path $fixtureRoot 'timed-out-descendant.txt'
    Assert-RepairThrows -Action {
        Invoke-NativeProcessWithTimeout -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'spawn-child',$descendantOutput) -TimeoutSeconds 1 | Out-Null
    } -Pattern 'deadline' -Message 'A native process tree did not report its deadline.'
    Start-Sleep -Milliseconds 2500
    Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath $descendantOutput)) -Message 'A timed-out native process left a descendant running after cleanup began.'

    Assert-RepairThrows -Action {
        Invoke-NativeCapture -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'sleep','unused') -TimeoutSeconds 1 | Out-Null
    } -Pattern 'deadline' -Message 'Invoke-NativeCapture did not enforce its requested deadline.'
    Assert-RepairThrows -Action {
        Invoke-NativeChecked -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'sleep','unused') -TimeoutSeconds 1
    } -Pattern 'deadline' -Message 'Invoke-NativeChecked did not enforce its requested deadline.'
    $nativeNode = Resolve-NodeExecutable -ProjectRoot (Split-Path -Parent $PSScriptRoot)
    $inheritedHandleOutput = Join-Path $fixtureRoot 'inherited-handle-descendant.txt'
    $inheritedHandleReady = Join-Path $fixtureRoot 'inherited-handle-descendant.ready'
    $escapedInheritedHandleOutput = ConvertTo-Json -InputObject $inheritedHandleOutput -Compress
    $escapedInheritedHandleReady = ConvertTo-Json -InputObject $inheritedHandleReady -Compress
    $inheritedHandleChildScript = "const fs=require('node:fs');fs.writeFileSync($escapedInheritedHandleReady,'ready');setTimeout(()=>fs.writeFileSync($escapedInheritedHandleOutput,'descendant-survived'),2000);setTimeout(()=>{},5000)"
    $escapedInheritedHandleChildScript = ConvertTo-Json -InputObject $inheritedHandleChildScript -Compress
    $inheritedHandleScript = "const fs=require('node:fs');const {spawn}=require('node:child_process');const child=spawn(process.execPath,['-e',$escapedInheritedHandleChildScript],{detached:true,stdio:['ignore',1,2]});child.unref();const wait=new Int32Array(new SharedArrayBuffer(4));const deadline=Date.now()+2000;while(!fs.existsSync($escapedInheritedHandleReady)&&Date.now()<deadline){Atomics.wait(wait,0,0,10)}if(!fs.existsSync($escapedInheritedHandleReady)){try{process.kill(child.pid)}catch{};throw new Error('detached inherited-handle child did not become ready')}"
    $inheritedHandleTimer = [Diagnostics.Stopwatch]::StartNew()
    # Hosted Windows PowerShell 5.1 can spend more than one second starting the
    # trusted bootstrap. The elapsed assertion below still requires prompt exit.
    $inheritedHandleResult = Invoke-NativeCapture -FilePath $nativeNode -Arguments @('--input-type=commonjs','-e',$inheritedHandleScript) -TimeoutSeconds 5
    Assert-RepairFixture -Condition (
        $inheritedHandleResult.ExitCode -eq 0 -and $inheritedHandleTimer.Elapsed.TotalSeconds -lt 4
    ) -Message 'A parent-exited native descendant retained inherited output handles after contained cleanup.'
    Assert-RepairFixture -Condition (
        (Test-Path -LiteralPath $inheritedHandleReady -PathType Leaf) -and
        (Get-Content -LiteralPath $inheritedHandleReady -Raw) -ceq 'ready'
    ) -Message 'The inherited-handle containment probe did not prove its detached child reached readiness.'
    Start-Sleep -Milliseconds 2500
    Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath $inheritedHandleOutput)) -Message 'A parent-exited native descendant survived its containment deadline.'

    $successfulDetachedOutput = Join-Path $fixtureRoot 'successful-detached-descendant.txt'
    $successfulDetachedReady = Join-Path $fixtureRoot 'successful-detached-descendant.ready'
    $escapedSuccessfulDetachedOutput = ConvertTo-Json -InputObject $successfulDetachedOutput -Compress
    $escapedSuccessfulDetachedReady = ConvertTo-Json -InputObject $successfulDetachedReady -Compress
    $successfulDetachedChildScript = "const fs=require('node:fs');fs.writeFileSync($escapedSuccessfulDetachedReady,'ready');setTimeout(()=>fs.writeFileSync($escapedSuccessfulDetachedOutput,'descendant-survived'),2000);setTimeout(()=>{},5000)"
    $escapedSuccessfulDetachedChildScript = ConvertTo-Json -InputObject $successfulDetachedChildScript -Compress
    $successfulDetachedParentScript = "const fs=require('node:fs');const {spawn}=require('node:child_process');const child=spawn(process.execPath,['-e',$escapedSuccessfulDetachedChildScript],{detached:true,stdio:'ignore'});child.unref();const wait=new Int32Array(new SharedArrayBuffer(4));const deadline=Date.now()+2000;while(!fs.existsSync($escapedSuccessfulDetachedReady)&&Date.now()<deadline){Atomics.wait(wait,0,0,10)}if(!fs.existsSync($escapedSuccessfulDetachedReady)){try{process.kill(child.pid)}catch{};throw new Error('detached no-pipe child did not become ready')}"
    $successfulDetached = Invoke-NativeCapture -FilePath $nativeNode -Arguments @('--input-type=commonjs','-e',$successfulDetachedParentScript) -TimeoutSeconds 10
    Assert-RepairFixture -Condition ($successfulDetached.ExitCode -eq 0) -Message 'A successful native parent with a detached descendant did not preserve its exit code.'
    Assert-RepairFixture -Condition (
        (Test-Path -LiteralPath $successfulDetachedReady -PathType Leaf) -and
        (Get-Content -LiteralPath $successfulDetachedReady -Raw) -ceq 'ready'
    ) -Message 'The no-pipe containment probe did not prove its detached child reached readiness.'
    Start-Sleep -Milliseconds 2500
    Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath $successfulDetachedOutput)) -Message 'A detached no-pipe descendant survived successful native invocation cleanup.'

    $capturedFailure = Invoke-NativeCapture -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'capture','unused') -TimeoutSeconds 10
    Assert-RepairFixture -Condition (
        $capturedFailure.ExitCode -eq 7 -and
        $capturedFailure.Text.Contains('captured-stdout') -and
        $capturedFailure.Text.Contains('captured-stderr')
    ) -Message 'Bounded native capture did not preserve the exit code and diagnostic streams.'

    $batchHelper = Join-Path $fixtureRoot 'native batch helper with spaces.cmd'
    [IO.File]::WriteAllText($batchHelper, @'
@echo off
if "%~1"=="sleep" (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"
  exit /b 0
)
if "%~1"=="spawn-child" (
  set "MQL5_CHM_BATCH_READY=%~3"
  start "" /b "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -EncodedCommand "%~2"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "$deadline=[DateTime]::UtcNow.AddSeconds(3); while ((-not (Test-Path -LiteralPath $env:MQL5_CHM_BATCH_READY)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }; if (-not (Test-Path -LiteralPath $env:MQL5_CHM_BATCH_READY)) { exit 9 }"
  if errorlevel 1 exit /b 9
  exit /b 0
)
echo [%~1]
echo [%~2]
exit /b 7
'@.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n"), [Text.Encoding]::ASCII)
    $batchCapture = Invoke-NativeCapture -FilePath $batchHelper -Arguments @('contains spaces','') -TimeoutSeconds 10
    Assert-RepairFixture -Condition (
        $batchCapture.ExitCode -eq 7 -and
        $batchCapture.Text -match '(?m)^\[contains spaces\]\r?$' -and
        $batchCapture.Text -match '(?m)^\[\]\r?$'
    ) -Message 'Bounded native capture did not preserve synchronous .cmd output, empty arguments, spaces, and exit code.'
    $literalBatchHelper = Join-Path $fixtureRoot 'literal batch argument helper.cmd'
    [IO.File]::WriteAllText($literalBatchHelper, @'
@echo off
setlocal DisableDelayedExpansion
set "arg1=%~1"
set "arg2=%~2"
setlocal EnableDelayedExpansion
echo [!arg1!]
echo [!arg2!]
exit /b 7
'@.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n"), [Text.Encoding]::ASCII)
    $literalBatchArguments = [ordered]@{
        ampersand = 'unsafe&ver'
        pipe = 'unsafe|ver'
        output_redirection = 'unsafe>nul'
        input_redirection = 'unsafe<nul'
        percent_expansion = 'unsafe%PATH%'
        caret_escape = 'unsafe^value'
        open_parenthesis = 'unsafe(value'
        close_parenthesis = 'unsafe)value'
        delayed_expansion = 'unsafe!PATH!'
        legal_package_path = 'C:\Program Files (x86)\MQL5 & CHM! %draft% ^ caret\node.exe'
    }
    foreach ($literalBatchCase in $literalBatchArguments.GetEnumerator()) {
        $literalBatchCapture = Invoke-NativeCapture -FilePath $literalBatchHelper -Arguments @([string]$literalBatchCase.Value,'') -TimeoutSeconds 10
        $literalBatchLines = @($literalBatchCapture.Lines)
        Assert-RepairFixture -Condition (
            $literalBatchCapture.ExitCode -eq 7 -and
            $literalBatchLines.Count -eq 2 -and
            $literalBatchLines[0] -ceq "[$([string]$literalBatchCase.Value)]" -and
            $literalBatchLines[1] -ceq '[]'
        ) -Message "A .cmd argument containing $($literalBatchCase.Key) was corrupted or reinterpreted by cmd.exe. Exit=$($literalBatchCapture.ExitCode); output=$($literalBatchCapture.Text)"
    }
    Assert-RepairThrows -Action {
        Invoke-NativeCapture -FilePath $literalBatchHelper -Arguments @('unsafe"value') -TimeoutSeconds 10 | Out-Null
    } -Pattern 'cannot be transported safely' -Message 'A .cmd argument containing a quote was not rejected before command-processor reinterpretation.'
    $bangBatchDirectory = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'target!literal')
    $bangBatchHelper = Join-Path $bangBatchDirectory.FullName 'inherits delayed expansion.cmd'
    [IO.File]::WriteAllText($bangBatchHelper, @'
@echo off
echo [%~1]
echo [%~dp0]
exit /b 7
'@.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n"), [Text.Encoding]::ASCII)
    $bangBatchCapture = Invoke-NativeCapture -FilePath $bangBatchHelper -Arguments @('left!PATH!right') -TimeoutSeconds 10
    $bangBatchLines = @($bangBatchCapture.Lines)
    Assert-RepairFixture -Condition (
        $bangBatchCapture.ExitCode -eq 7 -and
        $bangBatchLines.Count -eq 2 -and
        $bangBatchLines[0] -ceq '[left!PATH!right]' -and
        $bangBatchLines[1] -ceq "[$($bangBatchDirectory.FullName)\]"
    ) -Message "A .cmd target inherited delayed expansion or corrupted a legal exclamation-mark path. Exit=$($bangBatchCapture.ExitCode); output=$($bangBatchCapture.Text)"
    $metacharacterBatchDirectory = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'batch target (copy) & ! %safe% ^')
    $metacharacterBatchHelper = Join-Path $metacharacterBatchDirectory.FullName 'literal helper.cmd'
    Copy-Item -LiteralPath $literalBatchHelper -Destination $metacharacterBatchHelper
    $metacharacterTargetCapture = Invoke-NativeCapture -FilePath $metacharacterBatchHelper -Arguments @('target-path-preserved','') -TimeoutSeconds 10
    $metacharacterTargetLines = @($metacharacterTargetCapture.Lines)
    Assert-RepairFixture -Condition (
        $metacharacterTargetCapture.ExitCode -eq 7 -and
        $metacharacterTargetLines.Count -eq 2 -and
        $metacharacterTargetLines[0] -ceq '[target-path-preserved]' -and
        $metacharacterTargetLines[1] -ceq '[]'
    ) -Message "A legal .cmd target path was corrupted or reinterpreted by cmd.exe. Exit=$($metacharacterTargetCapture.ExitCode); output=$($metacharacterTargetCapture.Text)"
    $batchBatHelper = Join-Path $fixtureRoot 'native batch helper with spaces.bat'
    Copy-Item -LiteralPath $batchHelper -Destination $batchBatHelper
    $batchBatCapture = Invoke-NativeCapture -FilePath $batchBatHelper -Arguments @('contains spaces','') -TimeoutSeconds 10
    Assert-RepairFixture -Condition (
        $batchBatCapture.ExitCode -eq 7 -and
        $batchBatCapture.Text -match '(?m)^\[contains spaces\]\r?$' -and
        $batchBatCapture.Text -match '(?m)^\[\]\r?$'
    ) -Message 'Bounded native capture did not preserve safe .bat arguments, output, and exit code.'
    $literalBatchBatHelper = Join-Path $fixtureRoot 'literal batch argument helper.bat'
    Copy-Item -LiteralPath $literalBatchHelper -Destination $literalBatchBatHelper
    $literalBatCapture = Invoke-NativeCapture -FilePath $literalBatchBatHelper -Arguments @('C:\Program Files (x86)\MQL5 & CHM!\server.mjs','') -TimeoutSeconds 10
    $literalBatLines = @($literalBatCapture.Lines)
    Assert-RepairFixture -Condition (
        $literalBatCapture.ExitCode -eq 7 -and
        $literalBatLines.Count -eq 2 -and
        $literalBatLines[0] -ceq '[C:\Program Files (x86)\MQL5 & CHM!\server.mjs]' -and
        $literalBatLines[1] -ceq '[]'
    ) -Message 'A .bat legal package path was corrupted or reinterpreted by cmd.exe.'
    $batchTimeoutTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-RepairThrows -Action {
        Invoke-NativeCapture -FilePath $batchHelper -Arguments @('sleep') -TimeoutSeconds 1 | Out-Null
    } -Pattern 'deadline' -Message 'A timed-out .cmd target was not contained.'
    Assert-RepairFixture -Condition ($batchTimeoutTimer.Elapsed.TotalSeconds -lt 8) -Message 'A timed-out .cmd target did not return promptly.'
    $batchDescendantOutput = Join-Path $fixtureRoot 'batch-inherited-handle-descendant.txt'
    $batchDescendantReady = Join-Path $fixtureRoot 'batch-inherited-handle-descendant.ready'
    $escapedBatchDescendantOutput = $batchDescendantOutput.Replace("'","''")
    $escapedBatchDescendantReady = $batchDescendantReady.Replace("'","''")
    $batchDescendantCommand = "[IO.File]::WriteAllText('$escapedBatchDescendantReady','ready',[Text.Encoding]::UTF8); Start-Sleep -Seconds 2; [IO.File]::WriteAllText('$escapedBatchDescendantOutput','batch-descendant-survived',[Text.Encoding]::UTF8); Start-Sleep -Seconds 30"
    $encodedBatchDescendant = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($batchDescendantCommand))
    $batchDescendantTimer = [Diagnostics.Stopwatch]::StartNew()
    $batchDescendantResult = Invoke-NativeCapture -FilePath $batchHelper -Arguments @('spawn-child',$encodedBatchDescendant,$batchDescendantReady) -TimeoutSeconds 5
    Assert-RepairFixture -Condition (
        $batchDescendantResult.ExitCode -eq 0 -and $batchDescendantTimer.Elapsed.TotalSeconds -lt 4
    ) -Message 'A successful .cmd descendant retained inherited output handles after its parent exited.'
    Assert-RepairFixture -Condition (
        (Test-Path -LiteralPath $batchDescendantReady -PathType Leaf) -and
        (Get-Content -LiteralPath $batchDescendantReady -Raw) -ceq 'ready'
    ) -Message 'The .cmd containment probe did not prove its detached child reached readiness.'
    Start-Sleep -Milliseconds 2500
    Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath $batchDescendantOutput)) -Message 'A successful .cmd descendant survived outer job cleanup.'

    $nativeWorkingDirectory = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'native current directory')
    Push-Location $nativeWorkingDirectory.FullName
    try {
        $workingDirectoryResult = Invoke-NativeCapture -FilePath $hostExecutable -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'cwd','unused') -TimeoutSeconds 10
    } finally {
        Pop-Location
    }
    Assert-RepairFixture -Condition (
        $workingDirectoryResult.ExitCode -eq 0 -and
        $workingDirectoryResult.Text.Trim().Equals($nativeWorkingDirectory.FullName, [StringComparison]::OrdinalIgnoreCase)
    ) -Message 'Bounded native invocation did not preserve the caller filesystem working directory.'

    $unicodeArgument = 'unicode-' + [char]0x2603 + '-' + [char]0x6f22
    $nativeArgumentValues = [string[]]@(
        '',
        'contains spaces',
        'embedded"quote',
        'trailing\',
        'slashes\\before"quote',
        $unicodeArgument
    )
    $argumentProbeCommand = [string[]]@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$nativeHelper,'arguments'
    ) + $nativeArgumentValues
    $argumentProbe = Invoke-NativeCapture -FilePath $hostExecutable -Arguments $argumentProbeCommand -TimeoutSeconds 10
    $argumentProbeJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($argumentProbe.Text))
    $argumentProbeValues = @((ConvertFrom-Json -InputObject $argumentProbeJson).arguments)
    Assert-RepairFixture -Condition ($argumentProbe.ExitCode -eq 0 -and $argumentProbeValues.Count -eq $nativeArgumentValues.Count) -Message 'Bounded native invocation changed the argument count.'
    for ($argumentIndex = 0; $argumentIndex -lt $nativeArgumentValues.Count; $argumentIndex++) {
        Assert-RepairFixture -Condition (
            [string]$argumentProbeValues[$argumentIndex] -ceq $nativeArgumentValues[$argumentIndex]
        ) -Message "Bounded native invocation corrupted argument $argumentIndex."
    }

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
$script:IndexContract='mql5-chm-index-v3-assets-v3'
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
function Assert-ManifestAndCorpus { param([string]$ProjectRoot) return [pscustomobject]@{IndexRevision=('a'*64);CorpusRevision=('c'*64);ManifestSchemaVersion=3;Manifest=[pscustomobject]@{index_contract='mql5-chm-index-v3-assets-v3';assets=[pscustomobject]@{policy_sha256=('d'*64)}}} }
function Get-SourceRecordsFromActiveRevision { param([string]$ProjectRoot) return @([pscustomobject]@{Id='fixture'}) }
function New-RevisionCandidate { param([string]$ProjectRoot,[object[]]$SourceRecords,[string]$WorkingRoot,[int]$ExtractionTimeoutSeconds,[int]$HhTimeoutSeconds) return [pscustomobject]@{IndexRevision=('b'*64);CorpusRevision=('c'*64);ManifestSchemaVersion=3;Manifest=[pscustomobject]@{index_contract='mql5-chm-index-v3-assets-v3';assets=[pscustomobject]@{policy_sha256=('d'*64)}};Inspection=[pscustomobject]@{}} }
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

    # A retry after the initial pointer was activated must reconcile the
    # advisory status and managed checksums without rewriting the pointer.
    $reconciliationRoot = Join-Path $fixtureRoot 'already active reconciliation probe'
    $reconciliationScripts = Join-Path $reconciliationRoot 'scripts'
    $reconciliationProject = Join-Path $reconciliationRoot 'project'
    foreach ($directory in @($reconciliationScripts,$reconciliationProject,(Join-Path $reconciliationProject 'data'),(Join-Path $reconciliationProject 'maintenance'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Rebuild-Index.ps1') -Destination (Join-Path $reconciliationScripts 'Rebuild-Index.ps1')
    $reconciliationMaintenance = @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Resolve-FullPath { param([string]$Path,[switch]$MustExist,[string]$PathType) return [IO.Path]::GetFullPath($Path) }
function Assert-NoReparsePoint { param([string]$Root,[string]$Path) }
function Enter-ExclusiveFileLock { param([string]$Path,[string]$IdentityRoot,[int]$TimeoutSeconds) $lease=[pscustomobject]@{};$lease|Add-Member ScriptMethod Dispose {};return $lease }
function Repair-InterruptedMaintenanceArtifacts { param([string]$ProjectRoot) }
function Repair-InterruptedRevisionStageInstall { param([string]$ProjectRoot) return [pscustomobject]@{State='none'} }
function Get-RevisionTransition { param([string]$ProjectRoot,[switch]$AllowMissing) return $null }
function Assert-MaintenancePackageIntegrity { param([string]$ProjectRoot,[switch]$AllowPendingTransition) return $true }
function Get-ActiveRevisionPointer { param([string]$ProjectRoot,[switch]$AllowMissing) return [pscustomobject]@{schema_version=2;active_revision=('b'*64)} }
function Assert-Revision { param([string]$ProjectRoot,[string]$Revision,[string]$IdentityMode,[switch]$RequireCurrent) return [pscustomobject]@{IndexRevision=('b'*64);CorpusRevision=('c'*64)} }
function Set-ActiveRevisionPointer { param([string]$ProjectRoot,[string]$ActiveRevision,[string]$PreviousRevision,[int]$SchemaVersion) [IO.File]::WriteAllText((Join-Path $ProjectRoot 'maintenance\pointer-set.txt'),'called');throw 'already-active retry rewrote the pointer' }
function Set-UpdateStatus {
    param([string]$ProjectRoot,[string]$Status,[string]$ActiveRevision,[string]$ActiveCorpusRevision,[string]$CandidateRevision,[string]$CandidateCorpusRevision,[string]$Message)
    $capture=[ordered]@{status=$Status;active_revision=$ActiveRevision;active_corpus_revision=$ActiveCorpusRevision;candidate_revision=$CandidateRevision;candidate_corpus_revision=$CandidateCorpusRevision}
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'maintenance\reconciliation-status.json'),($capture|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
}
function Update-ManagedChecksumsIfPresent { param([string]$ProjectRoot) [IO.File]::WriteAllText((Join-Path $ProjectRoot 'maintenance\checksum-reconciled.txt'),'1') }
function Remove-SafeDirectory { param([string]$ConfinementRoot,[string]$Path) }
'@
    [IO.File]::WriteAllText((Join-Path $reconciliationScripts 'IndexMaintenance.ps1'),$reconciliationMaintenance,(New-Object Text.UTF8Encoding($false)))
    $reconciliationResult = Invoke-NativeCapture -FilePath (Get-Process -Id $PID).Path -Arguments @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $reconciliationScripts 'Rebuild-Index.ps1'),
        '-Apply','-Revision',('b'*64),'-ProjectRoot',$reconciliationProject
    )
    $statusCapturePath = Join-Path $reconciliationProject 'maintenance\reconciliation-status.json'
    Assert-RepairFixture -Condition ($reconciliationResult.ExitCode -eq 0) -Message "Already-active rebuild retry failed. $($reconciliationResult.Text)"
    Assert-RepairFixture -Condition (Test-Path -LiteralPath $statusCapturePath -PathType Leaf) -Message 'Already-active rebuild retry did not reconcile update status.'
    $statusCapture = Get-Content -LiteralPath $statusCapturePath -Raw | ConvertFrom-Json
    Assert-RepairFixture -Condition (
        [string]$statusCapture.status -ceq 'up-to-date' -and
        [string]$statusCapture.active_revision -ceq ('b'*64) -and
        [string]$statusCapture.active_corpus_revision -ceq ('c'*64) -and
        [string]$statusCapture.candidate_revision -ceq ('b'*64) -and
        [string]$statusCapture.candidate_corpus_revision -ceq ('c'*64)
    ) -Message 'Already-active rebuild retry wrote incorrect reconciliation status.'
    Assert-RepairFixture -Condition ((Get-Content -LiteralPath (Join-Path $reconciliationProject 'maintenance\checksum-reconciled.txt') -Raw) -ceq '1') -Message 'Already-active rebuild retry did not reconcile managed checksums exactly once.'
    Assert-RepairFixture -Condition (-not (Test-Path -LiteralPath (Join-Path $reconciliationProject 'maintenance\pointer-set.txt'))) -Message 'Already-active rebuild retry rewrote the active pointer.'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $tempBase -Path $fixtureRoot }
}

Write-Host 'Index maintenance repair fixtures passed.'
