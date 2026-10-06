#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

# Load only the sidecar validator; packaging's executable entry point is not run.
$tokens=$null; $parseErrors=$null
$packageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Package-Portable.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Cannot parse the packaging script.' }
foreach ($name in @('Test-JsonIntegerValue','Assert-PreparedPackageManifestShape')) {
    $definition=$packageAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

$temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $temporaryParent ('mql5-json-roots-'+[guid]::NewGuid().ToString('N'))
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$utf8=New-Object Text.UTF8Encoding($false)
$checks=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) {throw $Message}; $script:checks++ }
function Write-Text([string]$Path,[string]$Text) { [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null; [IO.File]::WriteAllText($Path,$Text,$utf8) }
function Assert-RootRejected([scriptblock]$Read,[string]$Context) {
    $message=''; try { & $Read | Out-Null } catch { $message=$_.Exception.Message }
    Check ($message -match 'must be a JSON object') ($Context+' did not reject its serialized root: '+$message)
}
function Wrap-Root([string]$Kind,[string]$ObjectText) {
    switch ($Kind) {
        'singleton' {return '['+$ObjectText+']'}
        'multiple' {return '['+$ObjectText+','+$ObjectText+']'}
        'empty' {return '[]'}
        'null' {return 'null'}
        'boolean' {return 'true'}
        'number' {return '1'}
        'string' {return '"object"'}
    }
    throw 'Unknown fixture kind.'
}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $a='a'*64; $b='b'*64; $c='c'*64
    $transition=@{schema_version=2;operation='rollback';from_revision=$a;from_corpus_revision=$c;to_revision=$b;to_corpus_revision=$c;started_at='2026-10-06T00:00:00Z'} | ConvertTo-Json -Compress
    $status=@{schema_version=2;checked_at='2026-10-06T00:00:00Z';status='up-to-date';active_revision=$a;active_corpus_revision=$c;candidate_revision=$null;candidate_corpus_revision=$null;message='Verified'} | ConvertTo-Json -Compress
    $sidecar=@{schema_version=1;file='fixture.zip';bytes=0;sha256=$a} | ConvertTo-Json -Compress
    $transitionPath=Join-Path $testRoot 'maintenance\revision-transition.json'
    $statusPath=Join-Path $testRoot 'maintenance\update-status.json'
    $stagePath=Join-Path $testRoot 'maintenance\revision-stage.json'
    $reportPath=Join-Path $testRoot 'stage-report.json'
    $sidecarPath=Join-Path $testRoot 'fixture.zip.manifest.json'
    $provenancePath=Join-Path $testRoot 'tools\7zip.provenance.json'
    $policyPath=Join-Path $testRoot 'config\mql5-image-policy.json'
    $revisionRoot=Join-Path $testRoot ('revisions\'+$a)
    $corpusLockPath=Join-Path $revisionRoot 'corpus.lock.json'
    $repairManifestPath=Join-Path $revisionRoot 'manifest.json'
    Write-Text (Join-Path $revisionRoot 'mql5-docs.sqlite') 'untouched database'
    foreach ($kind in @('singleton','multiple','empty','null','boolean','number','string')) {
        Write-Text $transitionPath (Wrap-Root $kind $transition)
        Assert-RootRejected {Get-RevisionTransition -ProjectRoot $testRoot} ('transition '+$kind)
        Write-Text $statusPath (Wrap-Root $kind $status)
        Assert-RootRejected {Get-UpdateStatus -ProjectRoot $testRoot} ('status '+$kind)
        Write-Text $stagePath (Wrap-Root $kind '{}')
        Assert-RootRejected {Get-RevisionStageJournal -ProjectRoot $testRoot} ('stage journal '+$kind)
        Write-Text $reportPath (Wrap-Root $kind '{}')
        Assert-RootRejected {Assert-StagedRevisionReport -Path $reportPath -ExpectedRevision $a} ('current stage report '+$kind)
        Assert-RootRejected {Assert-LegacyStagedRevisionReport -Path $reportPath -ExpectedCorpusRevision $c} ('legacy stage report '+$kind)
        Write-Text $sidecarPath (Wrap-Root $kind $sidecar)
        Assert-RootRejected {Assert-PreparedPackageManifestShape -ManifestPath $sidecarPath -ExpectedFile 'fixture.zip'} ('orphan sidecar '+$kind)
        Assert-RootRejected {Read-JsonFile -Path $sidecarPath -RequireObject} ('generic object reader '+$kind)
        Write-Text $provenancePath (Wrap-Root $kind '{}')
        Assert-RootRejected {Assert-SevenZipProvenance -ProjectRoot $testRoot} ('extractor provenance '+$kind)
        Assert-RootRejected {Get-PinnedSevenZipMetadata -ProjectRoot $testRoot} ('repair provenance '+$kind)
        Write-Text $policyPath (Wrap-Root $kind '{}')
        Assert-RootRejected {Get-ChmIndexInputExtensions -ProjectRoot $testRoot} ('image policy '+$kind)
        Write-Text $corpusLockPath (Wrap-Root $kind '{}')
        Write-Text $repairManifestPath '{}'
        Assert-RootRejected {Assert-Revision -ProjectRoot $testRoot -Revision $a} ('revision corpus lock '+$kind)
        Write-Text $repairManifestPath (Wrap-Root $kind '{}')
        Assert-RootRejected {Get-RevisionStageReportRepairContext -ProjectRoot $testRoot -RevisionDirectory $revisionRoot} ('repair manifest '+$kind)
    }
    Write-Text $transitionPath $transition
    Check ((Get-RevisionTransition -ProjectRoot $testRoot).to_revision -ceq $b) 'Valid transition objects must pass.'
    Write-Text $statusPath $status
    Check ((Get-UpdateStatus -ProjectRoot $testRoot).status -ceq 'up-to-date') 'Valid update-status objects must pass.'
    Write-Text $sidecarPath $sidecar
    Check ((Assert-PreparedPackageManifestShape -ManifestPath $sidecarPath -ExpectedFile 'fixture.zip').bytes -eq 0) 'Valid sidecar objects must pass.'
    Write-Text $reportPath '{"items":[1,2],"empty":[]}'
    $nested=Read-JsonFile -Path $reportPath -RequireObject
    Check ($nested.items.Count -eq 2 -and $nested.empty -is [Array] -and $nested.empty.Count -eq 0) 'Legitimate arrays inside objects must be preserved.'
    Write-Text $reportPath '1'
    Check ((Read-JsonFile -Path $reportPath) -eq 1) 'The generic reader default must remain unchanged.'

    # Exercise the public recovery command. Invalid journals must fail before
    # canonical pointers, database bytes, retained backups, or journals change.
    foreach ($kind in @('singleton','multiple','empty','null','boolean','number','string')) {
        $case=Join-Path $testRoot ('public-'+$kind)
        $journal=Join-Path $case 'maintenance\revision-transition.json'
        Write-Text $journal (Wrap-Root $kind $transition)
        Write-Text (Join-Path $case 'maintenance\.update.lock') ''
        Write-Text (Join-Path $case 'data\active.json') ('{"schema_version":2,"active_revision":"'+$a+'","previous_revision":"'+$b+'","changed_at":"2026-10-06T00:00:00Z"}')
        Write-Text (Join-Path $case 'revisions\canonical.sqlite') 'canonical database evidence'
        Write-Text (Join-Path $case 'backups\retained.sqlite') 'retained backup evidence'
        $before=@{}
        foreach ($file in Get-ChildItem -LiteralPath $case -File -Recurse) {$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
        $beforePreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output=& $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Rollback-Documentation.ps1') -ProjectRoot $case 2>&1 | Out-String
            $childExit=$LASTEXITCODE
        } finally {$ErrorActionPreference=$beforePreference}
        Check ($childExit -ne 0 -and $output -match 'must be a JSON object') ('Public rollback accepted the '+$kind+' root: '+$output)
        foreach ($entry in $before.GetEnumerator()) {
            Check ((Test-Path -LiteralPath $entry.Key -PathType Leaf) -and (Get-FileHash -LiteralPath $entry.Key -Algorithm SHA256).Hash -ceq $entry.Value) ('Recovery changed or deleted evidence: '+$entry.Key)
        }
    }
    # This catches an object-only call site being reintroduced without the
    # serialized-root guard. Test fixture readers and the generic definition
    # are deliberately excluded.
    foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        if ($scriptFile.Name -like 'Test-*') {continue}
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$parseErrors)
        foreach ($call in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-JsonFile'},$true)) {
            Check (@($call.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'RequireObject'}).Count -eq 1) ('Object-only reader lacks its guard: '+$scriptFile.Name+':'+$call.Extent.StartLineNumber)
        }
    }
    Write-Output ('JSON_OBJECT_ROOT_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
} finally {
    $full=[IO.Path]::GetFullPath($testRoot)
    if (-not $full.StartsWith($temporaryParent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Test cleanup escaped its temporary parent.'}
    if (Test-Path -LiteralPath $full) {Remove-Item -LiteralPath $full -Recurse -Force}
}
# Public recovery refusal is an expected native exit in the fixtures above.
# Publish success only after every assertion and cleanup completed, so a shell
# wrapper does not mistake the last negative test for this script's result.
$global:LASTEXITCODE=0
