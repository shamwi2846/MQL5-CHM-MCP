#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$expected=(Get-Content -LiteralPath (Join-Path $repo '.github\approved-peer.json') -Raw | ConvertFrom-Json).repository
$reader=Join-Path $PSScriptRoot 'ReadApprovedPeer.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('approved-peer-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$beforeOutput=$env:GITHUB_OUTPUT;$env:GITHUB_OUTPUT=$null;$checks=0
function Assert([bool]$ok,[string]$why){if(-not $ok){throw $why};$script:checks++}
try {
    $record=@{schema_version=1;repository=$expected;version='1.0.0';commit=('a'*40)}
    $path=Join-Path $root 'record.json';$good=$record|ConvertTo-Json -Compress
    foreach($bad in @('[]','[{}]','[{},{}]','null','true','1','"scalar"','{}','{"schema_version":')) {
        [IO.File]::WriteAllText($path,$bad);$failed=$false;try{& $reader -RecordPath $path -ExpectedRepository $expected | Out-Null}catch{$failed=$true};Assert $failed ('Invalid peer root accepted '+$bad)
    }
    foreach($field in @('schema_version','repository','version','commit')){
        $copy=$good|ConvertFrom-Json -AsHashtable;$copy[$field]=switch($field){schema_version {1.0} repository {'other/repository'} version {'01.0.0'} commit {'A'*40}}
        [IO.File]::WriteAllText($path,($copy|ConvertTo-Json -Compress));$failed=$false;try{& $reader -RecordPath $path -ExpectedRepository $expected | Out-Null}catch{$failed=$true};Assert $failed ('Invalid approved field accepted '+$field)
    }
    [IO.File]::WriteAllText($path,$good);& $reader -RecordPath $path -ExpectedRepository $expected | Out-Null;$checks++
    $peer=Join-Path $root 'peer';[void][IO.Directory]::CreateDirectory($peer)
    & git -C $peer init --quiet; & git -C $peer config user.name 'Compatibility fixture'; & git -C $peer config user.email 'fixture@example.invalid'
    [IO.File]::WriteAllText((Join-Path $peer 'version.json'),'{"version":"1.0.0","nested":[1,2]}')
    & git -C $peer add version.json; & git -C $peer commit --quiet -m fixture
    if($LASTEXITCODE -ne 0){throw 'Synthetic Git fixture failed.'}
    $record.commit=(& git -C $peer rev-parse HEAD).Trim();[IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress))
    & $reader -RecordPath $path -ExpectedRepository $expected -PeerRoot $peer -VersionFile version.json | Out-Null;$checks++
    [IO.File]::WriteAllText((Join-Path $peer 'version.json'),'{"version":"2.0.0"}');$failed=$false;try{& $reader -RecordPath $path -ExpectedRepository $expected -PeerRoot $peer -VersionFile version.json | Out-Null}catch{$failed=$true};Assert $failed 'Peer version mismatch accepted'
    $record.commit='b'*40;[IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress));$failed=$false;try{& $reader -RecordPath $path -ExpectedRepository $expected -PeerRoot $peer -VersionFile version.json | Out-Null}catch{$failed=$true};Assert $failed 'Unavailable approved commit accepted'
    Write-Output ('PASS: '+$checks+' approved peer checks')
}finally{$env:GITHUB_OUTPUT=$beforeOutput;$absolute=[IO.Path]::GetFullPath($root);if(-not $absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid cleanup root.'};Remove-Item -LiteralPath $absolute -Recurse -Force}
