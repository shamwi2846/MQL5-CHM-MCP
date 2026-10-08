#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecordPath,[Parameter(Mandatory)][string]$ExpectedRepository,[string]$PeerRoot,[string]$VersionFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$record=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RecordPath)) -AsHashtable -NoEnumerate
if ($record -isnot [Collections.IDictionary] -or @($record.Keys).Count -ne 4 -or
    @($record.Keys | Where-Object {$_ -cnotin @('schema_version','repository','version','commit')}).Count -ne 0 -or
    ($record.schema_version -isnot [int] -and $record.schema_version -isnot [long]) -or $record.schema_version -ne 1 -or
    $record.repository -isnot [string] -or $record.repository -cne $ExpectedRepository -or
    $record.commit -isnot [string] -or $record.commit -cnotmatch '^[0-9a-f]{40}$' -or
    $record.version -isnot [string] -or $record.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {throw 'Invalid approved peer record.'}
if ($PeerRoot) {
    if (-not $VersionFile) {throw 'Peer verification requires its version file.'}
    $commit=(& git -C $PeerRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -cne $record.commit) {throw 'Approved peer checkout commit mismatch.'}
    $version=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PeerRoot $VersionFile))) -AsHashtable -NoEnumerate
    if ($version -isnot [Collections.IDictionary] -or $version.version -isnot [string] -or $version.version -cne $record.version) {throw 'Approved peer package version mismatch.'}
}
if ($env:GITHUB_OUTPUT) {
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT,('commit='+$record.commit+"`n"+'version='+$record.version+"`n"),(New-Object Text.UTF8Encoding($false)))
}
$record | ConvertTo-Json -Compress
