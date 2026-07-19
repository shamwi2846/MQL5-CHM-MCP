[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$projectRoot = Resolve-FullPath -Path (Split-Path -Parent $PSScriptRoot) -MustExist -PathType Container
$buildRoot = Join-Path $projectRoot 'build'
if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $buildRoot | Out-Null
}
$testRoot = Join-Path $buildRoot ('file-set-transaction-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0

function Write-TestFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-TestDescriptor {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = $utf8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{Bytes=[int64]$bytes.Length;Sha256=$hash}
}

function New-TestJournalItem {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Prepared,
        [Parameter(Mandatory)][string]$Backup,
        [AllowNull()][object]$OldText,
        [Parameter(Mandatory)][string]$NewText
    )
    $newDescriptor = Get-TestDescriptor -Text $NewText
    $oldPresent = $null -ne $OldText
    $oldDescriptor = if ($oldPresent) { Get-TestDescriptor -Text $OldText } else { $null }
    return [ordered]@{
        target=$Target
        prepared=$Prepared
        backup=$Backup
        old_present=[bool]$oldPresent
        old_bytes=if ($oldPresent) { $oldDescriptor.Bytes } else { $null }
        old_sha256=if ($oldPresent) { $oldDescriptor.Sha256 } else { $null }
        new_bytes=$newDescriptor.Bytes
        new_sha256=$newDescriptor.Sha256
    }
}

function Write-TestJournal {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$JournalName = '.transaction.json',
        [ValidateSet('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')][string]$Role
    )
    if ([string]::IsNullOrWhiteSpace($Role)) {
        $value = [ordered]@{schema_version=1;operation='publish-prepared-file-set';transaction_id='0123456789abcdef0123456789abcdef';items=@($Items)}
    } else {
        $value = [ordered]@{schema_version=2;operation='publish-prepared-file-set';transaction_id='0123456789abcdef0123456789abcdef';role=$Role;items=@($Items)}
    }
    [IO.File]::WriteAllText((Join-Path $Root $JournalName), ($value | ConvertTo-Json -Depth 8), $utf8)
}

function Assert-Test {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function New-TestCaseDirectory {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

try {
    # Normal two-file publication leaves only the validated canonical pair.
    $case = New-TestCaseDirectory -Name 'normal'
    Write-TestFile (Join-Path $case 'a.txt') 'old-a'
    Write-TestFile (Join-Path $case 'b.txt') 'old-b'
    Write-TestFile (Join-Path $case '.a.new') 'new-a'
    Write-TestFile (Join-Path $case '.b.new') 'new-b'
    Publish-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json' -Items @(
        [pscustomobject]@{PreparedPath=(Join-Path $case '.a.new');TargetPath=(Join-Path $case 'a.txt')},
        [pscustomobject]@{PreparedPath=(Join-Path $case '.b.new');TargetPath=(Join-Path $case 'b.txt')}
    ) | Out-Null
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'new-a') 'Normal publication did not install a.txt.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'b.txt')) -ceq 'new-b') 'Normal publication did not install b.txt.'
    Assert-Test (-not (Test-Path (Join-Path $case '.transaction.json'))) 'Normal publication retained its journal.'

    # A hard stop after the durable journal candidate is flushed but before
    # its atomic rename is recoverable and does not strand a double-dot temp.
    $case = New-TestCaseDirectory -Name 'journal-publication-cut'
    Write-TestFile (Join-Path $case 'a.txt') 'old-a'
    Write-TestFile (Join-Path $case '.a.new') 'new-a'
    $interrupted = $false
    try {
        Publish-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json' -Items @(
            [pscustomobject]@{PreparedPath=(Join-Path $case '.a.new');TargetPath=(Join-Path $case 'a.txt')}
        ) -InternalCheckpoint { param($phase) if ($phase -ceq 'journal-prepared') { throw 'synthetic journal publication crash' } } | Out-Null
    } catch { $interrupted = $_.Exception.Message -match 'synthetic journal publication crash' }
    Assert-Test $interrupted 'The journal-prepared crash cut was not reached.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'old-a') 'Journal preparation changed a canonical target before publication.'
    Assert-Test (@(Get-ChildItem -LiteralPath $case -Force | Where-Object Name -like '.transaction.json.prepared-*').Count -eq 1) 'Journal preparation did not retain one transaction-bound recovery file.'
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'committed') 'Prepared journal recovery did not complete its candidate.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'new-a') 'Prepared journal recovery did not publish its candidate.'
    Assert-Test (@(Get-ChildItem -LiteralPath $case -Force).Count -eq 1) 'Prepared journal recovery retained transaction debris.'

    $case = New-TestCaseDirectory -Name 'partial-journal-write-cut'
    Write-TestFile (Join-Path $case 'a.txt') 'old-a'
    Write-TestFile (Join-Path $case '.a.new') 'new-a'
    Write-TestFile (Join-Path $case '.transaction.json.writing-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') '{"schema_version":'
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'none') 'Partial pre-publication journal write was not classified as pre-journal debris.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $case '.transaction.json.writing-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'))) 'Partial journal write was stranded.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'old-a') 'Partial journal cleanup changed the canonical target.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.a.new')) -ceq 'new-a') 'Partial journal cleanup changed prepared candidate bytes.'

    # Recover the exact legacy double-dot Write-JsonAtomic cut produced by
    # earlier builds, after strict journal/context validation.
    $case = New-TestCaseDirectory -Name 'legacy-double-dot-journal-cut'
    $items = @((New-TestJournalItem 'a.txt' '.a.new' '.a.backup-0123456789abcdef0123456789abcdef' 'old-a' 'new-a'))
    Write-TestFile (Join-Path $case 'a.txt') 'old-a'
    Write-TestFile (Join-Path $case '.a.new') 'new-a'
    Write-TestJournal -Root $case -Items $items
    [IO.File]::Move((Join-Path $case '.transaction.json'),(Join-Path $case '..transaction.json.replace.tmp-fedcba9876543210fedcba9876543210'))
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'committed') 'Legacy double-dot journal recovery did not commit its complete candidate.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'new-a') 'Legacy double-dot journal recovery did not publish its candidate.'
    Assert-Test (@(Get-ChildItem -LiteralPath $case -Force).Count -eq 1) 'Legacy double-dot journal recovery retained transaction debris.'

    # A fully recoverable candidate commits after an interruption between items.
    $case = New-TestCaseDirectory -Name 'commit-recovery'
    $items = @(
        (New-TestJournalItem 'a.txt' '.a.new' '.a.backup' 'old-a' 'new-a'),
        (New-TestJournalItem 'b.txt' '.b.new' '.b.backup' 'old-b' 'new-b')
    )
    Write-TestFile (Join-Path $case 'a.txt') 'new-a'
    Write-TestFile (Join-Path $case '.a.backup') 'old-a'
    Write-TestFile (Join-Path $case 'b.txt') 'old-b'
    Write-TestFile (Join-Path $case '.b.new') 'new-b'
    Write-TestJournal -Root $case -Items $items
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'committed') 'Recoverable candidate did not commit.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'b.txt')) -ceq 'new-b') 'Candidate recovery did not complete b.txt.'
    Assert-Test (@(Get-ChildItem $case -Force).Count -eq 2) 'Candidate recovery retained transaction debris.'

    # An incomplete candidate restores the complete prior pair.
    $case = New-TestCaseDirectory -Name 'rollback-recovery'
    $items = @(
        (New-TestJournalItem 'a.txt' '.a.new' '.a.backup' 'old-a' 'new-a'),
        (New-TestJournalItem 'b.txt' '.b.new' '.b.backup' 'old-b' 'new-b')
    )
    Write-TestFile (Join-Path $case 'a.txt') 'new-a'
    Write-TestFile (Join-Path $case '.a.backup') 'old-a'
    Write-TestFile (Join-Path $case '.b.backup') 'old-b'
    Write-TestJournal -Root $case -Items $items
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'rolled-back') 'Incomplete candidate did not roll back.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'old-a') 'Rollback did not restore a.txt.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'b.txt')) -ceq 'old-b') 'Rollback did not restore b.txt.'

    # The release ZIP and its strict sidecar use this same two-file primitive.
    # Model interruption after the ZIP replacement but before sidecar replacement.
    $case = New-TestCaseDirectory -Name 'zip-sidecar-recovery'
    $oldSidecar = '{"schema_version":1,"file":"package.zip","bytes":7,"sha256":"old"}'
    $newSidecar = '{"schema_version":1,"file":"package.zip","bytes":7,"sha256":"new"}'
    $items = @(
        (New-TestJournalItem 'package.zip' '.package.zip.new' '.package.zip.backup' 'old-zip' 'new-zip'),
        (New-TestJournalItem 'package.zip.manifest.json' '.package.manifest.new' '.package.manifest.backup' $oldSidecar $newSidecar)
    )
    Write-TestFile (Join-Path $case 'package.zip') 'new-zip'
    Write-TestFile (Join-Path $case '.package.zip.backup') 'old-zip'
    Write-TestFile (Join-Path $case 'package.zip.manifest.json') $oldSidecar
    Write-TestFile (Join-Path $case '.package.manifest.new') $newSidecar
    Write-TestJournal -Root $case -Items $items
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'committed') 'Interrupted ZIP/sidecar publication did not complete the candidate pair.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'package.zip.manifest.json')) -ceq $newSidecar) 'ZIP/sidecar recovery retained the prior sidecar.'
    Assert-Test (@(Get-ChildItem $case -Force).Count -eq 2) 'ZIP/sidecar recovery retained transaction debris.'

    # A partial first publication clears only journal-bound candidate bytes.
    $case = New-TestCaseDirectory -Name 'first-build-recovery'
    $items = @(
        (New-TestJournalItem 'a.txt' '.a.new' '.a.backup' $null 'new-a'),
        (New-TestJournalItem 'b.txt' '.b.new' '.b.backup' $null 'new-b')
    )
    Write-TestFile (Join-Path $case 'a.txt') 'new-a'
    Write-TestFile (Join-Path $case 'unrelated.chm') 'keep-me'
    Write-TestJournal -Root $case -Items $items
    $result = Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json'
    Assert-Test ($result.State -ceq 'rolled-back') 'Partial first build did not roll back.'
    Assert-Test (-not (Test-Path (Join-Path $case 'a.txt'))) 'Partial first build retained a canonical candidate.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'unrelated.chm')) -ceq 'keep-me') 'Recovery modified unrelated output.'

    # Ambiguous bytes fail closed before an earlier item is changed.
    $case = New-TestCaseDirectory -Name 'ambiguous'
    $items = @(
        (New-TestJournalItem 'a.txt' '.a.new' '.a.backup' 'old-a' 'new-a'),
        (New-TestJournalItem 'b.txt' '.b.new' '.b.backup' 'old-b' 'new-b')
    )
    Write-TestFile (Join-Path $case 'a.txt') 'new-a'
    Write-TestFile (Join-Path $case '.a.backup') 'old-a'
    Write-TestFile (Join-Path $case 'b.txt') 'unknown-b'
    Write-TestFile (Join-Path $case '.b.backup') 'old-b'
    Write-TestJournal -Root $case -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.transaction.json' | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Ambiguous recovery unexpectedly mutated the file set.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'a.txt')) -ceq 'new-a') 'Fail-closed recovery partially rolled back an earlier item.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.a.backup')) -ceq 'old-a') 'Fail-closed recovery removed an earlier backup.'
    Assert-Test (Test-Path (Join-Path $case '.transaction.json')) 'Fail-closed recovery removed its evidence journal.'

    # A structurally valid journal from another transaction role must not be
    # replayed merely because it was substituted at the Node journal path.
    $case = New-TestCaseDirectory -Name 'cross-context-role'
    $item = New-TestJournalItem 'unrelated.txt' '.unrelated.prepared' '.unrelated.backup' 'keep-old' 'replace-new'
    Write-TestFile (Join-Path $case 'unrelated.txt') 'keep-old'
    Write-TestFile (Join-Path $case '.unrelated.prepared') 'replace-new'
    Write-TestJournal -Root $case -JournalName '.node-runtime-transaction.json' -Role portable-zip -Items @($item)
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.node-runtime-transaction.json' -ExpectedRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Cross-context role substitution was accepted.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'unrelated.txt')) -ceq 'keep-old') 'Cross-context rejection changed an unrelated target.'
    Assert-Test (Test-Path (Join-Path $case '.unrelated.prepared')) 'Cross-context rejection removed unrelated prepared bytes.'

    # Even the right role cannot authorize a different target leaf set.
    $case = New-TestCaseDirectory -Name 'wrong-context-targets'
    $items = @(
        (New-TestJournalItem 'LICENSE' '.node-license-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.prepared' '.LICENSE.backup-0123456789abcdef0123456789abcdef' 'old-license' 'new-license'),
        (New-TestJournalItem 'other.exe' '.node-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.prepared' '.other.exe.backup-0123456789abcdef0123456789abcdef' 'old-other' 'new-other')
    )
    Write-TestFile (Join-Path $case 'LICENSE') 'old-license'
    Write-TestFile (Join-Path $case 'other.exe') 'old-other'
    Write-TestFile (Join-Path $case '.node-license-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.prepared') 'new-license'
    Write-TestFile (Join-Path $case '.node-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.prepared') 'new-other'
    Write-TestJournal -Root $case -JournalName '.node-runtime-transaction.json' -Role node-runtime -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.node-runtime-transaction.json' -ExpectedRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Context-bound recovery accepted the wrong target names.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'LICENSE')) -ceq 'old-license') 'Wrong-target rejection changed the valid target.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'other.exe')) -ceq 'old-other') 'Wrong-target rejection changed the unrelated target.'

    # Exact targets with non-token-derived prepared names also fail before a move.
    $case = New-TestCaseDirectory -Name 'wrong-context-names'
    $items = @(
        (New-TestJournalItem 'LICENSE' '.license.candidate' '.LICENSE.backup-0123456789abcdef0123456789abcdef' 'old-license' 'new-license'),
        (New-TestJournalItem 'node.exe' '.node.candidate' '.node.exe.backup-0123456789abcdef0123456789abcdef' 'old-node' 'new-node')
    )
    Write-TestFile (Join-Path $case 'LICENSE') 'old-license'
    Write-TestFile (Join-Path $case 'node.exe') 'old-node'
    Write-TestFile (Join-Path $case '.license.candidate') 'new-license'
    Write-TestFile (Join-Path $case '.node.candidate') 'new-node'
    Write-TestJournal -Root $case -JournalName '.node-runtime-transaction.json' -Role node-runtime -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.node-runtime-transaction.json' -ExpectedRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Context-bound recovery accepted non-token-derived names.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'node.exe')) -ceq 'old-node') 'Prepared-name rejection changed the Node target.'
    Assert-Test (Test-Path (Join-Path $case '.license.candidate')) 'Prepared-name rejection removed unbound bytes.'

    # Journal hashes that consistently describe arbitrary files are still not a
    # valid Node candidate: the role binds the new descriptors to the pinned
    # executable and license before generic recovery can move anything.
    $case = New-TestCaseDirectory -Name 'node-semantic-descriptors'
    $nodeToken = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $items = @(
        (New-TestJournalItem 'LICENSE' ".node-license-$nodeToken.prepared" '.LICENSE.backup-0123456789abcdef0123456789abcdef' 'old-license' 'hash-consistent-fake-license'),
        (New-TestJournalItem 'node.exe' ".node-$nodeToken.prepared" '.node.exe.backup-0123456789abcdef0123456789abcdef' 'old-node' 'hash-consistent-fake-node')
    )
    Write-TestFile (Join-Path $case 'LICENSE') 'old-license'
    Write-TestFile (Join-Path $case 'node.exe') 'old-node'
    Write-TestFile (Join-Path $case ".node-license-$nodeToken.prepared") 'hash-consistent-fake-license'
    Write-TestFile (Join-Path $case ".node-$nodeToken.prepared") 'hash-consistent-fake-node'
    Write-TestFile (Join-Path $case '.LICENSE.backup-0123456789abcdef0123456789abcdef') 'old-license'
    Write-TestJournal -Root $case -JournalName '.node-runtime-transaction.json' -Role node-runtime -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.node-runtime-transaction.json' -ExpectedRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Hash-consistent but unpinned Node candidate was accepted.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'node.exe')) -ceq 'old-node') 'Unpinned Node rejection changed the canonical executable.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.LICENSE.backup-0123456789abcdef0123456789abcdef')) -ceq 'old-license') 'Unpinned Node rejection changed prior backup bytes.'

    # The portable role additionally binds the candidate sidecar contents to
    # the exact ZIP leaf and new ZIP descriptor, not merely to its own journal
    # hash. A mismatched sidecar therefore fails before canonical/backup moves.
    $case = New-TestCaseDirectory -Name 'portable-sidecar-semantics'
    $packageToken = 'cccccccccccccccccccccccccccccccc'
    $candidateZipText = 'candidate-zip-bytes'
    $candidateZipDescriptor = Get-TestDescriptor $candidateZipText
    $candidateSidecarText = '{"schema_version":1,"file":"package.zip","bytes":19,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}'
    $oldZipText = 'old-zip'
    $oldZipDescriptor = Get-TestDescriptor $oldZipText
    $oldSidecarText = "{`"schema_version`":1,`"file`":`"package.zip`",`"bytes`":$($oldZipDescriptor.Bytes),`"sha256`":`"$($oldZipDescriptor.Sha256)`"}"
    $items = @(
        (New-TestJournalItem 'package.zip' ".package-$packageToken.prepared.zip" '.package.zip.backup-0123456789abcdef0123456789abcdef' $oldZipText $candidateZipText),
        (New-TestJournalItem 'package.zip.manifest.json' ".package-$packageToken.prepared.manifest.json" '.package.zip.manifest.json.backup-0123456789abcdef0123456789abcdef' $oldSidecarText $candidateSidecarText)
    )
    Write-TestFile (Join-Path $case 'package.zip') $oldZipText
    Write-TestFile (Join-Path $case 'package.zip.manifest.json') $oldSidecarText
    Write-TestFile (Join-Path $case ".package-$packageToken.prepared.zip") $candidateZipText
    Write-TestFile (Join-Path $case ".package-$packageToken.prepared.manifest.json") $candidateSidecarText
    Write-TestFile (Join-Path $case '.package.zip.backup-0123456789abcdef0123456789abcdef') $oldZipText
    Write-TestJournal -Root $case -JournalName '.package.zip.publication-transaction.json' -Role portable-zip -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.package.zip.publication-transaction.json' -ExpectedRole portable-zip -ExpectedTargetNames @('package.zip','package.zip.manifest.json') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Portable transaction accepted a sidecar that mismatched its candidate ZIP.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'package.zip')) -ceq $oldZipText) 'Mismatched sidecar rejection changed the canonical ZIP.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.package.zip.backup-0123456789abcdef0123456789abcdef')) -ceq $oldZipText) 'Mismatched sidecar rejection changed prior ZIP backup bytes.'

    # The same semantic binding applies before rollback. If an interrupted
    # publication has no complete candidate and its complete prior sidecar does
    # not describe the prior ZIP, all canonical and backup evidence is retained.
    $case = New-TestCaseDirectory -Name 'portable-prior-sidecar-semantics'
    $packageToken = 'dddddddddddddddddddddddddddddddd'
    $candidateZipText = 'candidate-only-zip'
    $oldZipText = 'prior-zip'
    $oldZipDescriptor = Get-TestDescriptor $oldZipText
    $mismatchedOldSidecar = "{`"schema_version`":1,`"file`":`"package.zip`",`"bytes`":$($oldZipDescriptor.Bytes),`"sha256`":`"$('f' * 64)`"}"
    $items = @(
        (New-TestJournalItem 'package.zip' ".package-$packageToken.prepared.zip" '.package.zip.backup-0123456789abcdef0123456789abcdef' $oldZipText $candidateZipText),
        (New-TestJournalItem 'package.zip.manifest.json' ".package-$packageToken.prepared.manifest.json" '.package.zip.manifest.json.backup-0123456789abcdef0123456789abcdef' $mismatchedOldSidecar '{"schema_version":1,"file":"package.zip","bytes":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}')
    )
    Write-TestFile (Join-Path $case 'package.zip') $candidateZipText
    Write-TestFile (Join-Path $case '.package.zip.backup-0123456789abcdef0123456789abcdef') $oldZipText
    Write-TestFile (Join-Path $case '.package.zip.manifest.json.backup-0123456789abcdef0123456789abcdef') $mismatchedOldSidecar
    Write-TestJournal -Root $case -JournalName '.package.zip.publication-transaction.json' -Role portable-zip -Items $items
    $failedClosed = $false
    try { Repair-PreparedFileSetTransaction -Root $case -JournalName '.package.zip.publication-transaction.json' -ExpectedRole portable-zip -ExpectedTargetNames @('package.zip','package.zip.manifest.json') | Out-Null }
    catch { $failedClosed = $true }
    Assert-Test $failedClosed 'Portable rollback accepted a mismatched complete prior sidecar.'
    Assert-Test ((Get-Content -Raw (Join-Path $case 'package.zip')) -ceq $candidateZipText) 'Prior-sidecar rejection changed the canonical candidate ZIP.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.package.zip.backup-0123456789abcdef0123456789abcdef')) -ceq $oldZipText) 'Prior-sidecar rejection changed the prior ZIP backup.'
    Assert-Test ((Get-Content -Raw (Join-Path $case '.package.zip.manifest.json.backup-0123456789abcdef0123456789abcdef')) -ceq $mismatchedOldSidecar) 'Prior-sidecar rejection changed the prior sidecar backup.'

    Write-Host "Prepared file-set transaction tests passed: $passed"
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $testRoot
    }
}
