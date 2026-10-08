Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PinnedSevenZipMsiUri = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.msi'
$script:PinnedSevenZipMsiBytes = [int64]1999872
$script:MaximumSevenZipDownloadBytes = [int64]16777216

function Test-SevenZipJsonInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64]
}

function Get-PinnedSevenZipMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $provenancePath = Resolve-FullPath -Path (Join-Path $root 'tools\7zip.provenance.json') -MustExist -PathType Leaf
    Assert-NoReparsePoint -Root $root -Path $provenancePath
    $provenance = Read-JsonFile -Path $provenancePath -Context '7-Zip provenance manifest' -RequireObject
    Assert-ExactJsonProperties -Object $provenance -Names @(
        'schema_version','distribution','version','architecture','upstream_url',
        'artifact_bytes','artifact_sha256','files','required_format'
    ) -Context '7-Zip provenance manifest'
    if (-not (Test-SevenZipJsonInteger $provenance.schema_version) -or [int64]$provenance.schema_version -ne 1 -or
        $provenance.distribution -isnot [string] -or [string]$provenance.distribution -cne 'official-windows-x64-msi' -or
        $provenance.version -isnot [string] -or [string]$provenance.version -cne $script:PinnedSevenZipVersion -or
        $provenance.architecture -isnot [string] -or [string]$provenance.architecture -cne 'x64' -or
        $provenance.upstream_url -isnot [string] -or [string]$provenance.upstream_url -cne $script:PinnedSevenZipMsiUri -or
        -not (Test-SevenZipJsonInteger $provenance.artifact_bytes) -or [int64]$provenance.artifact_bytes -ne $script:PinnedSevenZipMsiBytes -or
        $provenance.artifact_sha256 -isnot [string] -or [string]$provenance.artifact_sha256 -cne $script:PinnedSevenZipArtifactSha256 -or
        $provenance.required_format -isnot [string] -or [string]$provenance.required_format -cne 'Chm') {
        throw '7-Zip provenance manifest does not match the pinned official Windows x64 26.02 MSI.'
    }

    Assert-ExactJsonProperties -Object $provenance.files -Names @(
        'tools/7z.exe','tools/7z.dll','licenses/7ZIP-LICENSE.txt'
    ) -Context '7-Zip provenance files'
    $expectations = @(
        [pscustomobject]@{Relative='tools/7z.exe';Bytes=[int64]576000;Sha256=$script:PinnedSevenZipExecutableSha256;Version='26.02'},
        [pscustomobject]@{Relative='tools/7z.dll';Bytes=[int64]1906688;Sha256=$script:PinnedSevenZipLibrarySha256;Version='26.02'},
        [pscustomobject]@{Relative='licenses/7ZIP-LICENSE.txt';Bytes=[int64]6031;Sha256=$script:PinnedSevenZipLicenseSha256;Version=$null}
    )
    foreach ($expected in $expectations) {
        $property = $provenance.files.PSObject.Properties[[string]$expected.Relative]
        if ($null -eq $property) { throw "7-Zip provenance is missing '$($expected.Relative)'." }
        $entry = $property.Value
        $names = if ($null -eq $expected.Version) { @('bytes','sha256') } else { @('bytes','sha256','file_version') }
        Assert-ExactJsonProperties -Object $entry -Names $names -Context "7-Zip provenance entry '$($expected.Relative)'"
        if (-not (Test-SevenZipJsonInteger $entry.bytes) -or [int64]$entry.bytes -ne [int64]$expected.Bytes -or
            $entry.sha256 -isnot [string] -or [string]$entry.sha256 -cne [string]$expected.Sha256 -or
            ($null -ne $expected.Version -and ($entry.file_version -isnot [string] -or [string]$entry.file_version -cne [string]$expected.Version))) {
            throw "7-Zip provenance entry does not match the pinned MSI: $($expected.Relative)"
        }
    }

    $licensesRoot = Resolve-FullPath -Path (Join-Path $root 'licenses') -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $licensesRoot
    $licensePath = Assert-PathWithin -Root $licensesRoot -Path (Join-Path $licensesRoot '7ZIP-LICENSE.txt')
    if (Test-Path -LiteralPath $licensePath) {
        if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
            throw 'The canonical 7-Zip license path is not a regular file.'
        }
        Assert-NoReparsePoint -Root $root -Path $licensePath
    }
    return [pscustomobject]@{
        Root = $root
        ProvenancePath = $provenancePath
        Provenance = $provenance
        LicensePath = $licensePath
        ArtifactUri = [Uri]$script:PinnedSevenZipMsiUri
        ArtifactBytes = $script:PinnedSevenZipMsiBytes
        ArtifactSha256 = $script:PinnedSevenZipArtifactSha256
    }
}

function Test-PinnedSevenZipLicense {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LicensePath)
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $LicensePath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing a 7-Zip license reparse point.'
    }
    return Test-FileDescriptorMatch -Path $LicensePath -Bytes 6031 -Sha256 $script:PinnedSevenZipLicenseSha256
}

function Get-PinnedSevenZipRuntimeAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DllPath,
        [scriptblock]$InternalPeMachineTypeProbe,
        [scriptblock]$InternalFileVersionProbe,
        [scriptblock]$InternalNativeInfoProbe
    )

    foreach ($path in @($ExePath,$DllPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{State='repair_required';Reason='A runtime file is missing.'} }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing a 7-Zip runtime containing a reparse point.'
        }
    }
    if (-not (Test-FileDescriptorMatch -Path $ExePath -Bytes 576000 -Sha256 $script:PinnedSevenZipExecutableSha256) -or
        -not (Test-FileDescriptorMatch -Path $DllPath -Bytes 1906688 -Sha256 $script:PinnedSevenZipLibrarySha256)) {
        return [pscustomobject]@{State='repair_required';Reason='A runtime file has the wrong hash or size.'}
    }

    $exeMachine = if ($null -eq $InternalPeMachineTypeProbe) { Get-PeMachineType -Path $ExePath } else { & $InternalPeMachineTypeProbe $ExePath }
    $dllMachine = if ($null -eq $InternalPeMachineTypeProbe) { Get-PeMachineType -Path $DllPath } else { & $InternalPeMachineTypeProbe $DllPath }
    if ([int]$exeMachine -ne 0x8664 -or [int]$dllMachine -ne 0x8664) {
        return [pscustomobject]@{State='repair_required';Reason='A runtime file has the wrong architecture.'}
    }
    try {
        $exeVersion = if ($null -eq $InternalFileVersionProbe) { [string](Get-WindowsExecutableVersionInfo $ExePath).FileVersion } else { [string](& $InternalFileVersionProbe $ExePath) }
        $dllVersion = if ($null -eq $InternalFileVersionProbe) { [string](Get-WindowsExecutableVersionInfo $DllPath).FileVersion } else { [string](& $InternalFileVersionProbe $DllPath) }
        if ([string]::IsNullOrWhiteSpace($exeVersion) -or [string]::IsNullOrWhiteSpace($dllVersion)) { throw 'No readable Windows version resource.' }
    } catch {
        return [pscustomobject]@{State='metadata_unavailable';Reason=$_.Exception.Message}
    }
    if ($exeVersion -cne '26.02' -or $dllVersion -cne '26.02') {
        return [pscustomobject]@{State='repair_required';Reason='A runtime file has the wrong version.'}
    }
    return Get-SevenZipNativeCapability -ExePath $ExePath -InternalNativeInfoProbe $InternalNativeInfoProbe
}

function Test-PinnedSevenZipRuntimeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DllPath,
        [scriptblock]$InternalPeMachineTypeProbe,
        [scriptblock]$InternalFileVersionProbe,
        [scriptblock]$InternalNativeInfoProbe
    )
    return (Get-PinnedSevenZipRuntimeAssessment @PSBoundParameters).State -ceq 'verified'
}

function Test-PinnedSevenZipRuntimePair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DllPath,
        [Parameter(Mandatory)][string]$LicensePath,
        [scriptblock]$InternalPeMachineTypeProbe,
        [scriptblock]$InternalFileVersionProbe,
        [scriptblock]$InternalNativeInfoProbe
    )
    if (-not (Test-PinnedSevenZipLicense -LicensePath $LicensePath)) { return $false }
    return Test-PinnedSevenZipRuntimeFiles -ExePath $ExePath -DllPath $DllPath `
        -InternalPeMachineTypeProbe $InternalPeMachineTypeProbe `
        -InternalFileVersionProbe $InternalFileVersionProbe `
        -InternalNativeInfoProbe $InternalNativeInfoProbe
}

function Invoke-BoundedSevenZipDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 300,
        [ValidateRange(1,16777216)][int64]$MaximumBytes = 16777216,
        [ValidateRange(0,5)][int]$MaximumRedirects = 3
    )

    if (-not $Uri.IsAbsoluteUri -or $Uri.AbsoluteUri -cne $script:PinnedSevenZipMsiUri -or
        $Uri.Scheme -cne 'https' -or -not $Uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($Uri.UserInfo) -or -not [string]::IsNullOrEmpty($Uri.Fragment)) {
        throw 'The 7-Zip download must begin at the exact pinned credential-free HTTPS release URL.'
    }
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $handler.UseCookies = $false
    if ($handler.PSObject.Properties.Name -contains 'SslProtocols') {
        $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
    }
    $client = New-Object Net.Http.HttpClient($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $deadline = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSeconds))
    $current = $Uri
    $redirects = 0
    try {
        while ($true) {
            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $current)
            [void]$request.Headers.UserAgent.ParseAdd('mql5-chm-mcp-packager/1.3.7')
            $response = $null
            $stream = $null
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if ($redirects -ge $MaximumRedirects) { throw 'The 7-Zip download exceeded its redirect limit.' }
                    $location = $response.Headers.Location
                    if ($null -eq $location) { throw 'The 7-Zip download returned a redirect without a Location header.' }
                    $next = if ($location.IsAbsoluteUri) { $location } else { New-Object Uri($current, $location) }
                    if (-not $next.IsAbsoluteUri -or $next.Scheme -cne 'https' -or
                        $next.Host -cne 'release-assets.githubusercontent.com' -or -not $next.IsDefaultPort -or
                        -not [string]::IsNullOrEmpty($next.UserInfo) -or -not [string]::IsNullOrEmpty($next.Fragment)) {
                        throw 'The 7-Zip download redirect left the pinned GitHub release-asset origin.'
                    }
                    $current = $next
                    $redirects++
                    continue
                }
                if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) {
                    throw "7-Zip download returned HTTP $status."
                }
                if ($response.Content.Headers.ContentEncoding.Count -ne 0) {
                    throw 'The 7-Zip download unexpectedly used content encoding.'
                }
                $contentLength = $response.Content.Headers.ContentLength
                if ($null -ne $contentLength -and [int64]$contentLength -gt $MaximumBytes) {
                    throw "7-Zip download declares $contentLength bytes, above the $MaximumBytes-byte limit."
                }
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                return Copy-StreamToFileBounded -Stream $stream -Destination $Destination -MaximumBytes $MaximumBytes -CancellationToken $deadline.Token
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                $request.Dispose()
            }
        }
    } catch {
        if ($deadline.IsCancellationRequested) { throw "7-Zip download exceeded its $TimeoutSeconds-second deadline." }
        throw
    } finally {
        $client.Dispose()
        $deadline.Dispose()
    }
}

function Invoke-SevenZipMsiAdministrativeExtract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 300
    )
    $msi = Resolve-FullPath -Path $MsiPath -MustExist -PathType Leaf
    $destinationFull = Resolve-FullPath -Path $Destination -MustExist -PathType Container
    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) { throw 'Unable to resolve the trusted Windows directory.' }
    $msiexec = Resolve-FullPath -Path (Join-Path $windowsRoot 'System32\msiexec.exe') -MustExist -PathType Leaf
    Invoke-NativeProcessWithTimeout -FilePath $msiexec -Arguments @(
        '/a',$msi,'/qn','/norestart','REBOOT=ReallySuppress',"TARGETDIR=$destinationFull"
    ) -TimeoutSeconds $TimeoutSeconds -FailureMessage 'Administrative extraction of the pinned 7-Zip MSI failed.' | Out-Null
}

function Assert-InternalSevenZipRuntimeTestHooks {
    [CmdletBinding()]
    param([hashtable]$Hooks)
    if ($null -eq $Hooks) { return }
    $allowed = @(
        'ExpectedArtifactBytes','ExpectedArtifactSha256','DownloadArtifact','ExtractArtifact',
        'PeMachineTypeProbe','FileVersionProbe','NativeInfoProbe','PublicationCheckpoint'
    )
    foreach ($key in @($Hooks.Keys)) {
        if ($key -isnot [string] -or $allowed -cnotcontains [string]$key) {
            throw "Unsupported internal 7-Zip runtime test hook '$key'."
        }
    }
    foreach ($required in @('ExpectedArtifactBytes','ExpectedArtifactSha256','DownloadArtifact','ExtractArtifact')) {
        if (-not $Hooks.ContainsKey($required)) { throw "Internal 7-Zip runtime test hooks are missing '$required'." }
    }
    if (-not (Test-SevenZipJsonInteger $Hooks.ExpectedArtifactBytes) -or [int64]$Hooks.ExpectedArtifactBytes -lt 1 -or
        [int64]$Hooks.ExpectedArtifactBytes -gt $script:MaximumSevenZipDownloadBytes) {
        throw 'Internal 7-Zip artifact byte count is invalid.'
    }
    if ($Hooks.ExpectedArtifactSha256 -isnot [string] -or [string]$Hooks.ExpectedArtifactSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Internal 7-Zip artifact SHA-256 must be lowercase hexadecimal.'
    }
    foreach ($name in @('DownloadArtifact','ExtractArtifact','PeMachineTypeProbe','FileVersionProbe','NativeInfoProbe','PublicationCheckpoint')) {
        if ($Hooks.ContainsKey($name) -and $Hooks[$name] -isnot [scriptblock]) {
            throw "Internal 7-Zip runtime test hook '$name' must be a script block."
        }
    }
}

function Get-ReservedSevenZipRuntimeArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolsRoot)
    $toolsFull = Resolve-FullPath -Path $ToolsRoot -MustExist -PathType Container
    return @(Get-ChildItem -LiteralPath $toolsFull -Force | Where-Object {
        $_.Name -ceq '.7zip-runtime-transaction.json' -or
        $_.Name.StartsWith('.7z-exe-', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('.7z-dll-', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('.7z.exe.backup-', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('.7z.dll.backup-', [StringComparison]::OrdinalIgnoreCase)
    })
}

function Assert-NoReservedSevenZipRuntimeArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolsRoot)
    $reserved = @(Get-ReservedSevenZipRuntimeArtifacts -ToolsRoot $ToolsRoot)
    if ($reserved.Count -gt 0) {
        throw "Tools directory contains reserved 7-Zip transaction debris: $(@($reserved | ForEach-Object Name | Sort-Object) -join ', ')"
    }
}

function Get-ReservedSevenZipLicenseArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LicensesRoot)
    $licensesFull = Resolve-FullPath -Path $LicensesRoot -MustExist -PathType Container
    return @(Get-ChildItem -LiteralPath $licensesFull -Force | Where-Object {
        $_.Name -ceq '.7zip-license-transaction.json' -or
        $_.Name.StartsWith('.7zip-license-', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('.7ZIP-LICENSE.txt.backup-', [StringComparison]::OrdinalIgnoreCase)
    })
}

function Assert-NoReservedSevenZipLicenseArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LicensesRoot)
    $reserved = @(Get-ReservedSevenZipLicenseArtifacts -LicensesRoot $LicensesRoot)
    if ($reserved.Count -gt 0) {
        throw "Licenses directory contains reserved 7-Zip transaction debris: $(@($reserved | ForEach-Object Name | Sort-Object) -join ', ')"
    }
}

function Repair-SevenZipLicensePreparedOrphans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LicensesRoot,
        [Parameter(Mandatory)][string]$LicensePath,
        [switch]$NoDownload
    )
    $licensesFull = Resolve-FullPath -Path $LicensesRoot -MustExist -PathType Container
    $reserved = @(Get-ReservedSevenZipLicenseArtifacts -LicensesRoot $licensesFull)
    if ($reserved.Count -eq 0) { return [pscustomobject]@{State='none'} }
    if ($reserved.Count -ne 1) {
        throw "Licenses directory contains malformed or ambiguous unbound 7-Zip transaction debris: $(@($reserved | ForEach-Object Name | Sort-Object) -join ', ')"
    }
    if ($reserved[0].Name -cmatch '^\.7zip-license-([0-9a-f]{32})\.writing$') {
        Assert-NoReparsePoint -Root $licensesFull -Path $reserved[0].FullName
        if (-not (Test-Path -LiteralPath $reserved[0].FullName -PathType Leaf)) { throw 'Incomplete 7-Zip license write is not a regular file.' }
        Remove-Item -LiteralPath $reserved[0].FullName -Force
        return [pscustomobject]@{State='removed'}
    }
    if ($reserved[0].Name -cnotmatch '^\.7zip-license-([0-9a-f]{32})\.prepared$') {
        throw "Licenses directory contains malformed or ambiguous unbound 7-Zip transaction debris: $($reserved[0].Name)"
    }
    $preparedLicense = $reserved[0].FullName
    Assert-NoReparsePoint -Root $licensesFull -Path $preparedLicense
    if (-not (Test-Path -LiteralPath $preparedLicense -PathType Leaf)) { throw 'Reserved 7-Zip license candidate is not a regular file.' }
    if (-not (Test-FileDescriptorMatch -Path $preparedLicense -Bytes 6031 -Sha256 $script:PinnedSevenZipLicenseSha256)) {
        if (-not (Test-PinnedSevenZipLicense -LicensePath $LicensePath) -and $NoDownload) {
            throw 'Malformed prepared 7-Zip license cannot repair the damaged offline runtime; it was preserved.'
        }
        Remove-Item -LiteralPath $preparedLicense -Force
        return [pscustomobject]@{State='removed'}
    }
    if (-not (Test-PinnedSevenZipLicense -LicensePath $LicensePath)) {
        Publish-PreparedFileSetTransaction -Root $licensesFull -JournalName '.7zip-license-transaction.json' -TransactionRole sevenzip-license -ExpectedTargetNames @('7ZIP-LICENSE.txt') -Items @(
            [pscustomobject]@{PreparedPath=$preparedLicense;TargetPath=$LicensePath}
        ) | Out-Null
        return [pscustomobject]@{State='published'}
    }
    Remove-Item -LiteralPath $preparedLicense -Force
    return [pscustomobject]@{State='removed'}
}

function Repair-SevenZipPreparedOrphans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolsRoot,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DllPath,
        [switch]$NoDownload,
        [hashtable]$PairValidationParameters = @{}
    )
    $toolsFull = Resolve-FullPath -Path $ToolsRoot -MustExist -PathType Container
    $reserved = @(Get-ReservedSevenZipRuntimeArtifacts -ToolsRoot $toolsFull)
    if ($reserved.Count -eq 0) { return [pscustomobject]@{State='none'} }
    $tokens = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $preparedExe = $null
    $preparedDll = $null
    $writingExe = $null
    $writingDll = $null
    foreach ($artifact in $reserved) {
        Assert-NoReparsePoint -Root $toolsFull -Path $artifact.FullName
        if (-not (Test-Path -LiteralPath $artifact.FullName -PathType Leaf)) {
            throw "Reserved 7-Zip transaction artifact is not a regular file: $($artifact.FullName)"
        }
        if ($artifact.Name -cmatch '^\.7z-exe-([0-9a-f]{32})\.prepared$') {
            if ($null -ne $preparedExe) { throw 'Tools contain duplicate prepared 7-Zip executables.' }
            [void]$tokens.Add($Matches[1]); $preparedExe = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.7z-dll-([0-9a-f]{32})\.prepared$') {
            if ($null -ne $preparedDll) { throw 'Tools contain duplicate prepared 7-Zip libraries.' }
            [void]$tokens.Add($Matches[1]); $preparedDll = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.7z-exe-([0-9a-f]{32})\.writing$') {
            if ($null -ne $writingExe) { throw 'Tools contain duplicate incomplete 7-Zip executable writes.' }
            [void]$tokens.Add($Matches[1]); $writingExe = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.7z-dll-([0-9a-f]{32})\.writing$') {
            if ($null -ne $writingDll) { throw 'Tools contain duplicate incomplete 7-Zip library writes.' }
            [void]$tokens.Add($Matches[1]); $writingDll = $artifact.FullName
        } else {
            throw "Tools contain malformed or unbound reserved 7-Zip transaction debris: $($artifact.Name)"
        }
    }
    if ($tokens.Count -ne 1) { throw 'Tools contain ambiguous prepared 7-Zip candidates from different transaction tokens.' }
    if (($null -ne $writingExe -and $null -ne $preparedExe) -or ($null -ne $writingDll -and $null -ne $preparedDll)) {
        throw 'Tools contain both writing and prepared artifacts for the same 7-Zip transaction item.'
    }
    $assessment = Get-PinnedSevenZipRuntimeAssessment -ExePath $ExePath -DllPath $DllPath @PairValidationParameters
    Assert-SevenZipRuntimeAvailability -Assessment $assessment -ExePath $ExePath
    foreach ($writing in @($writingDll,$writingExe)) {
        if ($null -ne $writing) { Remove-Item -LiteralPath $writing -Force }
    }
    $canonicalValid = $assessment.State -ceq 'verified'
    $invalidPrepared = @(
        if ($null -ne $preparedExe -and -not (Test-FileDescriptorMatch -Path $preparedExe -Bytes 576000 -Sha256 $script:PinnedSevenZipExecutableSha256)) { $preparedExe }
        if ($null -ne $preparedDll -and -not (Test-FileDescriptorMatch -Path $preparedDll -Bytes 1906688 -Sha256 $script:PinnedSevenZipLibrarySha256)) { $preparedDll }
    )
    if ($invalidPrepared.Count -gt 0) {
        if (-not $canonicalValid -and $NoDownload) {
            throw 'Malformed prepared 7-Zip files cannot repair the damaged offline runtime; they were preserved.'
        }
        foreach ($prepared in @($preparedDll,$preparedExe)) {
            if ($null -ne $prepared) { Remove-Item -LiteralPath $prepared -Force }
        }
        return [pscustomobject]@{State='removed'}
    }
    $candidateComplete = $null -ne $preparedExe -and $null -ne $preparedDll
    if (-not $canonicalValid -and $candidateComplete) {
        Publish-PreparedFileSetTransaction -Root $toolsFull -JournalName '.7zip-runtime-transaction.json' -TransactionRole sevenzip-runtime -ExpectedTargetNames @('7z.dll','7z.exe') -Items @(
            [pscustomobject]@{PreparedPath=$preparedDll;TargetPath=$DllPath},
            [pscustomobject]@{PreparedPath=$preparedExe;TargetPath=$ExePath}
        ) | Out-Null
        return [pscustomobject]@{State='published'}
    }
    if (-not $canonicalValid -and $NoDownload) {
        throw 'An incomplete pre-journal 7-Zip candidate cannot repair the damaged offline runtime; all artifacts were preserved.'
    }
    foreach ($prepared in @($preparedDll,$preparedExe)) {
        if ($null -ne $prepared) { Remove-Item -LiteralPath $prepared -Force }
    }
    return [pscustomobject]@{State='removed'}
}

function Ensure-PinnedSevenZipRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$NoDownload,
        [hashtable]$InternalTestHooks
    )

    Assert-InternalSevenZipRuntimeTestHooks -Hooks $InternalTestHooks
    $metadata = Get-PinnedSevenZipMetadata -ProjectRoot $ProjectRoot
    $root = [string]$metadata.Root
    $toolsRoot = Resolve-FullPath -Path (Join-Path $root 'tools') -MustExist -PathType Container
    $licensesRoot = Resolve-FullPath -Path (Join-Path $root 'licenses') -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $toolsRoot
    Assert-NoReparsePoint -Root $root -Path $licensesRoot
    $exePath = Join-Path $toolsRoot '7z.exe'
    $dllPath = Join-Path $toolsRoot '7z.dll'
    $licensePath = [string]$metadata.LicensePath
    $journalName = '.7zip-runtime-transaction.json'
    $journalPath = Join-Path $toolsRoot $journalName
    $licenseJournalName = '.7zip-license-transaction.json'
    $licenseJournalPath = Join-Path $licensesRoot $licenseJournalName
    $pairValidationParameters = @{}
    if ($null -ne $InternalTestHooks) {
        if ($InternalTestHooks.ContainsKey('PeMachineTypeProbe')) { $pairValidationParameters.InternalPeMachineTypeProbe = $InternalTestHooks.PeMachineTypeProbe }
        if ($InternalTestHooks.ContainsKey('FileVersionProbe')) { $pairValidationParameters.InternalFileVersionProbe = $InternalTestHooks.FileVersionProbe }
        if ($InternalTestHooks.ContainsKey('NativeInfoProbe')) { $pairValidationParameters.InternalNativeInfoProbe = $InternalTestHooks.NativeInfoProbe }
    }

    # Check canonical bytes before recovery removes or publishes any pending
    # evidence. Downloads cannot fix native execution or metadata unavailability
    # for an already-verified pair.
    $assessment = Get-PinnedSevenZipRuntimeAssessment -ExePath $exePath -DllPath $dllPath @pairValidationParameters
    Assert-SevenZipRuntimeAvailability -Assessment $assessment -ExePath $exePath
    if ((Test-Path -LiteralPath $licenseJournalPath) -and -not (Test-Path -LiteralPath $licenseJournalPath -PathType Leaf)) { throw "7-Zip license transaction journal is not a file: $licenseJournalPath" }
    Repair-PreparedFileSetTransaction -Root $licensesRoot -JournalName $licenseJournalName -ExpectedRole sevenzip-license -ExpectedTargetNames @('7ZIP-LICENSE.txt') | Out-Null
    Repair-SevenZipLicensePreparedOrphans -LicensesRoot $licensesRoot -LicensePath $licensePath -NoDownload:$NoDownload | Out-Null
    Assert-NoReservedSevenZipLicenseArtifacts -LicensesRoot $licensesRoot

    if ((Test-Path -LiteralPath $journalPath) -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw "7-Zip transaction journal is not a file: $journalPath" }
    Repair-PreparedFileSetTransaction -Root $toolsRoot -JournalName $journalName -ExpectedRole sevenzip-runtime -ExpectedTargetNames @('7z.dll','7z.exe') | Out-Null
    Repair-SevenZipPreparedOrphans -ToolsRoot $toolsRoot -ExePath $exePath -DllPath $dllPath -NoDownload:$NoDownload -PairValidationParameters $pairValidationParameters | Out-Null
    Assert-NoReservedSevenZipRuntimeArtifacts -ToolsRoot $toolsRoot
    $assessment = Get-PinnedSevenZipRuntimeAssessment -ExePath $exePath -DllPath $dllPath @pairValidationParameters
    Assert-SevenZipRuntimeAvailability -Assessment $assessment -ExePath $exePath
    if ($assessment.State -ceq 'verified' -and (Test-PinnedSevenZipLicense -LicensePath $licensePath)) {
        return [pscustomobject]@{ExeName='7z.exe';DllName='7z.dll';Extractor=(Resolve-FullPath -Path $exePath -MustExist -PathType Leaf);Provenance=[string]$metadata.ProvenancePath}
    }
    if ($NoDownload) { throw 'The bundled 7-Zip 26.02 runtime is missing or invalid; portable repack mode will not download or repair tools.' }

    $buildRoot = Join-Path $root 'build'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        if (Test-Path -LiteralPath $buildRoot) { throw "Build path is not a directory: $buildRoot" }
        New-Item -ItemType Directory -Path $buildRoot | Out-Null
    }
    $buildRoot = Resolve-FullPath -Path $buildRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $buildRoot
    $token = [Guid]::NewGuid().ToString('N')
    $downloadRoot = Join-Path $buildRoot "7zip-download-$token"
    $extractRoot = Join-Path $buildRoot "7zip-extract-$token"
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    $artifactPath = Join-Path $downloadRoot '7z2602-x64.msi'
    $preparedDll = Join-Path $toolsRoot ".7z-dll-$token.prepared"
    $preparedExe = Join-Path $toolsRoot ".7z-exe-$token.prepared"
    $preparedLicense = Join-Path $licensesRoot ".7zip-license-$token.prepared"
    $writingDll = Join-Path $toolsRoot ".7z-dll-$token.writing"
    $writingExe = Join-Path $toolsRoot ".7z-exe-$token.writing"
    $writingLicense = Join-Path $licensesRoot ".7zip-license-$token.writing"
    try {
        Write-Host 'Downloading pinned official 7-Zip 26.02 Windows x64 MSI...'
        if ($null -eq $InternalTestHooks) {
            Invoke-BoundedSevenZipDownload -Uri ([Uri]$metadata.ArtifactUri) -Destination $artifactPath -TimeoutSeconds 300 -MaximumBytes $script:MaximumSevenZipDownloadBytes | Out-Null
            $expectedArtifactBytes = [int64]$metadata.ArtifactBytes
            $expectedArtifactSha256 = [string]$metadata.ArtifactSha256
        } else {
            & $InternalTestHooks.DownloadArtifact ([Uri]$metadata.ArtifactUri) $artifactPath 300 $script:MaximumSevenZipDownloadBytes | Out-Null
            $expectedArtifactBytes = [int64]$InternalTestHooks.ExpectedArtifactBytes
            $expectedArtifactSha256 = [string]$InternalTestHooks.ExpectedArtifactSha256
        }
        Assert-NoReparsePoint -Root $downloadRoot -Path $artifactPath
        if (-not (Test-FileDescriptorMatch -Path $artifactPath -Bytes $expectedArtifactBytes -Sha256 $expectedArtifactSha256)) {
            throw 'Downloaded 7-Zip MSI does not match its pinned byte count and SHA-256.'
        }
        if ($null -eq $InternalTestHooks) {
            Invoke-SevenZipMsiAdministrativeExtract -MsiPath $artifactPath -Destination $extractRoot -TimeoutSeconds 300
        } else {
            & $InternalTestHooks.ExtractArtifact $artifactPath $extractRoot 300 | Out-Null
        }
        $reparse = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        if ($reparse.Count -gt 0) { throw "Extracted 7-Zip MSI contains a reparse point: $($reparse[0].FullName)" }
        $distributionRoot = Resolve-FullPath -Path (Join-Path $extractRoot 'Files\7-Zip') -MustExist -PathType Container
        Assert-NoReparsePoint -Root $extractRoot -Path $distributionRoot
        $extractedExe = Resolve-FullPath -Path (Join-Path $distributionRoot '7z.exe') -MustExist -PathType Leaf
        $extractedDll = Resolve-FullPath -Path (Join-Path $distributionRoot '7z.dll') -MustExist -PathType Leaf
        $extractedLicense = Resolve-FullPath -Path (Join-Path $distributionRoot 'License.txt') -MustExist -PathType Leaf
        if (-not (Test-PinnedSevenZipRuntimePair -ExePath $extractedExe -DllPath $extractedDll -LicensePath $extractedLicense @pairValidationParameters)) {
            throw 'Files extracted from the 7-Zip MSI failed pinned hash, version, architecture, CHM, or license validation.'
        }
        $publicationParameters = @{}
        if ($null -ne $InternalTestHooks -and $InternalTestHooks.ContainsKey('PublicationCheckpoint')) {
            $publicationParameters.InternalCheckpoint = $InternalTestHooks.PublicationCheckpoint
        }
        if (-not (Test-PinnedSevenZipLicense -LicensePath $licensePath)) {
            Copy-FileDurable -Source $extractedLicense -Destination $writingLicense | Out-Null
            if (-not (Test-FileDescriptorMatch -Path $writingLicense -Bytes 6031 -Sha256 $script:PinnedSevenZipLicenseSha256)) { throw 'Prepared 7-Zip license copy failed validation.' }
            [IO.File]::Move($writingLicense,$preparedLicense)
            Publish-PreparedFileSetTransaction -Root $licensesRoot -JournalName $licenseJournalName -TransactionRole sevenzip-license -ExpectedTargetNames @('7ZIP-LICENSE.txt') -Items @(
                [pscustomobject]@{PreparedPath=$preparedLicense;TargetPath=$licensePath}
            ) @publicationParameters | Out-Null
        }
        $assessment = Get-PinnedSevenZipRuntimeAssessment -ExePath $exePath -DllPath $dllPath @pairValidationParameters
        Assert-SevenZipRuntimeAvailability -Assessment $assessment -ExePath $exePath
        if ($assessment.State -cne 'verified') {
            Copy-FileDurable -Source $extractedDll -Destination $writingDll | Out-Null
            if (-not (Test-FileDescriptorMatch -Path $writingDll -Bytes 1906688 -Sha256 $script:PinnedSevenZipLibrarySha256)) { throw 'Prepared 7-Zip library copy failed validation.' }
            [IO.File]::Move($writingDll,$preparedDll)
            Copy-FileDurable -Source $extractedExe -Destination $writingExe | Out-Null
            if (-not (Test-FileDescriptorMatch -Path $writingExe -Bytes 576000 -Sha256 $script:PinnedSevenZipExecutableSha256)) { throw 'Prepared 7-Zip executable copy failed validation.' }
            [IO.File]::Move($writingExe,$preparedExe)
            Publish-PreparedFileSetTransaction -Root $toolsRoot -JournalName $journalName -TransactionRole sevenzip-runtime -ExpectedTargetNames @('7z.dll','7z.exe') -Items @(
                [pscustomobject]@{PreparedPath=$preparedDll;TargetPath=$dllPath},
                [pscustomobject]@{PreparedPath=$preparedExe;TargetPath=$exePath}
            ) @publicationParameters | Out-Null
        }
        if (-not (Test-PinnedSevenZipRuntimePair -ExePath $exePath -DllPath $dllPath -LicensePath $licensePath @pairValidationParameters)) {
            throw 'Published 7-Zip runtime pair failed final validation.'
        }
        return [pscustomobject]@{ExeName='7z.exe';DllName='7z.dll';Extractor=(Resolve-FullPath -Path $exePath -MustExist -PathType Leaf);Provenance=[string]$metadata.ProvenancePath}
    } finally {
        foreach ($writing in @($writingLicense,$writingDll,$writingExe)) {
            if (Test-Path -LiteralPath $writing -PathType Leaf) { Remove-Item -LiteralPath $writing -Force }
        }
        if (-not (Test-Path -LiteralPath $licenseJournalPath -PathType Leaf) -and
            (Test-Path -LiteralPath $preparedLicense -PathType Leaf) -and
            (Test-FileDescriptorMatch -Path $preparedLicense -Bytes 6031 -Sha256 $script:PinnedSevenZipLicenseSha256)) {
            Remove-Item -LiteralPath $preparedLicense -Force
        }
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            foreach ($prepared in @($preparedDll,$preparedExe)) {
                if (Test-Path -LiteralPath $prepared -PathType Leaf) {
                    $expectedHash = if ($prepared -ceq $preparedDll) { $script:PinnedSevenZipLibrarySha256 } else { $script:PinnedSevenZipExecutableSha256 }
                    if ((Get-FileHash -LiteralPath $prepared -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) {
                        Remove-Item -LiteralPath $prepared -Force
                    }
                }
            }
        }
        foreach ($temporaryRoot in @($downloadRoot,$extractRoot)) {
            if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
                Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $temporaryRoot
            }
        }
    }
}
