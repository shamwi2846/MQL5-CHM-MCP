#Requires -Version 5.1
[CmdletBinding()]
param([string]$TemporaryParent = [IO.Path]::GetTempPath())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

# Reuse the independently specified fixture values without running its suite.
$tokens=$null; $parseErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-StageInstallRecovery.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Cannot parse the stage fixture definitions.' }
$definition=$fixtureAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-StageFixtureReport'},$true)
. ([scriptblock]::Create($definition.Extent.Text))

$parentFull=Resolve-FullPath -Path $TemporaryParent -MustExist -PathType Container
$testRoot=Join-Path $parentFull ('json-scalars-'+[guid]::NewGuid().ToString('N'))
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$utf8=New-Object Text.UTF8Encoding($false)
$checks=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) {throw $Message}; $script:checks++ }
function Write-Value([string]$Path,[object]$Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Compress -Depth 30),$utf8)
}
function Clone-Value([object]$Value) {
    $json=$Value | ConvertTo-Json -Compress -Depth 30
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {return ConvertFrom-Json -InputObject $json -DateKind String}
    return ConvertFrom-Json -InputObject $json
}
function Set-Field([object]$Value,[string]$Path,[AllowNull()][object]$Replacement) {
    $parts=$Path.Split('.'); $target=$Value
    for ($i=0;$i -lt $parts.Length-1;$i++) {$target=$target.PSObject.Properties[$parts[$i]].Value}
    $target.PSObject.Properties[$parts[-1]].Value=$Replacement
}
function Assert-TypeRejected([scriptblock]$Read,[string]$Context) {
    $message=''; try { & $Read | Out-Null } catch {$message=$_.Exception.Message}
    Check ($message -match 'must (?:have JSON type|contain JSON strings)') ($Context+' did not reject its raw scalar type: '+$message)
}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $a='a'*64; $b='b'*64; $c='c'*64; $d='d'*64
    $transition=[pscustomobject][ordered]@{schema_version=2;operation='rollback';from_revision=$a;from_corpus_revision=$c;to_revision=$b;to_corpus_revision=$d;started_at='2026-10-08T00:00:00Z'}
    $status=[pscustomobject][ordered]@{schema_version=2;checked_at='2026-10-08T00:00:00Z';status='up-to-date';active_revision=$a;active_corpus_revision=$c;candidate_revision=$null;candidate_corpus_revision=$null;message='Verified'}
    $report=New-StageFixtureReport -Revision $b -CorpusRevision $d -BaseRevision $a -BaseCorpusRevision $c
    $legacy=[pscustomobject][ordered]@{schema_version=1;revision=$d;base_revision=$c;staged_at='2026-10-08T00:00:00Z';validation_passed=$true;source_topic_counts=$report.source_topic_counts;changes=$report.changes;required_rankings=$report.required_rankings}
    $stage=[pscustomobject][ordered]@{
        schema_version=1;operation='rebuild';index_revision=$b;corpus_revision=$d;base_index_revision=$a;base_corpus_revision=$c
        candidate_tree_sha256=('e'*64);json_digest_contract='powershell-json-compress-depth20-v1'
        stage_report_canonical_sha256=(Get-CanonicalJsonValueSha256 -Value $report);stage_report_file_sha256=(Get-StagedRevisionReportFileSha256 -StageReport $report)
        destination_existed=$false;prior_stage_report_canonical_sha256=$null;prior_stage_report_file_sha256=$null
        allow_legacy_active=$false;started_at='2026-10-08T00:00:00Z';stage_report=$report
    }
    $manifest=[pscustomobject][ordered]@{schema_version=3;index_revision=$b;corpus_sha256=$d;database=[pscustomobject]@{sha256=$b}}
    $revisionRoot=Join-Path $testRoot ('revisions\'+$b)
    $cases=@(
        @{Name='transition';Value=$transition;Path=(Join-Path $testRoot 'maintenance\revision-transition.json');Fields=@('schema_version','operation','from_revision','from_corpus_revision','to_revision','to_corpus_revision','started_at');Read={Get-RevisionTransition -ProjectRoot $testRoot}},
        @{Name='status';Value=$status;Path=(Join-Path $testRoot 'maintenance\update-status.json');Fields=@('schema_version','checked_at','status','active_revision','active_corpus_revision','candidate_revision','candidate_corpus_revision','message');Read={Get-UpdateStatus -ProjectRoot $testRoot}},
        @{Name='stage';Value=$stage;Path=(Join-Path $testRoot 'maintenance\revision-stage.json');Fields=@('schema_version','operation','index_revision','corpus_revision','base_index_revision','base_corpus_revision','candidate_tree_sha256','json_digest_contract','stage_report_canonical_sha256','stage_report_file_sha256','destination_existed','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256','allow_legacy_active','started_at');Read={Get-RevisionStageJournal -ProjectRoot $testRoot}},
        @{Name='report';Value=$report;Path=(Join-Path $testRoot 'report.json');Fields=@('schema_version','index_revision','corpus_revision','base_index_revision','base_corpus_revision','staged_at','validation_passed','source_topic_counts.mql5.base','source_topic_counts.mql5.delta','changes.added_count','changes.added_truncated','asset_changes.added_count','asset_changes.cataloged_delta','asset_changes.reduction_requires_review','required_rankings.OnTick.title','required_rankings.OnTick.source');Read={Assert-StagedRevisionReport -Path (Join-Path $testRoot 'report.json') -ExpectedRevision $b}},
        @{Name='legacy-report';Value=$legacy;Path=(Join-Path $testRoot 'legacy-report.json');Fields=@('schema_version','revision','base_revision','staged_at','validation_passed','source_topic_counts.mql5.base','source_topic_counts.mql5.delta','changes.added_count','changes.added_truncated','required_rankings.OnTick.title','required_rankings.OnTick.source');Read={Assert-LegacyStagedRevisionReport -Path (Join-Path $testRoot 'legacy-report.json') -ExpectedCorpusRevision $d}},
        @{Name='repair-manifest';Value=$manifest;Path=(Join-Path $revisionRoot 'manifest.json');Fields=@('schema_version','index_revision','corpus_sha256','database.sha256');Read={Get-RevisionStageReportRepairContext -ProjectRoot $testRoot -RevisionDirectory $revisionRoot}}
    )
    foreach ($case in $cases) {
        Write-Value $case.Path $case.Value
        & $case.Read | Out-Null; $checks++
        foreach ($field in $case.Fields) {
            $target=$case.Value
            foreach ($part in $field.Split('.')) {$target=$target.PSObject.Properties[$part].Value}
            foreach ($kind in @('singleton','multiple','empty','object','wrong-scalar')) {
                $changed=Clone-Value $case.Value
                $replacement=switch ($kind) {
                    'singleton' {,([object[]]@($target))}
                    'multiple' {,([object[]]@($target,$target))}
                    'empty' {,([object[]]@())}
                    'object' {[pscustomobject]@{value=$target}}
                    'wrong-scalar' {if ($target -is [string] -or $null -eq $target) {17} else {[string]$target}}
                }
                Set-Field $changed $field $replacement
                Write-Value $case.Path $changed
                Assert-TypeRejected $case.Read ($case.Name+'.'+$field+' '+$kind)
            }
        }
        Write-Value $case.Path $case.Value
    }
    # A legitimate nested array is data; its elements must still be strings.
    $badIds=Clone-Value $report
    $badIds.changes.added_topic_ids=@(@('mql5:fixture'))
    # Use an explicit nested array because PowerShell can enumerate a literal.
    $badIds.changes.added_topic_ids=[object[]]@(,[object[]]@('mql5:fixture'))
    Write-Value (Join-Path $testRoot 'report.json') $badIds
    Assert-TypeRejected {Assert-StagedRevisionReport -Path (Join-Path $testRoot 'report.json') -ExpectedRevision $b} 'nested topic ID array'

    foreach ($timestamp in @('2026-10-08T00:00:00Z','2026-10-08T00:00:00.1Z','2026-10-08T00:00:00.1234567Z')) {
        Assert-UtcIsoTimestamp $timestamp; $checks++
    }
    foreach ($suffix in @("`n","`r`n","`r",' ',"`t")) {
        $message=''; try {Assert-UtcIsoTimestamp ('2026-10-08T00:00:00Z'+$suffix)} catch {$message=$_.Exception.Message}
        Check ($message -match 'ISO-8601 UTC timestamp') 'Timestamp accepted trailing characters.'
    }
    $timestampRoot=Join-Path $testRoot 'public-transition-timestamp'
    [IO.Directory]::CreateDirectory((Join-Path $timestampRoot 'maintenance')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $timestampRoot 'maintenance\.update.lock'),'',$utf8)
    $timestampTarget=Join-Path $timestampRoot 'maintenance\revision-transition.json'
    $timestampPrepared=Join-Path $timestampRoot ('maintenance\.revision-transition.json.replace.tmp-'+('6'*32))
    $badTimestamp=Clone-Value $transition; $badTimestamp.started_at+="`n"
    Write-Value $timestampPrepared $badTimestamp
    $timestampHash=(Get-FileHash -LiteralPath $timestampPrepared -Algorithm SHA256).Hash
    $preference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $output=& $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Rollback-Documentation.ps1') -ProjectRoot $timestampRoot 2>&1 | Out-String
        $childExit=$LASTEXITCODE
    } finally {$ErrorActionPreference=$preference}
    Check ($childExit -ne 0 -and $output -match 'ISO-8601 UTC timestamp|must have JSON type String') ('Public recovery accepted timestamp suffix: '+$output)
    Check ((Test-Path -LiteralPath $timestampPrepared) -and (Get-FileHash -LiteralPath $timestampPrepared -Algorithm SHA256).Hash -ceq $timestampHash) 'Recovery changed timestamp evidence.'
    Check (-not (Test-Path -LiteralPath $timestampTarget)) 'Malformed timestamp journal became canonical.'

    # Exercise the public recovery entry point with canonical, prepared, and
    # retained-backup evidence. No validation function or mutation is mocked.
    foreach ($kind in @('transition','status','stage','report','legacy-report','repair-manifest')) {
        foreach ($boundary in @('canonical','prepared','backup')) {
            $caseRoot=Join-Path $testRoot ('public-'+$kind+'-'+$boundary)
            [IO.Directory]::CreateDirectory((Join-Path $caseRoot 'maintenance')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $caseRoot 'maintenance\.update.lock'),'',$utf8)
            $caseRevision=if ($kind -ceq 'legacy-report') {$d} else {$b}
            $caseRevisionRoot=Join-Path $caseRoot ('revisions\'+$caseRevision)
            [IO.Directory]::CreateDirectory($caseRevisionRoot) | Out-Null
            Write-Value (Join-Path $caseRoot 'data\active.json') ([ordered]@{schema_version=2;active_revision=$a;previous_revision=$b;activated_at='2026-10-08T00:00:00Z'})
            [IO.File]::WriteAllText((Join-Path $caseRevisionRoot 'mql5-docs.sqlite'),'canonical database evidence',$utf8)
            [IO.Directory]::CreateDirectory((Join-Path $caseRoot 'backups')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $caseRoot 'backups\retained.sqlite'),'retained backup evidence',$utf8)
            $entry=$cases | Where-Object {$_.Name -ceq $kind}
            $invalid=Clone-Value $entry.Value
            $invalid.schema_version=[object[]]@($invalid.schema_version)
            if ($kind -in @('report','legacy-report','repair-manifest')) {
                $validManifest=if ($kind -ceq 'legacy-report') {[pscustomobject]@{schema_version=2;corpus_sha256=$d;database=[pscustomobject]@{sha256=$b}}} else {$manifest}
                Write-Value (Join-Path $caseRevisionRoot 'manifest.json') $validManifest
                $target=Join-Path $caseRevisionRoot 'stage-report.json'
                if ($kind -ceq 'repair-manifest') {$target=Join-Path $caseRevisionRoot 'manifest.json'}
            } else {$target=Join-Path $caseRoot ('maintenance\'+@{transition='revision-transition.json';status='update-status.json';stage='revision-stage.json'}[$kind])}
            $evidence=$target
            if ($boundary -cne 'canonical') {$evidence=Join-Path (Split-Path -Parent $target) ('.'+[IO.Path]::GetFileName($target)+'.replace.'+@{prepared='tmp';backup='backup'}[$boundary]+'-'+('9'*32))}
            Write-Value $evidence $invalid
            if ($boundary -ceq 'canonical' -and $kind -cne 'repair-manifest') {
                # Recovery examines an existing canonical value only when the
                # target has an interrupted atomic publication to reconcile.
                Write-Value (Join-Path (Split-Path -Parent $target) ('.'+[IO.Path]::GetFileName($target)+'.replace.tmp-'+('7'*32))) $entry.Value
            }
            # Manifest evidence is read as the context of a pending stage report.
            if ($kind -ceq 'repair-manifest') {
                if ($boundary -cne 'canonical') {Write-Value $target $invalid}
                Write-Value (Join-Path $caseRevisionRoot ('.stage-report.json.replace.tmp-'+('8'*32))) $report
            }
            $before=@{}
            foreach ($file in Get-ChildItem -LiteralPath $caseRoot -File -Recurse -Force) {$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
            $preference=$ErrorActionPreference
            try {
                $ErrorActionPreference='Continue'
                $output=& $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Rollback-Documentation.ps1') -ProjectRoot $caseRoot 2>&1 | Out-String
                $childExit=$LASTEXITCODE
            } finally {$ErrorActionPreference=$preference}
            Check ($childExit -ne 0 -and $output -match 'must have JSON type') ('Public recovery accepted '+$kind+' '+$boundary+': '+$output)
            foreach ($file in $before.GetEnumerator()) {Check ((Test-Path -LiteralPath $file.Key -PathType Leaf) -and (Get-FileHash -LiteralPath $file.Key -Algorithm SHA256).Hash -ceq $file.Value) ('Recovery changed or removed evidence: '+$file.Key)}
            if ($boundary -cne 'canonical' -and $kind -cne 'repair-manifest') {Check (-not (Test-Path -LiteralPath $target)) ('Invalid recovery evidence became canonical: '+$target)}
        }
    }
    Write-Output ('JSON_SCALAR_TYPE_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
} finally {
    $full=[IO.Path]::GetFullPath($testRoot)
    if (-not $full.StartsWith($parentFull.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Test cleanup escaped its temporary parent.'}
    if (Test-Path -LiteralPath $full) {Remove-Item -LiteralPath $full -Recurse -Force}
}
$global:LASTEXITCODE=0
