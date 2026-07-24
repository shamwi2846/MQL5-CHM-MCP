Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'SevenZipRuntime.ps1')
. (Join-Path $PSScriptRoot 'StageInstallRecovery.ps1')

function ConvertFrom-SevenZipSltInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string[]]$IndexExtensions,
        [string]$Context = '7-Zip CHM listing'
    )
    $extensionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $IndexExtensions) {
        $normalizedExtension = ([string]$extension).ToLowerInvariant()
        if ($normalizedExtension -cnotmatch '^\.[a-z0-9]+$') { throw "$Context contains an invalid index extension '$extension'." }
        [void]$extensionSet.Add($normalizedExtension)
    }
    foreach ($required in @('.htm','.html','.hhc','.hhk')) {
        if (-not $extensionSet.Contains($required)) { throw "$Context is missing required index extension '$required'." }
    }

    $separator = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ([string]$Lines[$index] -ceq '----------') { $separator = $index; break }
    }
    if ($separator -lt 0) { throw "$Context is invalid: the archive-entry separator is missing." }
    $allowedTailWarning = $false
    for ($index = 0; $index -lt $separator; $index++) {
        if ([string]$Lines[$index] -cne 'WARNINGS:') { continue }
        if ($allowedTailWarning -or $index + 3 -ge $separator -or
            [string]$Lines[$index + 1] -cne 'There are data after the end of archive' -or
            [string]$Lines[$index + 2] -cnotmatch '^Physical Size = \d+$' -or
            [string]$Lines[$index + 3] -cnotmatch '^Tail Size = ([1-9]\d*)$' -or [int64]$Matches[1] -gt 1048576) {
            throw "$Context reports an unsupported archive warning."
        }
        $allowedTailWarning = $true
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $record = @{}
    for ($index = $separator + 1; $index -le $Lines.Count; $index++) {
        $line = if ($index -eq $Lines.Count) { '' } else { [string]$Lines[$index] }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($record.Count -gt 0) { [void]$records.Add([hashtable]$record); $record = @{} }
            continue
        }
        if ($record.Count -eq 0 -and $line -match '^Warnings: 0$') {
            if ($allowedTailWarning) { throw "$Context warning header conflicts with its zero-warning summary." }
            break
        }
        if ($record.Count -eq 0 -and $line -match '^Warnings: 1$') {
            if (-not $allowedTailWarning) { throw "$Context reports an unsupported archive-listing warning." }
            break
        }
        if ($record.Count -eq 0 -and $line -match '^Warnings: [2-9]\d*$') { throw "$Context reports multiple archive-listing warnings: $line" }
        if ($record.Count -eq 0 -and $line -match '^Errors: [1-9]\d*$') { throw "$Context reports archive-listing errors: $line" }
        if ($line -notmatch '^([^=]+?) = (.*)$') { throw "$Context contains an invalid archive record line: $line" }
        $name = $Matches[1].Trim(); $value = $Matches[2]
        if ($record.ContainsKey($name)) { throw "$Context contains duplicate '$name' fields in one archive record." }
        $record[$name] = $value
    }
    if ($records.Count -eq 0) { throw "$Context contains no archive entries." }

    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $invalidNameCharacters = [IO.Path]::GetInvalidFileNameChars()
    [int]$htmlCount = 0
    foreach ($archiveRecord in $records) {
        if (-not $archiveRecord.ContainsKey('Path') -or -not $archiveRecord.ContainsKey('Size')) { throw "$Context contains an invalid archive record without Path and Size." }
        $archivePath = [string]$archiveRecord['Path']
        if ([string]::IsNullOrWhiteSpace($archivePath) -or $archivePath.IndexOf([char]0) -ge 0 -or $archivePath -match '[\x00-\x1f]') { throw "$Context contains an invalid archive path." }
        $normalizedPath = $archivePath.Replace('\','/')
        if ($normalizedPath.StartsWith('/') -or $normalizedPath.StartsWith('//') -or $normalizedPath -match '^[A-Za-z]:') { throw "$Context contains a rooted archive path: $archivePath" }
        $segments = @($normalizedPath.Split([char]'/'))
        if ($segments.Count -eq 0 -or @($segments | Where-Object { [string]::IsNullOrEmpty($_) }).Count -gt 0) { throw "$Context contains an invalid archive path: $archivePath" }
        if (@($segments | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) { throw "$Context contains a traversal archive path: $archivePath" }
        foreach ($segment in $segments) {
            if ($segment.IndexOfAny($invalidNameCharacters) -ge 0 -or $segment.EndsWith(' ') -or $segment.EndsWith('.') -or $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
                throw "$Context contains an invalid archive path: $archivePath"
            }
        }

        $existing = $null
        if ($seen.TryGetValue($normalizedPath, [ref]$existing)) {
            if ([string]$existing -ceq $normalizedPath) { throw "$Context contains a duplicate archive path: $normalizedPath" }
            throw "$Context contains a case collision between '$existing' and '$normalizedPath'."
        }
        $seen.Add($normalizedPath, $normalizedPath)

        $sizeText = [string]$archiveRecord['Size']; [int64]$size = 0
        if ($sizeText -cnotmatch '^\d+$' -or -not [int64]::TryParse($sizeText, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)) {
            throw "$Context contains an invalid size for '$normalizedPath': $sizeText"
        }
        $extension = [IO.Path]::GetExtension($normalizedPath).ToLowerInvariant()
        if ($extensionSet.Contains($extension)) {
            [void]$entries.Add([pscustomobject]@{ Path=$normalizedPath; Size=$size })
            if ($extension -ceq '.htm' -or $extension -ceq '.html') { $htmlCount++ }
        }
    }
    if ($htmlCount -le 0) { throw "$Context contains no HTML topics." }
    return [pscustomobject]@{ Entries=@($entries | Sort-Object Path); Extensions=@($extensionSet | Sort-Object); HtmlCount=$htmlCount }
}

function Get-ChmIndexInputExtensions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $policy = Read-JsonFile -Path (Join-Path $root 'config\mql5-image-policy.json') -Context 'MQL5 image policy'
    $catalogProperty = $policy.PSObject.Properties['catalog_extensions']
    if ($null -eq $catalogProperty -or $catalogProperty.Value -is [string] -or -not ($catalogProperty.Value -is [Collections.IEnumerable])) {
        throw 'MQL5 image policy catalog_extensions must be an array.'
    }
    $extensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($required in @('.htm','.html','.hhc','.hhk')) { [void]$extensions.Add($required) }
    foreach ($extension in @($catalogProperty.Value)) {
        $value = ([string]$extension).ToLowerInvariant()
        if ($value -cnotmatch '^\.[a-z0-9]+$') { throw "MQL5 image policy contains invalid catalog extension '$extension'." }
        if (-not $extensions.Add($value)) { throw "MQL5 image policy contains duplicate catalog extension '$extension'." }
    }
    return @($extensions | Sort-Object)
}

function Get-ChmIndexInputInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$ChmPath
    )
    $extractor = Resolve-FullPath -Path $SevenZip -MustExist -PathType Leaf
    $archive = Resolve-FullPath -Path $ChmPath -MustExist -PathType Leaf
    $listing = Invoke-NativeCapture -FilePath $extractor -Arguments @('l','-slt',$archive)
    if ($listing.ExitCode -ne 0) { throw "Could not enumerate CHM contents before extraction: $archive. $($listing.Text)" }
    $extensions = Get-ChmIndexInputExtensions -ProjectRoot $ProjectRoot
    return ConvertFrom-SevenZipSltInventory -Lines $listing.Lines -IndexExtensions $extensions -Context "CHM directory listing '$archive'"
}

function Get-ExtractionClosureState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Inventory)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason='candidate directory does not exist' } }
    $root = Resolve-FullPath -Path $Path -MustExist -PathType Container
    $reparse = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparse.Count -gt 0) { throw "Extraction candidate contains a reparse point: $($reparse[0].FullName)" }

    $extensionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in @($Inventory.Extensions)) { [void]$extensionSet.Add(([string]$extension).ToLowerInvariant()) }
    $expected = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Inventory.Entries)) {
        $entryPath = [string]$entry.Path
        if ($expected.ContainsKey($entryPath)) { throw "Extraction inventory contains a duplicate path: $entryPath" }
        $expected.Add($entryPath, $entry)
    }
    $actual = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop) {
        if (-not $extensionSet.Contains($file.Extension.ToLowerInvariant())) { continue }
        $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($actual.ContainsKey($relative)) { throw "Extraction candidate contains a case-colliding path: $relative" }
        $actual.Add($relative, $file)
        if (-not $expected.ContainsKey($relative)) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="unexpected index input '$relative'" } }
    }
    if ($actual.Count -ne $expected.Count) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="expected $($expected.Count) index inputs but found $($actual.Count)" } }

    $builder = [Text.StringBuilder]::new(); $fileSha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in @($Inventory.Entries | Sort-Object Path)) {
            $entryPath = [string]$entry.Path; $file = $null
            if (-not $actual.TryGetValue($entryPath, [ref]$file)) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="missing index input '$entryPath'" } }
            $expectedSize = [int64]$entry.Size
            if ([int64]$file.Length -ne $expectedSize) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="size mismatch for '$entryPath'" } }
            $stream = $null
            try {
                $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                $fileSha.Initialize(); $fileHash = ([BitConverter]::ToString($fileSha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
            } catch {
                return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="could not hash '$entryPath'" }
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
            $afterHash = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            if ([int64]$afterHash.Length -ne $expectedSize) { return [pscustomobject]@{ Complete=$false; Digest=$null; HtmlCount=0; Reason="size changed while hashing '$entryPath'" } }
            [void]$builder.Append($entryPath).Append([char]0).Append($expectedSize).Append([char]0).Append($fileHash).Append("`n")
        }
    } finally { $fileSha.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString())))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return [pscustomobject]@{ Complete=$true; Digest=$digest; HtmlCount=[int]$Inventory.HtmlCount; Reason='' }
}

function Wait-ExtractionStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Inventory,
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 300,
        [ValidateRange(2,20)][int]$StablePolls = 2,
        [ValidateRange(1,1000)][int]$PollMilliseconds = 250
    )
    $timer = [Diagnostics.Stopwatch]::StartNew(); $lastDigest = $null; $stableSamples = 0; $lastReason = 'not inspected'
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $state = Get-ExtractionClosureState -Path $Path -Inventory $Inventory
        $lastReason = [string]$state.Reason
        if ([bool]$state.Complete) {
            if ($null -ne $lastDigest -and [string]$state.Digest -ceq [string]$lastDigest) { $stableSamples++ } else { $lastDigest = [string]$state.Digest; $stableSamples = 1 }
            if ($stableSamples -ge $StablePolls) { return $state }
        } else {
            $lastDigest = $null; $stableSamples = 0
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "Extraction did not reach a stable exact index-input closure within $TimeoutSeconds seconds: $Path. Last state: $lastReason"
}

function New-VerifiedExtractionSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$SnapshotRoot,
        [Parameter(Mandatory)][object]$Inventory,
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 300,
        [ValidateRange(2,20)][int]$StablePolls = 2,
        [ValidateRange(1,1000)][int]$PollMilliseconds = 250,
        [scriptblock]$AfterCopyHook
    )
    $candidate = Resolve-FullPath -Path $CandidatePath -MustExist -PathType Container
    $snapshotRootFull = Resolve-FullPath -Path $SnapshotRoot -MustExist -PathType Container
    $stable = Wait-ExtractionStable -Path $candidate -Inventory $Inventory -TimeoutSeconds $TimeoutSeconds -StablePolls $StablePolls -PollMilliseconds $PollMilliseconds
    $snapshot = Assert-PathWithin -Root $snapshotRootFull -Path (Join-Path $snapshotRootFull ('.extract-snapshot-' + [Guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $snapshot -ErrorAction Stop | Out-Null
        foreach ($entry in @($Inventory.Entries | Sort-Object Path)) {
            $relative = ([string]$entry.Path).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $source = Join-Path $candidate $relative; $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Extraction input is not a regular file: $source" }
            $target = Join-Path $snapshot $relative; $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
            Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            if ($null -ne $AfterCopyHook) { & $AfterCopyHook $source $target $entry }
        }
        $copied = Get-ExtractionClosureState -Path $snapshot -Inventory $Inventory
        if (-not [bool]$copied.Complete -or [string]$copied.Digest -cne [string]$stable.Digest) { throw 'Extraction source changed while its immutable snapshot was being created.' }
        return [pscustomobject]@{ Path=$snapshot; Digest=[string]$copied.Digest; HtmlCount=[int]$copied.HtmlCount }
    } catch {
        if (Test-Path -LiteralPath $snapshot -PathType Container) { Remove-SafeDirectory -ConfinementRoot $snapshotRootFull -Path $snapshot }
        throw
    }
}

function Resolve-SevenZipExtractor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    return [string](Ensure-PinnedSevenZipRuntime -ProjectRoot $Root).Extractor
}

function Get-ChmHtmlTopicCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$ChmPath,
        [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
    )
    return [int](Get-ChmIndexInputInventory -ProjectRoot $ProjectRoot -SevenZip $SevenZip -ChmPath $ChmPath).HtmlCount
}

function ConvertTo-WindowsNativeArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-NativeDiagnosticTail {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text,[ValidateRange(1,32768)][int]$MaximumCharacters = 4096)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -le $MaximumCharacters) { return $trimmed }
    return '[output tail] ' + $trimmed.Substring($trimmed.Length - $MaximumCharacters)
}

function Invoke-NativeProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateRange(1,1800)][int]$TimeoutSeconds,
        [string]$FailureMessage = 'Native process failed.'
    )
    $executable = Resolve-FullPath -Path $FilePath -MustExist -PathType Leaf
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsNativeArgument -Value ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw "Could not start native process: $executable" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
            } catch {
                throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline and could not be terminated: $executable", $_.Exception)
            }
            if (-not $process.WaitForExit(5000)) {
                throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline and did not terminate: $executable")
            }
            throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline: $executable")
        }
        $process.WaitForExit()
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $diagnostic = Get-NativeDiagnosticTail -Text (($stdout,$stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine)
        if ($process.ExitCode -ne 0) {
            $suffix = if ([string]::IsNullOrWhiteSpace($diagnostic)) { '' } else { " $diagnostic" }
            throw "$FailureMessage Exit code: $($process.ExitCode).$suffix"
        }
        return [pscustomobject]@{ExitCode=[int]$process.ExitCode;Text=$diagnostic}
    } finally {
        $process.Dispose()
    }
}

function Invoke-HtmlHelpExtraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HtmlHelpPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ArchivePath,
        [ValidateRange(1,300)][int]$TimeoutSeconds
    )
    Invoke-NativeProcessWithTimeout -FilePath $HtmlHelpPath -Arguments @('-decompile',$Destination,$ArchivePath) -TimeoutSeconds $TimeoutSeconds -FailureMessage 'hh.exe extraction failed.' | Out-Null
}

function Invoke-SevenZipExtraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$SourceName,
        [ValidateRange(1,1800)][int]$TimeoutSeconds
    )
    Invoke-NativeProcessWithTimeout -FilePath $SevenZip -Arguments @('x','-y',"-o$Destination",$ArchivePath) -TimeoutSeconds $TimeoutSeconds -FailureMessage "7-Zip extraction failed for '$SourceName'." | Out-Null
}

function Remove-ExtractionTemporaryDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtractionRoot, [AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try { Remove-SafeDirectory -ConfinementRoot $ExtractionRoot -Path $Path } catch { Write-Warning "Could not remove owned extraction temporary directory '$Path': $($_.Exception.Message)" }
}

function Invoke-ChmExtraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingRoot,
        [Parameter(Mandatory)][object]$SourceRecord,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SevenZip,
        [ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
        [ValidateRange(10,300)][int]$HhTimeoutSeconds = 60,
        [switch]$SkipHtmlHelp
    )
    $sourceDirectory = Resolve-FullPath -Path (Join-Path $WorkingRoot 'sources') -MustExist -PathType Container
    $extractedDirectory = Resolve-FullPath -Path (Join-Path $WorkingRoot 'extracted') -MustExist -PathType Container
    $destination = Assert-PathWithin -Root $extractedDirectory -Path (Join-Path $extractedDirectory $SourceRecord.Id)
    if (Test-Path -LiteralPath $destination) { Remove-SafeDirectory -ConfinementRoot $extractedDirectory -Path $destination }
    if ([string]::IsNullOrWhiteSpace($SevenZip)) { throw "A CHM-capable 7-Zip executable is required to independently enumerate '$($SourceRecord.FileName)' before extraction." }
    $archivePath = Join-Path $sourceDirectory $SourceRecord.FileName
    $inventory = Get-ChmIndexInputInventory -ProjectRoot $ProjectRoot -SevenZip $SevenZip -ChmPath $archivePath
    if ($null -ne $SourceRecord.TopicCount -and [int]$inventory.HtmlCount -ne [int]$SourceRecord.TopicCount) {
        throw "CHM directory listing for '$($SourceRecord.FileName)' contains $($inventory.HtmlCount) HTML topics; expected $($SourceRecord.TopicCount)."
    }
    $hhCandidate = $null; $sevenZipCandidate = $null; $snapshotPath = $null; $published = $false
    try {
        $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $hh = if ([string]::IsNullOrWhiteSpace($windowsRoot)) { '' } else { Join-Path $windowsRoot 'hh.exe' }
        if (-not $SkipHtmlHelp -and (Test-Path -LiteralPath $hh -PathType Leaf)) {
            $hhCandidate = Assert-PathWithin -Root $extractedDirectory -Path (Join-Path $extractedDirectory ('.extract-' + $SourceRecord.Id + '-hh-' + [Guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $hhCandidate -ErrorAction Stop | Out-Null
            try {
                $hhTimer = [Diagnostics.Stopwatch]::StartNew()
                Invoke-HtmlHelpExtraction -HtmlHelpPath $hh -Destination $hhCandidate -ArchivePath $archivePath -TimeoutSeconds $HhTimeoutSeconds
                $hhRemaining = [int][Math]::Floor($HhTimeoutSeconds - $hhTimer.Elapsed.TotalSeconds)
                if ($hhRemaining -lt 1) { throw "hh.exe extraction exceeded its $HhTimeoutSeconds-second deadline." }
                $snapshot = New-VerifiedExtractionSnapshot -CandidatePath $hhCandidate -SnapshotRoot $extractedDirectory -Inventory $inventory -TimeoutSeconds $hhRemaining
                $snapshotPath = [string]$snapshot.Path
                if (Test-Path -LiteralPath $destination) { throw "Extraction destination appeared before publication: $destination" }
                [IO.Directory]::Move($snapshotPath, $destination); $snapshotPath = $null; $published = $true
            } catch {
                Write-Warning "hh.exe extraction was incomplete for '$($SourceRecord.FileName)'; using isolated 7-Zip fallback. $($_.Exception.Message)"
            }
        }
        if (-not $published) {
            $sevenZipCandidate = Assert-PathWithin -Root $extractedDirectory -Path (Join-Path $extractedDirectory ('.extract-' + $SourceRecord.Id + '-7z-' + [Guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $sevenZipCandidate -ErrorAction Stop | Out-Null
            $sevenZipTimer = [Diagnostics.Stopwatch]::StartNew()
            Invoke-SevenZipExtraction -SevenZip $SevenZip -Destination $sevenZipCandidate -ArchivePath $archivePath -SourceName ([string]$SourceRecord.FileName) -TimeoutSeconds $ExtractionTimeoutSeconds
            $sevenZipRemaining = [int][Math]::Floor($ExtractionTimeoutSeconds - $sevenZipTimer.Elapsed.TotalSeconds)
            if ($sevenZipRemaining -lt 1) { throw "7-Zip extraction exceeded its $ExtractionTimeoutSeconds-second deadline for '$($SourceRecord.FileName)'." }
            $snapshot = New-VerifiedExtractionSnapshot -CandidatePath $sevenZipCandidate -SnapshotRoot $extractedDirectory -Inventory $inventory -TimeoutSeconds $sevenZipRemaining
            $snapshotPath = [string]$snapshot.Path
            if (Test-Path -LiteralPath $destination) { throw "Extraction destination appeared before publication: $destination" }
            [IO.Directory]::Move($snapshotPath, $destination); $snapshotPath = $null; $published = $true
        }
        return [int]$inventory.HtmlCount
    } finally {
        Remove-ExtractionTemporaryDirectory -ExtractionRoot $extractedDirectory -Path $snapshotPath
        Remove-ExtractionTemporaryDirectory -ExtractionRoot $extractedDirectory -Path $hhCandidate
        Remove-ExtractionTemporaryDirectory -ExtractionRoot $extractedDirectory -Path $sevenZipCandidate
    }
}

function Get-SourceRecordsFromActiveRevision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $validated = Assert-ManifestAndCorpus -ProjectRoot $ProjectRoot
    $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $source = $validated.Manifest.sources.PSObject.Properties[$definition.Id].Value
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=(Join-Path $validated.Root $definition.FileName)
            Sha256=[string]$source.sha256; Bytes=[int64]$source.bytes; TopicCount=[int]$source.topic_count
            HttpLastModified=$source.http_last_modified; HttpEtag=$source.http_etag; RetrievedAt=[string]$source.retrieved_at
        }
    }
    return $records
}

function Get-SourceRecordsFromRootMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container; $acceptedAt = [DateTime]::UtcNow.ToString('O'); $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $path = Join-Path $root $definition.FileName
        $hash = Assert-FileSha256 -Path $path -Expected $definition.Sha256
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=$path; Sha256=$hash; Bytes=(Get-Item -LiteralPath $path).Length
            TopicCount=$definition.TopicCount; HttpLastModified=$null; HttpEtag=$null; RetrievedAt=$acceptedAt
        }
    }
    return $records
}

function Get-DownloadedSourceRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DownloadRoot, [ValidateRange(5,600)][int]$TimeoutSeconds = 120)
    $records = @()
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $result = Invoke-OfficialChmDownload -Uri ([uri]$definition.DownloadUri) -Destination (Join-Path $DownloadRoot $definition.FileName) -MinimumBytes $definition.MinimumBytes -MaximumBytes $definition.MaximumBytes -TimeoutSeconds $TimeoutSeconds
        $records += [pscustomobject]@{
            Id=$definition.Id; FileName=$definition.FileName; Path=$result.Path; Sha256=$result.Sha256; Bytes=$result.Bytes
            TopicCount=$null; HttpLastModified=$result.HttpLastModified; HttpEtag=$result.HttpEtag; RetrievedAt=$result.RetrievedAt
        }
    }
    return $records
}

function Get-RevisionFromSourceRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SourceRecords)
    $hashes = [pscustomobject]@{}
    foreach ($record in $SourceRecords) { $hashes | Add-Member -NotePropertyName $record.Id -NotePropertyValue ([string]$record.Sha256) }
    return Get-CorpusRevision -SourceHashes $hashes
}

function New-CorpusLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SourceRecords, [Parameter(Mandatory)][hashtable]$TopicCounts)
    $sources = @(); $total = 0
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $record = @($SourceRecords | Where-Object Id -eq $definition.Id)
        if ($record.Count -ne 1) { throw "Expected one source record for '$($definition.Id)'." }
        $count = [int]$TopicCounts[$definition.Id]; if ($count -le 0) { throw "Topic count is invalid for '$($definition.Id)'." }; $total += $count
        $sources += [ordered]@{
            id=$definition.Id; filename=$definition.FileName; sha256=([string]$record[0].Sha256).ToLowerInvariant(); expected_topics=$count
            bytes=[int64]$record[0].Bytes; http_last_modified=$record[0].HttpLastModified; http_etag=$record[0].HttpEtag; retrieved_at=[string]$record[0].RetrievedAt
        }
    }
    return [ordered]@{ schema_version='1.1'; sources=$sources; expected_total_topics=$total }
}

function Resolve-Indexer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    foreach ($candidate in @((Join-Path $ProjectRoot 'src\indexer.mjs'),(Join-Path $ProjectRoot 'app\indexer.mjs'))) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return Resolve-FullPath -Path $candidate -MustExist -PathType Leaf } }
    throw 'No MQL5 CHM indexer was found.'
}

function Assert-DatabaseInspectionResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inspection, [switch]$RequireAssets)
    if (@($Inspection.integrity).Count -ne 1 -or [string]$Inspection.integrity[0] -ne 'ok') { throw 'SQLite integrity_check did not return ok.' }
    if ([int]$Inspection.topic_count -le 0 -or [int]$Inspection.fts_count -ne [int]$Inspection.section_count) { throw 'SQLite topic/section/FTS counts are inconsistent.' }
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $property = $Inspection.ranking.PSObject.Properties[$query]
        $row = if ($null -eq $property) { $null } else { $property.Value }
        if ($null -eq $row -or [string]$row.source -ne 'mql5' -or [string]$row.title -ne $query) { throw "Exact API ranking acceptance failed for '$query'." }
    }
    if ($RequireAssets) {
        if (-not [bool]$Inspection.has_assets -or [int]$Inspection.asset_count -le 0 -or [int]$Inspection.topic_asset_count -le 0) { throw 'SQLite asset catalog is missing or empty.' }
        if ([int]$Inspection.invalid_asset_count -ne 0 -or [int]$Inspection.invalid_topic_asset_count -ne 0) { throw 'SQLite asset catalog failed relational acceptance checks.' }
        if ([string]$Inspection.metadata.schema_version -cne '3' -or [string]$Inspection.metadata.index_contract -cne $script:IndexContract) { throw 'SQLite asset index contract metadata is invalid.' }
        foreach ($name in @('image_policy_sha256','asset_catalog_sha256','asset_tree_sha256')) { if ([string]$Inspection.metadata.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "SQLite metadata $name is invalid." } }
    }
    return $Inspection
}

function Invoke-DatabaseInspection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NodePath, [Parameter(Mandatory)][string]$DatabasePath, [switch]$RequireAssets)
    $inspector = Resolve-FullPath -Path (Join-Path $PSScriptRoot 'inspect-database.mjs') -MustExist -PathType Leaf
    $database = Resolve-FullPath -Path $DatabasePath -MustExist -PathType Leaf
    $result = Invoke-NativeCapture -FilePath $NodePath -Arguments @('--no-warnings',$inspector,$database)
    if ($result.ExitCode -ne 0) { throw "Database inspection failed. $($result.Text)" }
    try { $inspection = $result.Text | ConvertFrom-Json -ErrorAction Stop } catch { throw "Database inspection returned invalid JSON. $($_.Exception.Message)" }
    return Assert-DatabaseInspectionResult -Inspection $inspection -RequireAssets:$RequireAssets
}

function Get-TopicChangeReport {
    [CmdletBinding()]
    param([AllowNull()][object]$BaseInspection, [Parameter(Mandatory)][object]$CandidateInspection, [int]$MaximumIds = 200)
    $base = @{}; if ($null -ne $BaseInspection) { foreach ($property in $BaseInspection.topics.PSObject.Properties) { $base[$property.Name] = [string]$property.Value } }
    $candidate = @{}; foreach ($property in $CandidateInspection.topics.PSObject.Properties) { $candidate[$property.Name] = [string]$property.Value }
    $added = @($candidate.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
    $removed = @($base.Keys | Where-Object { -not $candidate.ContainsKey($_) } | Sort-Object)
    $changed = @($candidate.Keys | Where-Object { $base.ContainsKey($_) -and $base[$_] -cne $candidate[$_] } | Sort-Object)
    return [ordered]@{
        added_count=$added.Count; removed_count=$removed.Count; changed_count=$changed.Count
        added_topic_ids=@($added | Select-Object -First $MaximumIds); removed_topic_ids=@($removed | Select-Object -First $MaximumIds); changed_topic_ids=@($changed | Select-Object -First $MaximumIds)
        added_truncated=($added.Count -gt $MaximumIds); removed_truncated=($removed.Count -gt $MaximumIds); changed_truncated=($changed.Count -gt $MaximumIds)
    }
}

function Get-AssetChangeReport {
    [CmdletBinding()]
    param([AllowNull()][object]$BaseInspection, [Parameter(Mandatory)][object]$CandidateInspection, [int]$MaximumIds = 200)
    $base = @{}
    if ($null -ne $BaseInspection -and $null -ne $BaseInspection.PSObject.Properties['assets']) {
        foreach ($property in $BaseInspection.assets.PSObject.Properties) { $base[$property.Name] = ($property.Value | ConvertTo-Json -Compress -Depth 20) }
    }
    $candidate = @{}
    foreach ($property in $CandidateInspection.assets.PSObject.Properties) { $candidate[$property.Name] = ($property.Value | ConvertTo-Json -Compress -Depth 20) }
    $added = @($candidate.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
    $removed = @($base.Keys | Where-Object { -not $candidate.ContainsKey($_) } | Sort-Object)
    $changed = @($candidate.Keys | Where-Object { $base.ContainsKey($_) -and $base[$_] -cne $candidate[$_] } | Sort-Object)
    $emptySummary = [pscustomobject]@{ cataloged_count=0; exposed_count=0; excluded_count=0; occurrence_count=0; exposed_occurrence_count=0; total_bytes=0 }
    $baseSummary = if ($null -ne $BaseInspection -and $null -ne $BaseInspection.PSObject.Properties['asset_summary']) { $BaseInspection.asset_summary } else { $emptySummary }
    $candidateSummary = $CandidateInspection.asset_summary
    $baseCataloged = [int]$baseSummary.cataloged_count; $candidateCataloged = [int]$candidateSummary.cataloged_count
    $baseExposed = [int]$baseSummary.exposed_count; $candidateExposed = [int]$candidateSummary.exposed_count
    $baseOccurrences = [int]$baseSummary.occurrence_count; $candidateOccurrences = [int]$candidateSummary.occurrence_count
    $baseExposedOccurrences = [int]$baseSummary.exposed_occurrence_count; $candidateExposedOccurrences = [int]$candidateSummary.exposed_occurrence_count
    return [ordered]@{
        added_count=$added.Count; removed_count=$removed.Count; changed_count=$changed.Count
        added_asset_ids=@($added | Select-Object -First $MaximumIds); removed_asset_ids=@($removed | Select-Object -First $MaximumIds); changed_asset_ids=@($changed | Select-Object -First $MaximumIds)
        added_truncated=($added.Count -gt $MaximumIds); removed_truncated=($removed.Count -gt $MaximumIds); changed_truncated=($changed.Count -gt $MaximumIds)
        base_cataloged_count=$baseCataloged; candidate_cataloged_count=$candidateCataloged; cataloged_delta=($candidateCataloged-$baseCataloged)
        base_exposed_count=$baseExposed; candidate_exposed_count=$candidateExposed; exposed_delta=($candidateExposed-$baseExposed)
        candidate_excluded_count=[int]$candidateSummary.excluded_count
        base_occurrence_count=$baseOccurrences; candidate_occurrence_count=$candidateOccurrences; occurrence_delta=($candidateOccurrences-$baseOccurrences)
        base_exposed_occurrence_count=$baseExposedOccurrences; candidate_exposed_occurrence_count=$candidateExposedOccurrences; exposed_occurrence_delta=($candidateExposedOccurrences-$baseExposedOccurrences)
        candidate_total_bytes=[int64]$candidateSummary.total_bytes
        unsupported_count=0; oversized_count=0; unresolved_count=0; unclassified_count=0
        reduction_requires_review=($removed.Count -gt 0 -or $candidateExposed -lt $baseExposed -or $candidateOccurrences -lt $baseOccurrences -or $candidateExposedOccurrences -lt $baseExposedOccurrences)
    }
}

function Assert-AssetChangeReportMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Reported,
        [Parameter(Mandatory)][object]$Recomputed,
        [switch]$AcceptAssetReduction
    )
    $reportedJson = $Reported | ConvertTo-Json -Compress -Depth 30
    $recomputedJson = $Recomputed | ConvertTo-Json -Compress -Depth 30
    if ($reportedJson -cne $recomputedJson) { throw 'The staged asset-change report no longer matches the verified base and candidate indexes.' }
    if ([bool]$Recomputed.reduction_requires_review -and -not $AcceptAssetReduction) {
        throw 'The candidate reduces cataloged/exposed image or exposed-occurrence coverage. Review the stage report and retry with -AcceptAssetReduction.'
    }
    return $Recomputed
}

function Assert-StagedReportMatchesVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [AllowNull()][object]$BaseRevision,
        [Parameter(Mandatory)][object]$CandidateRevision,
        [AllowNull()][object]$BaseInspection,
        [Parameter(Mandatory)][object]$CandidateInspection,
        [switch]$AcceptAssetReduction
    )
    # Re-run the identity determinism gate at every semantic acceptance
    # boundary. This protects Apply and interrupted-stage recovery from a
    # candidate staged by an older build that did not yet enforce the gate.
    if ($null -ne $BaseRevision) {
        [void](Assert-DeterministicRebuildResult -BaseRevision $BaseRevision -CandidateRevision $CandidateRevision)
    }
    $topicChanges = if ($null -eq $BaseRevision) {
        Get-TopicChangeReport -BaseInspection $null -CandidateInspection $CandidateInspection
    } else {
        Assert-NoRevisionTopicLoss -BaseRevision $BaseRevision -CandidateRevision $CandidateRevision -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection -Context 'activation'
    }
    if (($Report.changes | ConvertTo-Json -Compress -Depth 30) -cne ($topicChanges | ConvertTo-Json -Compress -Depth 30)) {
        throw 'The staged topic-change report no longer matches the verified base and candidate indexes.'
    }
    $assetChanges = Get-AssetChangeReport -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection
    Assert-AssetChangeReportMatches -Reported $Report.asset_changes -Recomputed $assetChanges -AcceptAssetReduction:$AcceptAssetReduction | Out-Null
    $sourceCounts = [ordered]@{}
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $baseCount = if ($null -eq $BaseRevision) { 0 } else { [int]$BaseRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count }
        $candidateCount = [int]$CandidateRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        $sourceCounts[$definition.Id] = [ordered]@{ base=$baseCount; candidate=$candidateCount; delta=($candidateCount-$baseCount) }
    }
    if (($Report.source_topic_counts | ConvertTo-Json -Compress -Depth 20) -cne ($sourceCounts | ConvertTo-Json -Compress -Depth 20)) {
        throw 'The staged per-source topic counts no longer match the verified revisions.'
    }
    $rankings = [ordered]@{}
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $row = $CandidateInspection.ranking.PSObject.Properties[$query].Value
        $rankings[$query] = [ordered]@{ title=[string]$row.title; source=[string]$row.source }
    }
    if (($Report.required_rankings | ConvertTo-Json -Compress -Depth 20) -cne ($rankings | ConvertTo-Json -Compress -Depth 20)) {
        throw 'The staged representative-ranking report no longer matches the verified index.'
    }
    return [pscustomobject]@{ TopicChanges=$topicChanges; AssetChanges=$assetChanges; SourceTopicCounts=$sourceCounts; RequiredRankings=$rankings }
}

function Assert-CandidateActivationAccepted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CandidateIndexRevision,
        [AllowNull()][object]$BaseRevision,
        [AllowNull()][string]$NodePath,
        [switch]$AcceptAssetReduction,
        [switch]$RequireCurrentSources,
        [switch]$RequireCurrentPolicy
    )
    $candidateParameters = @{
        ProjectRoot=$ProjectRoot
        Revision=$CandidateIndexRevision
        IdentityMode='Index'
        RequireCurrent=$true
    }
    if ($RequireCurrentSources) { $candidateParameters.RequireCurrentSources = $true }
    if ($RequireCurrentPolicy) { $candidateParameters.RequireCurrentPolicy = $true }
    $candidate = Assert-Revision @candidateParameters
    $report = Assert-StagedRevisionReport -Path (Join-Path $candidate.Root 'stage-report.json') -ExpectedRevision $CandidateIndexRevision
    if ([string]$report.corpus_revision -cne [string]$candidate.CorpusRevision) {
        throw 'The staged report candidate corpus revision is invalid.'
    }
    if ($null -eq $BaseRevision) {
        if ($null -ne $report.base_index_revision -or $null -ne $report.base_corpus_revision) {
            throw 'Initial staged index unexpectedly declares a validation base.'
        }
    } elseif (
        [string]$report.base_index_revision -cne [string]$BaseRevision.IndexRevision -or
        [string]$report.base_corpus_revision -cne [string]$BaseRevision.CorpusRevision
    ) {
        throw 'The staged index was validated against a different active base. Stage it again before applying or packaging.'
    }

    $node = if ([string]::IsNullOrWhiteSpace($NodePath)) {
        Resolve-NodeExecutable -ProjectRoot $ProjectRoot
    } else {
        $NodePath
    }
    $baseInspection = if ($null -eq $BaseRevision) {
        $null
    } else {
        Invoke-DatabaseInspection -NodePath $node -DatabasePath $BaseRevision.DatabasePath
    }
    $candidateInspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $candidate.DatabasePath -RequireAssets
    $verifiedReport = Assert-StagedReportMatchesVerification `
        -Report $report `
        -BaseRevision $BaseRevision `
        -CandidateRevision $candidate `
        -BaseInspection $baseInspection `
        -CandidateInspection $candidateInspection `
        -AcceptAssetReduction:$AcceptAssetReduction
    return [pscustomobject]@{
        Base=$BaseRevision
        Candidate=$candidate
        Report=$report
        Changes=$verifiedReport.TopicChanges
        Verification=$verifiedReport
    }
}

function Assert-NoRevisionTopicLoss {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BaseRevision,
        [Parameter(Mandatory)][object]$CandidateRevision,
        [Parameter(Mandatory)][object]$BaseInspection,
        [Parameter(Mandatory)][object]$CandidateInspection,
        [string]$Context = 'candidate revision'
    )
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $baseCount = [int]$BaseRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        $candidateCount = [int]$CandidateRevision.Manifest.sources.PSObject.Properties[$definition.Id].Value.topic_count
        if ($candidateCount -lt $baseCount) { throw "Refusing $Context`: '$($definition.Id)' loses topics ($baseCount -> $candidateCount)." }
    }
    $changes = Get-TopicChangeReport -BaseInspection $BaseInspection -CandidateInspection $CandidateInspection
    if ([int]$changes.removed_count -ne 0) { throw "Refusing $Context`: candidate removes $($changes.removed_count) stable topic IDs." }
    if ([string]$BaseRevision.CorpusRevision -ceq [string]$CandidateRevision.CorpusRevision -and
        ([int]$changes.added_count -ne 0 -or [int]$changes.changed_count -ne 0)) {
        throw "Refusing $Context`: identical CHM bytes changed the stable topic set or content hashes."
    }
    return $changes
}

function Assert-DeterministicRebuildResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BaseRevision,
        [Parameter(Mandatory)][object]$CandidateRevision
    )
    $sameIdentityInputs = (
        [int]$BaseRevision.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and
        [int]$CandidateRevision.ManifestSchemaVersion -eq $script:ManifestSchemaVersion -and
        [string]$BaseRevision.Manifest.index_contract -ceq $script:IndexContract -and
        [string]$CandidateRevision.Manifest.index_contract -ceq $script:IndexContract -and
        [string]$BaseRevision.CorpusRevision -ceq [string]$CandidateRevision.CorpusRevision -and
        [string]$BaseRevision.Manifest.assets.policy_sha256 -ceq [string]$CandidateRevision.Manifest.assets.policy_sha256
    )
    if (-not $sameIdentityInputs) { return $false }
    if ([string]$BaseRevision.IndexRevision -cne [string]$CandidateRevision.IndexRevision) {
        throw "Deterministic rebuild failure: identical corpus '$($BaseRevision.CorpusRevision)', manifest schema '$($script:ManifestSchemaVersion)', index contract '$($script:IndexContract)', and image policy '$($BaseRevision.Manifest.assets.policy_sha256)' produced index '$($CandidateRevision.IndexRevision)' instead of '$($BaseRevision.IndexRevision)'. If the output change is intentional, change an identity-bearing index contract or policy before staging it."
    }
    return $true
}

function New-RevisionCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object[]]$SourceRecords,
        [Parameter(Mandatory)][string]$WorkingRoot,
        [ValidateRange(10,1800)][int]$ExtractionTimeoutSeconds = 300,
        [ValidateRange(10,300)][int]$HhTimeoutSeconds = 60
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $work = Reset-SafeDirectory -ConfinementRoot (Split-Path -Parent $WorkingRoot) -Path $WorkingRoot
    $sourceRoot = New-Item -ItemType Directory -Path (Join-Path $work 'sources'); $extractedRoot = New-Item -ItemType Directory -Path (Join-Path $work 'extracted')
    foreach ($record in $SourceRecords) { Copy-Item -LiteralPath (Resolve-FullPath -Path $record.Path -MustExist -PathType Leaf) -Destination (Join-Path $sourceRoot.FullName $record.FileName) }
    $sevenZip = Resolve-SevenZipExtractor -Root $root; $counts = @{}
    foreach ($record in $SourceRecords) { $counts[$record.Id] = Invoke-ChmExtraction -ProjectRoot $root -WorkingRoot $work -SourceRecord $record -SevenZip $sevenZip -ExtractionTimeoutSeconds $ExtractionTimeoutSeconds -HhTimeoutSeconds $HhTimeoutSeconds }
    $lock = New-CorpusLock -SourceRecords $SourceRecords -TopicCounts $counts
    $lockPath = Join-Path $work 'corpus.lock.json'; Write-JsonAtomic -Path $lockPath -Value $lock -ConfinementRoot $work
    $corpusRevision = Get-RevisionFromSourceRecords -SourceRecords $SourceRecords
    $candidateRoot = New-Item -ItemType Directory -Path (Join-Path $work 'revision')
    foreach ($record in $SourceRecords) { Copy-Item -LiteralPath (Join-Path $sourceRoot.FullName $record.FileName) -Destination (Join-Path $candidateRoot.FullName $record.FileName) }
    $node = Resolve-NodeExecutable -ProjectRoot $root; $indexer = Resolve-Indexer -ProjectRoot $root
    Invoke-NativeChecked -FilePath $node -Arguments @($indexer,'--root',$root,'--workspace-root',$work,'--source-directory',$sourceRoot.FullName,'--extracted-directory',$extractedRoot.FullName,'--output-directory',$candidateRoot.FullName,'--corpus-lock',$lockPath) -FailureMessage 'MQL5 CHM indexing failed.'
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $candidateRoot.FullName 'corpus.lock.json')
    $candidateManifest = Read-JsonFile -Path (Join-Path $candidateRoot.FullName 'manifest.json') -Context 'candidate manifest'
    $indexRevision = [string](Get-RequiredJsonProperty $candidateManifest 'index_revision' 'candidate manifest')
    if ($indexRevision -cnotmatch '^[0-9a-f]{64}$') { throw 'Candidate manifest index_revision is invalid.' }
    $validated = Assert-Revision -ProjectRoot $root -Revision $indexRevision -RevisionRoot $candidateRoot.FullName -RevisionConfinementRoot $work -IdentityMode Index -RequireCurrent
    if ([string]$validated.CorpusRevision -cne $corpusRevision) { throw 'Candidate manifest corpus revision does not match the source records.' }
    $inspection = Invoke-DatabaseInspection -NodePath $node -DatabasePath $validated.DatabasePath -RequireAssets
    if ([string]$inspection.metadata.corpus_sha256 -cne $corpusRevision -or [string]$inspection.metadata.image_policy_sha256 -cne [string]$validated.Manifest.assets.policy_sha256 -or [string]$inspection.metadata.asset_catalog_sha256 -cne [string]$validated.Manifest.assets.catalog_sha256 -or [string]$inspection.metadata.asset_tree_sha256 -cne [string]$validated.Manifest.assets.tree_sha256) { throw 'Candidate database asset metadata does not match its manifest.' }
    if ([int]$inspection.asset_count -ne [int]$validated.Manifest.assets.cataloged_count -or [int]$inspection.topic_asset_count -ne [int]$validated.Manifest.assets.occurrence_count) { throw 'Candidate database asset counts do not match its manifest.' }
    return [pscustomobject]@{ Revision=$indexRevision; IndexRevision=$indexRevision; CorpusRevision=$corpusRevision; ManifestSchemaVersion=[int]$validated.ManifestSchemaVersion; Root=$candidateRoot.FullName; Manifest=$validated.Manifest; Inspection=$inspection; TopicCounts=$counts; WorkRoot=$work }
}

function Install-RevisionCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][object]$Candidate)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $revisionsRoot = Join-Path $root 'revisions'; if (-not (Test-Path -LiteralPath $revisionsRoot -PathType Container)) { New-Item -ItemType Directory -Path $revisionsRoot | Out-Null }
    $revisionsRoot = Resolve-FullPath -Path $revisionsRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $revisionsRoot
    $destination = Get-RevisionDirectory -ProjectRoot $root -Revision ([string]$Candidate.Revision)
    if (Test-Path -LiteralPath $destination) { Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -IdentityMode Index -RequireCurrent | Out-Null; return $destination }
    $candidateWork = Resolve-FullPath -Path ([string]$Candidate.WorkRoot) -MustExist -PathType Container
    $candidateSource = Resolve-FullPath -Path ([string]$Candidate.Root) -MustExist -PathType Container
    Assert-PathWithin -Root $candidateWork -Path $candidateSource | Out-Null
    Assert-NoReparsePoint -Root $candidateWork -Path $candidateSource
    $sourceReparse = @(Get-ChildItem -LiteralPath $candidateSource -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($sourceReparse.Count -gt 0) { throw "Candidate revision contains a reparse point: $($sourceReparse[0].FullName)" }
    $temporary = Assert-PathWithin -Root $revisionsRoot -Path (Join-Path $revisionsRoot ('.revision-install-' + [Guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $temporary -ErrorAction Stop | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $candidateSource -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $temporary -Recurse -Force -ErrorAction Stop
        }
        Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -RevisionRoot $temporary -RevisionConfinementRoot $revisionsRoot -IdentityMode Index -RequireCurrent | Out-Null
        [IO.Directory]::Move($temporary, $destination)
        Assert-Revision -ProjectRoot $root -Revision ([string]$Candidate.Revision) -IdentityMode Index -RequireCurrent | Out-Null
        return $destination
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Container) { Remove-SafeDirectory -ConfinementRoot $revisionsRoot -Path $temporary }
    }
}
