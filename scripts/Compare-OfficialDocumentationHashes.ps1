[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [ValidateRange(5,600)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

function Compare-OfficialDocumentationHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateRange(5,600)][int]$TimeoutSeconds = 120,
        [Parameter(DontShow)][scriptblock]$InternalRecordProvider
    )

    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $root
    $checkedAt = [DateTime]::UtcNow.ToString('O')
    $tempBase = Resolve-FullPath -Path ([IO.Path]::GetTempPath()) -MustExist -PathType Container
    Assert-NoReparsePoint -Root $tempBase -Path $tempBase
    $downloadRoot = Join-Path $tempBase ('mql5-chm-freshness-' + [Guid]::NewGuid().ToString('N'))

    try {
        $lockPath = Resolve-FullPath -Path (Join-Path $root 'corpus.lock.json') -MustExist -PathType Leaf
        Assert-NoReparsePoint -Root $root -Path $lockPath
        $lock = Read-JsonFile -Path $lockPath -Context 'tracked corpus lock' -RequireObject
        Assert-ExactJsonProperties -Object $lock -Names @('schema_version','sources','expected_total_topics') -Context 'tracked corpus lock'
        Get-RevisionJsonField $lock 'schema_version' String 'tracked corpus lock' | Out-Null
        Get-RevisionJsonField $lock 'sources' Array 'tracked corpus lock' | Out-Null
        if ([string]$lock.schema_version -cne '1.0' -or @($lock.sources).Count -ne 3) {
            throw 'Tracked corpus lock must use schema 1.0 and describe exactly three sources.'
        }

        $definitions = @(Get-Mql5CorpusDefinition)
        $expectedById = @{}
        foreach ($source in @($lock.sources)) {
            Assert-ExactJsonProperties -Object $source -Names @('id','filename','sha256','expected_topics','role') -Context 'tracked corpus lock source'
            foreach ($name in @('id','filename','sha256')) { Get-RevisionJsonField $source $name String 'tracked corpus lock source' | Out-Null }
            $id = [string]$source.id
            if ([string]::IsNullOrWhiteSpace($id) -or $expectedById.ContainsKey($id)) {
                throw "Tracked corpus lock contains a missing or duplicate source id: '$id'."
            }
            $definition = @($definitions | Where-Object { [string]$_.Id -ceq $id })
            if ($definition.Count -ne 1 -or [string]$source.filename -cne [string]$definition[0].FileName) {
                throw "Tracked corpus lock contains an unknown source or filename: '$id'."
            }
            $expectedHash = ([string]$source.sha256).ToLowerInvariant()
            if ($expectedHash -cnotmatch '^[0-9a-f]{64}$' -or
                $expectedHash -cne ([string]$definition[0].Sha256).ToLowerInvariant()) {
                throw "Tracked corpus lock hash does not match the checked-in source definition: '$id'."
            }
            $expectedById[$id] = [pscustomobject]@{
                Id=$id
                FileName=[string]$source.filename
                Sha256=$expectedHash
            }
        }
        if ($expectedById.Count -ne $definitions.Count) {
            throw 'Tracked corpus lock does not exactly cover the official source definitions.'
        }

        New-Item -ItemType Directory -Path $downloadRoot -ErrorAction Stop | Out-Null
        Write-Host 'Downloading the three official MQL5 CHMs into temporary storage for a read-only hash comparison...'
        $records = if ($null -eq $InternalRecordProvider) {
            @(Get-DownloadedSourceRecords -DownloadRoot $downloadRoot -TimeoutSeconds $TimeoutSeconds)
        } else {
            @(& $InternalRecordProvider $downloadRoot $TimeoutSeconds)
        }
        if ($records.Count -ne $expectedById.Count) {
            throw "Official download results contain $($records.Count) sources; expected $($expectedById.Count)."
        }

        $actualById = @{}
        foreach ($record in $records) {
            $id = [string]$record.Id
            if (-not $expectedById.ContainsKey($id) -or $actualById.ContainsKey($id)) {
                throw "Official download results contain an unknown or duplicate source id: '$id'."
            }
            $actualHash = ([string]$record.Sha256).ToLowerInvariant()
            if ([string]$record.FileName -cne [string]$expectedById[$id].FileName -or
                $actualHash -cnotmatch '^[0-9a-f]{64}$' -or [int64]$record.Bytes -lt 1) {
                throw "Official download result is malformed for source '$id'."
            }
            $actualById[$id] = [pscustomobject]@{
                Id=$id
                FileName=[string]$record.FileName
                Sha256=$actualHash
                Bytes=[int64]$record.Bytes
                HttpLastModified=$record.HttpLastModified
                HttpEtag=$record.HttpEtag
            }
        }

        $reportSources = @($definitions | ForEach-Object {
            $expected = $expectedById[[string]$_.Id]
            $actual = $actualById[[string]$_.Id]
            [pscustomobject]@{
                id=[string]$_.Id
                filename=[string]$expected.FileName
                expected_sha256=[string]$expected.Sha256
                actual_sha256=[string]$actual.Sha256
                bytes=[int64]$actual.Bytes
                http_last_modified=$actual.HttpLastModified
                http_etag=$actual.HttpEtag
                changed=([string]$expected.Sha256 -cne [string]$actual.Sha256)
            }
        })
        $changedSources = @($reportSources | Where-Object { $_.changed })
        $candidateRevision = Get-RevisionFromSourceRecords -SourceRecords $records
        $expectedRecords = @($definitions | ForEach-Object {
            [pscustomobject]@{Id=[string]$_.Id;Sha256=[string]$expectedById[[string]$_.Id].Sha256}
        })
        $expectedRevision = Get-RevisionFromSourceRecords -SourceRecords $expectedRecords
        return [pscustomobject]@{
            schema_version=1
            checked_at=$checkedAt
            status=if ($changedSources.Count -eq 0) { 'up-to-date' } else { 'different-revision-available' }
            expected_corpus_revision=$expectedRevision
            candidate_corpus_revision=$candidateRevision
            sources=$reportSources
            changed_sources=$changedSources
            message=if ($changedSources.Count -eq 0) {
                'The official CHM downloads match the tracked corpus hashes.'
            } else {
                "$($changedSources.Count) official CHM source hash(es) differ from the tracked corpus."
            }
        }
    } catch {
        $message = [regex]::Replace([string]$_.Exception.Message, '[\x00-\x1f\x7f]+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'The official documentation freshness check failed without a diagnostic message.' }
        if ($message.Length -gt 500) { $message = $message.Substring(0,500) }
        return [pscustomobject]@{
            schema_version=1
            checked_at=$checkedAt
            status='check-unavailable'
            expected_corpus_revision=$null
            candidate_corpus_revision=$null
            sources=@()
            changed_sources=@()
            message=$message
        }
    } finally {
        if (Test-Path -LiteralPath $downloadRoot -PathType Container) {
            Remove-SafeDirectory -ConfinementRoot $tempBase -Path $downloadRoot
        }
    }
}

Compare-OfficialDocumentationHashes -ProjectRoot $ProjectRoot -TimeoutSeconds $TimeoutSeconds
