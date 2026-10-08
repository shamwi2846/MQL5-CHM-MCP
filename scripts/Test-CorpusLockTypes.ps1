#Requires -Version 5.1
[CmdletBinding()]
param([string]$TemporaryParent = [IO.Path]::GetTempPath())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

# Load only reviewed fixture builders and the freshness function. Never execute
# another test's top-level orchestration or perform an official download.
foreach ($definition in @(
    @{file='Test-StageInstallRecovery.ps1';names=@('New-CurrentStageRevisionTree','New-LegacyStageRevisionFixture')},
    @{file='Compare-OfficialDocumentationHashes.ps1';names=@('Compare-OfficialDocumentationHashes')}
)) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $definition.file),[ref]$tokens,[ref]$errors)
    if ($errors.Count) {throw 'Could not parse corpus-lock regression support.'}
    foreach ($name in $definition.names) {
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
        if ($null -eq $function) {throw 'Missing corpus-lock regression support.'}
        . ([scriptblock]::Create($function.Extent.Text))
    }
}

$parent=Resolve-FullPath -Path $TemporaryParent -MustExist -PathType Container
Assert-NoReparsePoint -Root $parent -Path $parent
$fixture=Join-Path $parent ('mql5-chm-corpus-lock-types-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$script:checks=0
function Check-CorpusType([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw ('FAIL: '+$Message)}
    $script:checks++
}
function Get-CorpusFixtureDigest([string]$Root) {
    $rows=@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        ($_.FullName.Substring($Root.Length)+'|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash)
    })
    return ($rows -join "`n")
}
function New-CorpusWrongValue($Value,[string]$Shape) {
    $result=switch ($Shape) {
        'singleton' {,@($Value)}
        'multiple' {,@($Value,$Value)}
        'empty' {,@()}
        'object' {[pscustomobject]@{value=$Value}}
        'null' {$null}
        'number' {42}
        'boolean' {$true}
        'string' {[string]$Value}
        'fractional' {[double]$Value+0.1}
        default {throw 'Unknown regression shape.'}
    }
    return ,$result
}
function Write-CorpusFixture([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
}

try {
    $trackedRoot=Join-Path $fixture 'tracked'
    [IO.Directory]::CreateDirectory($trackedRoot) | Out-Null
    $trackedSources=@(Get-Mql5CorpusDefinition | ForEach-Object {
        [pscustomobject]@{id=$_.Id;filename=$_.FileName;sha256=$_.Sha256;expected_topics=$_.TopicCount;role='native reference'}
    })
    $trackedJson=([pscustomobject]@{schema_version='1.0';sources=$trackedSources;expected_total_topics=4827}|ConvertTo-Json -Depth 20)
    $records=@(Get-Mql5CorpusDefinition | ForEach-Object {
        [pscustomobject]@{Id=$_.Id;FileName=$_.FileName;Sha256=$_.Sha256.ToLowerInvariant();Bytes=123;HttpLastModified=$null;HttpEtag=$null}
    })
    $observed=[pscustomobject]@{calls=0;downloadRoot=$null}
    $matching={param([string]$DownloadRoot,[int]$TimeoutSeconds) $observed.calls++;$observed.downloadRoot=$DownloadRoot;return $records}.GetNewClosure()
    $trackedPath=Join-Path $trackedRoot 'corpus.lock.json'
    [IO.File]::WriteAllText($trackedPath,$trackedJson,[Text.UTF8Encoding]::new($false))
    $before=Get-CorpusFixtureDigest $trackedRoot
    $normal=Compare-OfficialDocumentationHashes -ProjectRoot $trackedRoot -TimeoutSeconds 5 -InternalRecordProvider $matching
    Check-CorpusType ($normal.status -ceq 'up-to-date' -and $normal.sources.Count -eq 3) 'Valid tracked schema-1.0 lock failed.'
    Check-CorpusType ($before -ceq (Get-CorpusFixtureDigest $trackedRoot)) 'Valid freshness changed tracked evidence.'
    Check-CorpusType (-not (Test-Path -LiteralPath $observed.downloadRoot)) 'Valid freshness retained temporary storage.'

    foreach ($field in @('schema_version','id','filename','sha256')) {
        foreach ($shape in @('singleton','multiple','empty','object','null','number','boolean')) {
            $value=$trackedJson|ConvertFrom-Json
            $owner=if ($field -ceq 'schema_version') {$value} else {$value.sources[0]}
            $owner.PSObject.Properties[$field].Value=New-CorpusWrongValue $owner.PSObject.Properties[$field].Value $shape
            Write-CorpusFixture $trackedPath $value
            $before=Get-CorpusFixtureDigest $trackedRoot;$calls=$observed.calls
            $result=Compare-OfficialDocumentationHashes -ProjectRoot $trackedRoot -TimeoutSeconds 5 -InternalRecordProvider $matching
            Check-CorpusType ($result.status -ceq 'check-unavailable') ("Freshness accepted $field/$shape.")
            Check-CorpusType ($observed.calls -eq $calls) ("Freshness downloaded after malformed $field/$shape.")
            Check-CorpusType ($before -ceq (Get-CorpusFixtureDigest $trackedRoot)) ("Freshness changed malformed $field/$shape evidence.")
        }
    }
    $value=$trackedJson|ConvertFrom-Json
    $value.sources=[pscustomobject]@{first=$value.sources[0];second=$value.sources[1];third=$value.sources[2]}
    Write-CorpusFixture $trackedPath $value
    $result=Compare-OfficialDocumentationHashes -ProjectRoot $trackedRoot -TimeoutSeconds 5 -InternalRecordProvider $matching
    Check-CorpusType ($result.status -ceq 'check-unavailable') 'Freshness accepted an object instead of its source array.'

    foreach ($kind in @('current','legacy')) {
        $treeRoot=Join-Path $fixture $kind
        [IO.Directory]::CreateDirectory($treeRoot) | Out-Null
        $tree=if ($kind -ceq 'current') {
            New-CurrentStageRevisionTree -Root $treeRoot -Seed 'corpus-types' -Timestamp '2026-10-08T00:00:00Z'
        } else {New-LegacyStageRevisionFixture -Root $treeRoot -Seed 'corpus-types'}
        $lockPath=Join-Path $tree.Root 'corpus.lock.json'
        $original=[IO.File]::ReadAllText($lockPath)
        $validated=Assert-Revision -ProjectRoot $fixture -Revision $tree.Index -RevisionRoot $tree.Root -RevisionConfinementRoot $fixture -IdentityMode Index
        Check-CorpusType ($validated.IndexRevision -ceq $tree.Index -and $validated.CorpusRevision -ceq $tree.Corpus) ("Valid $kind revision failed.")
        foreach ($field in @('id','filename','sha256','expected_topics','expected_total_topics')) {
            $shapes=if ($field -in @('expected_topics','expected_total_topics')) {@('singleton','multiple','empty','object','string','boolean','fractional')} else {@('singleton','multiple','empty','object','null','number','boolean')}
            foreach ($shape in $shapes) {
                $value=$original|ConvertFrom-Json
                $owner=if ($field -ceq 'expected_total_topics') {$value} else {$value.sources[0]}
                $owner.PSObject.Properties[$field].Value=New-CorpusWrongValue $owner.PSObject.Properties[$field].Value $shape
                Write-CorpusFixture $lockPath $value
                $before=Get-CorpusFixtureDigest $treeRoot;$failed=$false
                try {Assert-Revision -ProjectRoot $fixture -Revision $tree.Index -RevisionRoot $tree.Root -RevisionConfinementRoot $fixture -IdentityMode Index | Out-Null} catch {$failed=$true}
                Check-CorpusType $failed ("$kind revision accepted $field/$shape.")
                Check-CorpusType ($before -ceq (Get-CorpusFixtureDigest $treeRoot)) ("$kind revision changed malformed $field/$shape evidence.")
            }
        }
        # Existing revision schema/contract compatibility is not tightened by
        # these original-value checks. Whole numbers and optional null totals
        # retain the same meaning as the manifest's numeric fields.
        foreach ($case in @('whole_decimal','null_total')) {
            $value=$original|ConvertFrom-Json
            if ($case -ceq 'whole_decimal') {$value.sources[0].expected_topics=[double]4134;$value.expected_total_topics=[double]4827}
            else {$value.expected_total_topics=$null}
            Write-CorpusFixture $lockPath $value
            $validated=Assert-Revision -ProjectRoot $fixture -Revision $tree.Index -RevisionRoot $tree.Root -RevisionConfinementRoot $fixture -IdentityMode Index
            Check-CorpusType ($validated.IndexRevision -ceq $tree.Index) ("$kind revision lost valid $case compatibility.")
        }
        [IO.File]::WriteAllText($lockPath,$original,[Text.UTF8Encoding]::new($false))
        Check-CorpusType ((Assert-Revision -ProjectRoot $fixture -Revision $tree.Index -RevisionRoot $tree.Root -RevisionConfinementRoot $fixture -IdentityMode Index).IndexRevision -ceq $tree.Index) ("$kind revision retry with valid evidence failed.")
    }
    Write-Output ('CORPUS_LOCK_TYPE_TESTS='+$script:checks+' host='+$PSVersionTable.PSVersion)
} finally {
    if (Test-Path -LiteralPath $fixture -PathType Container) {Remove-SafeDirectory -ConfinementRoot $parent -Path $fixture}
}
