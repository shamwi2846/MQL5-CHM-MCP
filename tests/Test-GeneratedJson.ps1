#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('fast','extended')][string]$Tier='fast',[string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\IndexMaintenance.ps1')
$seed=[uint32]1543604851;$state=[uint64]$seed;$checks=0;$cases=if ($Tier -eq 'extended') {4096} else {128}
$root=Join-Path ([IO.Path]::GetTempPath()) ('mql5-generated-json-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$records=New-Object 'System.Collections.Generic.List[object]'
if ($PSVersionTable.PSVersion.Major -eq 7) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Test-ReleaseVersion.ps1'),[ref]$tokens,[ref]$errors)
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-ReleaseJson'},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
$failure=$false
try {
    $canonical=Join-Path $root 'data\active.json';$backup=Join-Path $root 'backups\database.sqlite'
    foreach ($path in @($canonical,$backup)) {[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,'preserved evidence')}
    $original=(Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    for ($i=0;$i -lt $cases;$i++) {
        $state=(1664525*$state+1013904223)%4294967296
        $values=@([int]($state%100),@(),@{items=@('quoted " text',([string][char]0x65e5+[char]0x672c+[char]0x8a9e),@{a=@(1,2)})},$null,$false)
        $object=(@{version='1.3.7';nested=$values;empty=@()} | ConvertTo-Json -Depth 8 -Compress)
        $kind=$i%10;$valid=$kind -in @(0,9)
        $text=switch ($kind) {0 {$object} 1 {'['+$object+']'} 2 {'['+$object+','+$object+']'} 3 {'[]'} 4 {'true'} 5 {[string]$state} 6 {'null'} 7 {'"scalar"'} 8 {'{"broken":'} 9 {$object}}
        $path=Join-Path $root 'maintenance\revision-transition.json'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
        $rejected=$false;try{$value=Read-JsonFile -Path $path -RequireObject}catch{$rejected=$true}
        Assert ($rejected -ne $valid) ('Object-root oracle mismatch at case '+$i)
        if ($valid) {Assert ($value.empty -is [array] -and $value.empty.Count -eq 0 -and $value.nested.Count -eq 5) ('Nested arrays changed at case '+$i)}
        else {$refused=$false;try{Get-RevisionTransition -ProjectRoot $root | Out-Null}catch{$refused=$true};Assert $refused ('Recovery accepted malformed generated evidence '+$i)}
        if ($PSVersionTable.PSVersion.Major -eq 7) {$rejected=$false;try{Read-ReleaseJson -Path $path -Label 'Generated fixture' | Out-Null}catch{$rejected=$true};Assert ($rejected -ne $valid) ('Release reader oracle mismatch at case '+$i)}
        Assert ((Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash -ceq $original -and (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ceq $original -and [IO.File]::ReadAllText($path) -ceq $text) ('Recovery changed canonical files, backup, or pending evidence '+$i)
        $records.Add(@{generator_version=1;seed=$seed;case_number=$i;kind=$kind;expected_object_root=$valid;input_sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();status='passed'})
    }
    if ($OutputDirectory) {
        $dest=[IO.Path]::GetFullPath($OutputDirectory);if(Test-Path -LiteralPath $dest){throw 'Select a new generated-evidence directory.'};[void][IO.Directory]::CreateDirectory($dest)
        [IO.File]::WriteAllText((Join-Path $dest 'generated-json.json'),(@{schema_version=1;generator_version=1;seed=$seed;tier=$Tier;host=$PSVersionTable.PSVersion.ToString();checks=$checks;cases=@($records.ToArray())}|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    }
    Write-Output ('PASS: '+$cases+' generated JSON cases; '+$checks+' checks; host '+$PSVersionTable.PSVersion)
} catch {$failure=$true;Write-Output ('Generated failure retained at '+$root);throw}
finally {if(-not $failure){$absolute=[IO.Path]::GetFullPath($root);if(-not $absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid cleanup root.'};Remove-Item -LiteralPath $absolute -Recurse -Force}}
