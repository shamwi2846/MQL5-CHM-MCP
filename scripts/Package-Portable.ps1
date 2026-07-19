[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string]$ReleaseName = 'mql5-chm-mcp-windows-x64',

    [string]$OutputDirectory,

    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$CandidateRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Ensure-NodeRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $runtimeRoot = Join-Path $Root 'runtime'
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
    }
    Assert-NoReparsePoint -Root $Root -Path $runtimeRoot

    $nodePath = Join-Path $runtimeRoot 'node.exe'
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
        $version = '24.17.0'
        $archiveName = "node-v$version-win-x64.zip"
        $baseUri = "https://nodejs.org/dist/v$version"
        $buildRoot = Join-Path $Root 'build'
        if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $buildRoot | Out-Null
        }
        $downloadRoot = Reset-SafeDirectory -ConfinementRoot $buildRoot -Path (Join-Path $buildRoot 'node-download')
        $expandRoot = Reset-SafeDirectory -ConfinementRoot $buildRoot -Path (Join-Path $buildRoot 'node-expand')
        $archivePath = Join-Path $downloadRoot $archiveName
        $sumsPath = Join-Path $downloadRoot 'SHASUMS256.txt'

        Write-Host "Downloading official Node.js v$version Windows x64 runtime..."
        $oldProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUri/$archiveName" -OutFile $archivePath
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUri/SHASUMS256.txt" -OutFile $sumsPath
        } finally {
            $ProgressPreference = $oldProgressPreference
        }

        $escapedName = [regex]::Escape($archiveName)
        $sumLine = Get-Content -LiteralPath $sumsPath -Encoding UTF8 |
            Where-Object { $_ -match "^([0-9A-Fa-f]{64})\s+$escapedName$" } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$sumLine)) {
            throw "Official SHASUMS256.txt does not contain '$archiveName'."
        }
        if ($sumLine -notmatch '^([0-9A-Fa-f]{64})\s+') {
            throw "Could not parse the official SHA-256 for '$archiveName'."
        }
        Assert-FileSha256 -Path $archivePath -Expected $Matches[1] | Out-Null

        Expand-Archive -LiteralPath $archivePath -DestinationPath $expandRoot -Force
        $distributionRoot = Join-Path $expandRoot "node-v$version-win-x64"
        Assert-NoReparsePoint -Root $expandRoot -Path $distributionRoot
        $extractedNode = Resolve-FullPath -Path (Join-Path $distributionRoot 'node.exe') -MustExist -PathType Leaf
        $extractedLicense = Resolve-FullPath -Path (Join-Path $distributionRoot 'LICENSE') -MustExist -PathType Leaf
        Copy-Item -LiteralPath $extractedNode -Destination $nodePath -Force
        Copy-Item -LiteralPath $extractedLicense -Destination (Join-Path $runtimeRoot 'LICENSE') -Force

        $licensesRoot = Join-Path $Root 'licenses'
        if (-not (Test-Path -LiteralPath $licensesRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $licensesRoot | Out-Null
        }
        Copy-Item -LiteralPath $extractedLicense -Destination (Join-Path $licensesRoot 'NODE-LICENSE.txt') -Force
    }

    $runtimeLicense = Join-Path $runtimeRoot 'LICENSE'
    if (-not (Test-Path -LiteralPath $runtimeLicense -PathType Leaf)) {
        $licenseFallback = Join-Path $Root 'licenses\NODE-LICENSE.txt'
        Resolve-FullPath -Path $licenseFallback -MustExist -PathType Leaf | Out-Null
        Copy-Item -LiteralPath $licenseFallback -Destination $runtimeLicense
    }
    return Resolve-NodeExecutable -ProjectRoot $Root -RequireBundled
}

function Ensure-SevenZipRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $toolsRoot = Join-Path $Root 'tools'
    if (-not (Test-Path -LiteralPath $toolsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $toolsRoot | Out-Null
    }
    Assert-NoReparsePoint -Root $Root -Path $toolsRoot

    $pairs = @(
        [pscustomobject]@{ ExeName='7z.exe'; DllName='7z.dll' },
        [pscustomobject]@{ ExeName='7za.exe'; DllName='7za.dll' }
    )
    $selectedPair = $null
    foreach ($pair in $pairs) {
        $candidate = Join-Path $toolsRoot $pair.ExeName
        $candidateDll = Join-Path $toolsRoot $pair.DllName
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-Path -LiteralPath $candidateDll -PathType Leaf)) {
            Assert-NoReparsePoint -Root $Root -Path $candidate
            Assert-NoReparsePoint -Root $Root -Path $candidateDll
            $probe = Invoke-NativeCapture -FilePath $candidate -Arguments @('i')
            if ($probe.ExitCode -eq 0 -and $probe.Text -match '(?im)^\s*.*Chm\s+chm\b') {
                $selectedPair = $pair
                break
            }
        }
    }
    if ($null -eq $selectedPair) {
        $alternateExe = Join-Path $toolsRoot '7z.exe'
        $alternateDll = Join-Path $toolsRoot '7z.dll'
        $nvidiaRoot = 'C:\Program Files\NVIDIA Corporation\NVIDIA App'
        $nvidiaExe = Join-Path $nvidiaRoot '7z.exe'
        $nvidiaDll = Join-Path $nvidiaRoot '7z.dll'
        $nvidiaLicense = Join-Path $nvidiaRoot 'license.txt'
        if (-not ((Test-Path -LiteralPath $nvidiaExe -PathType Leaf) -and
                  (Test-Path -LiteralPath $nvidiaDll -PathType Leaf) -and
                  (Test-Path -LiteralPath $nvidiaLicense -PathType Leaf))) {
            throw 'Portable CHM-capable 7-Zip files are missing. Supply either tools\7z.exe + tools\7z.dll or tools\7za.exe + tools\7za.dll, plus licenses\7ZIP-LICENSE.txt.'
        }
        Copy-Item -LiteralPath $nvidiaExe -Destination $alternateExe -Force
        Copy-Item -LiteralPath $nvidiaDll -Destination $alternateDll -Force
        Copy-Item -LiteralPath $nvidiaLicense -Destination (Join-Path $Root 'licenses\7ZIP-LICENSE.txt') -Force
        $selectedPair = $pairs[0]
    }

    $licensePath = Join-Path $Root 'licenses\7ZIP-LICENSE.txt'
    Resolve-FullPath -Path $licensePath -MustExist -PathType Leaf | Out-Null
    $extractor = Join-Path $toolsRoot $selectedPair.ExeName
    $extractorDll = Join-Path $toolsRoot $selectedPair.DllName
    Resolve-FullPath -Path $extractorDll -MustExist -PathType Leaf | Out-Null
    $probe = Invoke-NativeCapture -FilePath $extractor -Arguments @('i')
    if ($probe.ExitCode -ne 0 -or $probe.Text -notmatch '(?im)^\s*.*Chm\s+chm\b') {
        throw "The packaged 7-Zip extractor does not advertise CHM support: $extractor"
    }
    return $selectedPair
}

function Copy-DirectorySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourceFull = Resolve-FullPath -Path $Source -MustExist -PathType Container
    Assert-NoReparsePoint -Root $Root -Path $sourceFull
    $reparseItems = @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Force |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) {
        throw "Refusing to package a directory containing reparse points: $sourceFull"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $sourceFull -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

$script:PackageRootMarkerName = '.mql5-chm-package-root'
$script:PackageRootMarkerValue = 'mql5-chm-portable-package-v1'

function Test-PathWithinOrEqual {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    return $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathsOverlap {
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    return (Test-PathWithinOrEqual -Path $First -Root $Second) -or
        (Test-PathWithinOrEqual -Path $Second -Root $First)
}

function Get-PhysicalPathDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $unresolved = New-Object 'Collections.Generic.List[string]'
    $cursor = $fullPath
    while (-not (Test-Path -LiteralPath $cursor)) {
        $trimmed = $cursor.TrimEnd('\','/')
        $leaf = [IO.Path]::GetFileName($trimmed)
        $parent = Split-Path -Parent $trimmed
        if ([string]::IsNullOrWhiteSpace($leaf) -or [string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cannot locate an existing filesystem ancestor for package path: $fullPath"
        }
        $unresolved.Insert(0, $leaf)
        $cursor = [IO.Path]::GetFullPath($parent)
    }

    $existingItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Package path resolves through a reparse point: $($existingItem.FullName)"
    }
    if ($existingItem.PSIsContainer) {
        $anchor = Resolve-FullPath -Path $existingItem.FullName -MustExist -PathType Container
        $existingBoundary = $anchor
    } else {
        if ($unresolved.Count -gt 0) { throw "Package path descends from an existing file: $($existingItem.FullName)" }
        $unresolved.Insert(0, [IO.Path]::GetFileName($existingItem.FullName))
        $anchor = Resolve-FullPath -Path (Split-Path -Parent $existingItem.FullName) -MustExist -PathType Container
        $existingBoundary = $existingItem.FullName
    }

    $volumeRoot = [IO.Path]::GetPathRoot($anchor)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "Cannot determine the volume root for package path: $fullPath" }
    Assert-NoReparsePoint -Root $volumeRoot -Path $existingBoundary

    # Each entry maps one physical ancestor directory to the target's relative
    # components from that ancestor. This remains comparable when an alias is a
    # SUBST root whose lexical parent chain starts at the mapped directory.
    $entries = New-Object 'Collections.Generic.List[object]'
    $relativeParts = New-Object 'Collections.Generic.List[string]'
    foreach ($part in $unresolved) { $relativeParts.Add($part.ToLowerInvariant()) }
    $current = $anchor
    while ($true) {
        $current = Resolve-FullPath -Path $current -MustExist -PathType Container
        $identity = Get-PhysicalDirectoryIdentity -Path $current
        $entries.Add([pscustomobject]@{ Identity=$identity; Parts=@($relativeParts.ToArray()) })

        $currentTrimmed = $current.TrimEnd('\','/')
        $parentInfo = [IO.Directory]::GetParent($currentTrimmed)
        if ($null -eq $parentInfo) { break }
        $parentPath = [IO.Path]::GetFullPath($parentInfo.FullName)
        if ($parentPath.TrimEnd('\','/').Equals($currentTrimmed, [StringComparison]::OrdinalIgnoreCase)) { break }
        $currentLeaf = [IO.Path]::GetFileName($currentTrimmed)
        if ([string]::IsNullOrWhiteSpace($currentLeaf)) { break }
        $relativeParts.Insert(0, $currentLeaf.ToLowerInvariant())
        $current = $parentPath
    }
    if ($entries.Count -eq 0) { throw "Could not derive a physical identity for package path: $fullPath" }
    return [pscustomobject]@{ FullPath=$fullPath; Entries=@($entries.ToArray()) }
}

function Test-PhysicalDescriptorWithinOrEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$PathDescriptor, [Parameter(Mandatory)][object]$RootDescriptor)

    foreach ($pathEntry in $PathDescriptor.Entries) {
        foreach ($rootEntry in $RootDescriptor.Entries) {
            if ([string]$pathEntry.Identity -cne [string]$rootEntry.Identity) { continue }
            $pathParts = @($pathEntry.Parts)
            $rootParts = @($rootEntry.Parts)
            if ($rootParts.Count -gt $pathParts.Count) { continue }
            $matches = $true
            for ($index = 0; $index -lt $rootParts.Count; $index++) {
                if (-not ([string]$pathParts[$index]).Equals([string]$rootParts[$index], [StringComparison]::OrdinalIgnoreCase)) {
                    $matches = $false
                    break
                }
            }
            if ($matches) { return $true }
        }
    }
    return $false
}

function Test-PhysicalDescriptorsEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$FirstDescriptor, [Parameter(Mandatory)][object]$SecondDescriptor)
    return (Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $FirstDescriptor -RootDescriptor $SecondDescriptor) -and
        (Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $SecondDescriptor -RootDescriptor $FirstDescriptor)
}

function Test-PhysicalDescriptorsOverlap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$FirstDescriptor, [Parameter(Mandatory)][object]$SecondDescriptor)
    return (Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $FirstDescriptor -RootDescriptor $SecondDescriptor) -or
        (Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $SecondDescriptor -RootDescriptor $FirstDescriptor)
}

function Test-PhysicalPathWithinOrEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $pathDescriptor = Get-PhysicalPathDescriptor -Path $Path
    $rootDescriptor = Get-PhysicalPathDescriptor -Path $Root
    return Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $pathDescriptor -RootDescriptor $rootDescriptor
}

function Test-PhysicalPathsEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    $firstDescriptor = Get-PhysicalPathDescriptor -Path $First
    $secondDescriptor = Get-PhysicalPathDescriptor -Path $Second
    return Test-PhysicalDescriptorsEqual -FirstDescriptor $firstDescriptor -SecondDescriptor $secondDescriptor
}

function Test-PhysicalPathsOverlap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    $firstDescriptor = Get-PhysicalPathDescriptor -Path $First
    $secondDescriptor = Get-PhysicalPathDescriptor -Path $Second
    return Test-PhysicalDescriptorsOverlap -FirstDescriptor $firstDescriptor -SecondDescriptor $secondDescriptor
}

function Assert-PackageOutputPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [string[]]$ProtectedSources = @()
    )
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    Assert-NoReparsePoint -Root $rootFull -Path $rootFull
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot
    $releaseParent = Resolve-FullPath -Path (Split-Path -Parent $releaseFull) -MustExist -PathType Container
    Assert-NoReparsePoint -Root $releaseParent -Path $releaseFull
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    $rootDescriptor = Get-PhysicalPathDescriptor -Path $rootFull
    $stageDescriptor = Get-PhysicalPathDescriptor -Path $stageFull
    $zipDescriptor = Get-PhysicalPathDescriptor -Path $zipFull

    if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $stageDescriptor -SecondDescriptor $rootDescriptor) {
        $allowedDevelopmentRoots = @((Join-Path $rootFull 'release'), (Join-Path $rootFull 'build'))
        $allowed = $false
        foreach ($allowedRoot in $allowedDevelopmentRoots) {
            $allowedDescriptor = Get-PhysicalPathDescriptor -Path $allowedRoot
            if ((Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $stageDescriptor -RootDescriptor $allowedDescriptor) -and
                -not (Test-PhysicalDescriptorsEqual -FirstDescriptor $stageDescriptor -SecondDescriptor $allowedDescriptor)) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            throw 'Package stage must not equal, contain, or occupy a protected part of the project tree; use release, build, or an external directory.'
        }
    }

    foreach ($source in $ProtectedSources) {
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        $sourceFull = Resolve-FullPath -Path $source
        $sourceDescriptor = Get-PhysicalPathDescriptor -Path $sourceFull
        if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $stageDescriptor -SecondDescriptor $sourceDescriptor) {
            throw "Package stage overlaps a source or immutable tree: $sourceFull"
        }
        if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $zipDescriptor -SecondDescriptor $sourceDescriptor) {
            throw "Package ZIP overlaps a source or immutable path: $sourceFull"
        }
    }
    if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $zipDescriptor -SecondDescriptor $rootDescriptor) {
        $allowedZipRoots = @((Join-Path $rootFull 'release'), (Join-Path $rootFull 'build'))
        if (@($allowedZipRoots | Where-Object {
            $allowedZipDescriptor = Get-PhysicalPathDescriptor -Path $_
            Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $zipDescriptor -RootDescriptor $allowedZipDescriptor
        }).Count -eq 0) {
            throw 'Package ZIP must not overwrite a protected project path.'
        }
    }
    return [pscustomobject]@{ ReleaseRoot=$releaseFull; StageRoot=$stageFull; ZipPath=$zipFull }
}

function Reset-OwnedPackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReleaseRoot, [Parameter(Mandatory)][string]$StageRoot)
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    Assert-NoReparsePoint -Root $releaseFull -Path $stageFull
    if (Test-Path -LiteralPath $stageFull) {
        $item = Get-Item -LiteralPath $stageFull -Force
        if (-not $item.PSIsContainer) { throw "Package stage target is not a directory: $stageFull" }
        $markerPath = Join-Path $stageFull $script:PackageRootMarkerName
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "Refusing to replace an existing unowned directory: $stageFull"
        }
        Assert-NoReparsePoint -Root $releaseFull -Path $markerPath
        $marker = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
        if ($marker -cne $script:PackageRootMarkerValue) {
            throw "Refusing to replace a directory with an invalid package ownership marker: $stageFull"
        }
        Remove-SafeDirectory -ConfinementRoot $releaseFull -Path $stageFull
    }
    New-Item -ItemType Directory -Path $stageFull -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $stageFull $script:PackageRootMarkerName), "$($script:PackageRootMarkerValue)`n", (New-Object Text.UTF8Encoding($false)))
    return $stageFull
}

function Assert-PackageZipMatchesStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ZipPath
    )

    $stageFull = Resolve-FullPath -Path $StageRoot -MustExist -PathType Container
    $zipFull = Resolve-FullPath -Path $ZipPath -MustExist -PathType Leaf
    Assert-NoReparsePoint -Root $stageFull -Path $stageFull

    $archiveRoot = Split-Path -Leaf $stageFull
    if ([string]::IsNullOrWhiteSpace($archiveRoot)) { throw 'Package stage has no archive root name.' }
    $stagePrefix = $stageFull.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $expectedFiles = @{}
    $allowedDirectories = @{}
    $allowedDirectories["$archiveRoot/"] = $true

    foreach ($directory in Get-ChildItem -LiteralPath $stageFull -Directory -Recurse -Force) {
        Assert-NoReparsePoint -Root $stageFull -Path $directory.FullName
        if (-not $directory.FullName.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package directory escaped its stage root: $($directory.FullName)"
        }
        $relative = $directory.FullName.Substring($stagePrefix.Length).Replace('\','/')
        $archiveName = "$archiveRoot/$relative/"
        if ($allowedDirectories.ContainsKey($archiveName)) { throw "Case-folded package directory collision: $archiveName" }
        $allowedDirectories[$archiveName] = $true
    }

    foreach ($file in Get-ChildItem -LiteralPath $stageFull -File -Recurse -Force) {
        Assert-NoReparsePoint -Root $stageFull -Path $file.FullName
        if (-not $file.FullName.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package file escaped its stage root: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($stagePrefix.Length).Replace('\','/')
        $archiveName = "$archiveRoot/$relative"
        if ($expectedFiles.ContainsKey($archiveName)) { throw "Case-folded package file collision: $archiveName" }
        $expectedFiles[$archiveName] = [pscustomobject]@{
            ArchiveName = $archiveName
            FullName = $file.FullName
            Length = [long]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    $seenFiles = @{}
    $seenDirectories = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($zipFull)
    try {
        if ($archive.Entries.Count -eq 0) { throw 'Candidate ZIP contains no entries.' }
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.StartsWith('/') -or $entryName.Contains([char]0)) {
                throw "Candidate ZIP contains an unsafe entry name: $entryName"
            }
            $isDirectory = $entryName.EndsWith('/') -or [string]::IsNullOrEmpty($entry.Name)
            if ($isDirectory) {
                if (-not $entryName.EndsWith('/')) { $entryName += '/' }
                if (-not $allowedDirectories.ContainsKey($entryName)) { throw "Candidate ZIP contains an unexpected directory: $entryName" }
                if ($seenDirectories.ContainsKey($entryName)) { throw "Candidate ZIP contains a duplicate directory: $entryName" }
                $seenDirectories[$entryName] = $true
                continue
            }
            if (-not $expectedFiles.ContainsKey($entryName)) { throw "Candidate ZIP contains an unexpected file: $entryName" }
            $expected = $expectedFiles[$entryName]
            if ($expected.ArchiveName -cne $entryName) { throw "Candidate ZIP changed package path casing: $entryName" }
            if ($seenFiles.ContainsKey($entryName)) { throw "Candidate ZIP contains a duplicate file: $entryName" }
            if ([long]$entry.Length -ne $expected.Length) { throw "Candidate ZIP length mismatch for: $entryName" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $actualHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
            if ($actualHash -cne $expected.Sha256) { throw "Candidate ZIP hash mismatch for: $entryName" }
            $seenFiles[$entryName] = $true
        }
    } finally {
        $archive.Dispose()
    }

    if ($seenFiles.Count -ne $expectedFiles.Count) {
        $missing = @($expectedFiles.Keys | Where-Object { -not $seenFiles.ContainsKey($_) } | Sort-Object)
        throw "Candidate ZIP is missing $($missing.Count) package file(s): $($missing -join ', ')"
    }
    return $true
}

function Publish-PackageZipAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ZipPath
    )
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    $temporaryZip = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ('.package-' + [Guid]::NewGuid().ToString('N') + '.tmp.zip'))
    $backupZip = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ('.package-' + [Guid]::NewGuid().ToString('N') + '.backup.zip'))
    $hadExistingZip = Test-Path -LiteralPath $zipFull -PathType Leaf
    try {
        Compress-Archive -LiteralPath $stageFull -DestinationPath $temporaryZip -CompressionLevel Optimal -ErrorAction Stop
        Assert-PackageZipMatchesStage -StageRoot $stageFull -ZipPath $temporaryZip | Out-Null
        $candidateZipHash = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash
        if ($hadExistingZip) {
            [IO.File]::Replace($temporaryZip, $zipFull, $backupZip, $true)
        } else {
            [IO.File]::Move($temporaryZip, $zipFull)
        }
        if (-not (Test-Path -LiteralPath $zipFull -PathType Leaf)) { throw 'Atomic package publication did not produce the final ZIP.' }
        if ((Get-FileHash -LiteralPath $zipFull -Algorithm SHA256).Hash -cne $candidateZipHash) {
            throw 'Atomic package publication changed the validated candidate ZIP.'
        }
        if (Test-Path -LiteralPath $backupZip -PathType Leaf) { Remove-Item -LiteralPath $backupZip -Force }
    } catch {
        $publicationError = $_
        if (Test-Path -LiteralPath $backupZip -PathType Leaf) {
            try {
                if (Test-Path -LiteralPath $zipFull -PathType Leaf) { Remove-Item -LiteralPath $zipFull -Force }
                [IO.File]::Move($backupZip, $zipFull)
            } catch {
                throw "Package publication failed and automatic restoration also failed. The known-good backup is retained at '$backupZip'. Publication error: $($publicationError.Exception.Message) Restoration error: $($_.Exception.Message)"
            }
        } elseif (-not $hadExistingZip -and (Test-Path -LiteralPath $zipFull -PathType Leaf)) {
            Remove-Item -LiteralPath $zipFull -Force
        }
        throw $publicationError
    } finally {
        if (Test-Path -LiteralPath $temporaryZip -PathType Leaf) { Remove-Item -LiteralPath $temporaryZip -Force }
    }
    return $zipFull
}

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
if ($layoutMode -eq 'incomplete-development') { throw 'Development build inputs are incomplete; refusing to package stale prebuilt application bundles.' }
if ($layoutMode -eq 'unverified-portable') { throw 'Portable prebuilt mode requires checksums.sha256; refusing to execute unverified bundled tools.' }
$portablePrebuiltMode = $layoutMode -eq 'portable'
$candidateMode = -not [string]::IsNullOrWhiteSpace($CandidateRevision)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if ($portablePrebuiltMode) {
        $releaseRoot = Join-Path (Split-Path -Parent $root) ((Split-Path -Leaf $root) + '-repack-output')
    } elseif ($candidateMode) {
        $releaseRoot = Join-Path $root 'build\portable-candidate-release'
    } else {
        $releaseRoot = Join-Path $root 'release'
    }
} else {
    $releaseRoot = Resolve-FullPath -Path $OutputDirectory
}
$releaseRoot = Resolve-FullPath -Path $releaseRoot
$stageCandidate = [IO.Path]::GetFullPath((Join-Path $releaseRoot $ReleaseName))
$zipCandidate = [IO.Path]::GetFullPath((Join-Path $releaseRoot "$ReleaseName.zip"))
$protectedProjectSources = @('runtime','scripts','licenses','config','tools','data','revisions','maintenance','app') | ForEach-Object { Join-Path $root $_ }
$outputPlan = Assert-PackageOutputPlan -Root $root -ReleaseRoot $releaseRoot -StageRoot $stageCandidate -ZipPath $zipCandidate -ProtectedSources $protectedProjectSources
if ($portablePrebuiltMode -and (Test-PhysicalPathsOverlap -First $outputPlan.StageRoot -Second $root)) {
    throw 'Portable repack output must be a non-overlapping directory outside the verified source package.'
}
$maintenanceRoot = Join-Path $root 'maintenance'; if (-not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) { New-Item -ItemType Directory -Path $maintenanceRoot | Out-Null }
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$updateLock = $null
$candidateBuildRoot = $null
try {
    $updateLock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -TimeoutSeconds 120
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    Assert-NoPendingRevisionStageInstall -ProjectRoot $root
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    if ($portablePrebuiltMode) {
        Assert-PackageChecksums -ProjectRoot $root | Out-Null
        Write-Host 'Using checksum-verified prebuilt application bundles from the portable package.'
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ($candidateMode) {
        $selected = Assert-Revision -ProjectRoot $root -Revision $CandidateRevision -IdentityMode Index -RequireCurrent
        if ([int]$selected.ManifestSchemaVersion -ne 3) { throw 'Inactive candidate packaging requires a manifest-schema-3 revision.' }
        $candidateReport = Assert-StagedRevisionReport -Path (Join-Path $selected.Root 'stage-report.json') -ExpectedRevision $CandidateRevision
        if ([string]$candidateReport.corpus_revision -cne [string]$selected.CorpusRevision) { throw 'Inactive candidate stage report does not match its verified corpus revision.' }
        if ([int]$pointer.schema_version -eq 2 -and [string]$pointer.active_revision -ceq $CandidateRevision) { throw 'CandidateRevision is already active; use default final packaging instead.' }
    } else {
        if ([int]$pointer.schema_version -ne 2) { throw 'Portable packaging requires an index-identity active pointer. Stage and apply the v1.2 rebuild first, or use -CandidateRevision for an inactive validated schema-3 index.' }
        $selected = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index -RequireCurrent
    }
    foreach ($relativePath in @('runtime','tools','app','scripts')) {
        $candidatePath = Join-Path $root $relativePath
        if (Test-Path -LiteralPath $candidatePath) { Assert-NoReparsePoint -Root $root -Path $candidatePath }
    }
    $node = Ensure-NodeRuntime -Root $root
    $sevenZipPair = Ensure-SevenZipRuntime -Root $root
    $applicationSource = Join-Path $root 'app'
    if (-not $portablePrebuiltMode) {
        $buildRoot = Join-Path $root 'build'
        if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) { New-Item -ItemType Directory -Path $buildRoot | Out-Null }
        $candidateBuildRoot = Reset-SafeDirectory -ConfinementRoot $buildRoot -Path (Join-Path $buildRoot ('portable-candidate-app-' + [Guid]::NewGuid().ToString('N')))
        $applicationSource = Join-Path $candidateBuildRoot 'app'
        $relativeApp = $applicationSource.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        $metaPath = Join-Path $candidateBuildRoot 'esbuild-meta.json'
        $relativeMeta = $metaPath.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        Write-Host 'Building confined package bundles without modifying the working app directory...'
        Invoke-NativeChecked -FilePath $node -Arguments @((Join-Path $root 'scripts\build.mjs'),'--outdir',$relativeApp,'--metafile',$relativeMeta) -FailureMessage 'Application bundling failed.'
    }
    foreach ($fileName in @('server.mjs','indexer.mjs')) {
        Resolve-FullPath -Path (Join-Path $applicationSource $fileName) -MustExist -PathType Leaf | Out-Null
    }
    foreach ($relativePath in @('README.md', 'SPEC.md')) {
        Resolve-FullPath -Path (Join-Path $root $relativePath) -MustExist -PathType Leaf | Out-Null
    }
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $releaseRoot -ErrorAction Stop | Out-Null
    }
    $releaseRoot = Resolve-FullPath -Path $releaseRoot -MustExist -PathType Container
$productionReleaseRoot = [IO.Path]::GetFullPath((Join-Path $root 'release')).TrimEnd('\','/')
if ($candidateMode -and (Test-PhysicalPathsEqual -First $releaseRoot -Second $productionReleaseRoot)) {
    throw 'Inactive candidate packaging must not target the production release directory.'
}
$outputPlan = Assert-PackageOutputPlan -Root $root -ReleaseRoot $releaseRoot -StageRoot $stageCandidate -ZipPath $zipCandidate -ProtectedSources @($protectedProjectSources + @($applicationSource,$selected.Root))
$stageRoot = Reset-OwnedPackageStage -ReleaseRoot $releaseRoot -StageRoot $outputPlan.StageRoot
$zipPath = $outputPlan.ZipPath
Assert-NoReparsePoint -Root $releaseRoot -Path $zipPath

foreach ($directoryName in @('runtime', 'scripts', 'licenses', 'config')) {
    Copy-DirectorySafe -Root $root -Source (Join-Path $root $directoryName) -Destination (Join-Path $stageRoot $directoryName)
}
Copy-DirectorySafe -Root $root -Source $applicationSource -Destination (Join-Path $stageRoot 'app')
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'tools') | Out-Null
foreach ($toolName in @($sevenZipPair.ExeName, $sevenZipPair.DllName)) {
    $toolPath = Resolve-FullPath -Path (Join-Path $root "tools\$toolName") -MustExist -PathType Leaf
    Copy-Item -LiteralPath $toolPath -Destination (Join-Path $stageRoot "tools\$toolName")
}
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'data') | Out-Null
$portablePointer = [ordered]@{
    schema_version=2
    active_revision=[string]$selected.IndexRevision
    previous_revision=$null
    activated_at=if ($candidateMode) { [DateTime]::UtcNow.ToString('O') } else { [string]$pointer.activated_at }
}
Write-JsonAtomic -Path (Join-Path $stageRoot 'data\active.json') -Value $portablePointer -ConfinementRoot $stageRoot
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'revisions') | Out-Null
Copy-DirectorySafe -Root $root -Source $selected.Root -Destination (Join-Path $stageRoot "revisions\$($selected.IndexRevision)")
$portableMaintenanceRoot = Join-Path $stageRoot 'maintenance'
New-Item -ItemType Directory -Path $portableMaintenanceRoot -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $portableMaintenanceRoot '.update.lock'), (New-Object byte[] 0))
$status = $null
try { $status = Get-UpdateStatus -ProjectRoot $root -AllowMissing } catch { Write-Warning "Not packaging invalid update status: $($_.Exception.Message)" }
if (-not $candidateMode -and $null -ne $status -and [string]$status.active_revision -eq [string]$selected.IndexRevision) {
    Copy-Item -LiteralPath (Join-Path $root 'maintenance\update-status.json') -Destination (Join-Path $stageRoot 'maintenance\update-status.json')
}

$rootFiles = @(
    'Install-Codex.ps1',
    'Rebuild-Index.ps1',
    'Uninstall-Codex.ps1',
    'Package-Portable.ps1',
    'Check-DocumentationUpdates.ps1',
    'Update-Documentation.ps1',
    'Rollback-Documentation.ps1',
    'README.md',
    'SPEC.md'
)
foreach ($fileName in $rootFiles) {
    $sourcePath = Resolve-FullPath -Path (Join-Path $root $fileName) -MustExist -PathType Leaf
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stageRoot $fileName)
}

$stageFull = [System.IO.Path]::GetFullPath($stageRoot).TrimEnd('\', '/')
$checksumLines = @(
    Get-ChildItem -LiteralPath $stageFull -Recurse -File -Force |
        Where-Object {
            if ($_.Name -eq 'checksums.sha256') { return $false }
            $relative = $_.FullName.Substring($stageFull.Length).TrimStart('\', '/').Replace('\', '/')
            return @('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -notcontains $relative
        } |
        ForEach-Object {
            $relative = $_.FullName.Substring($stageFull.Length).TrimStart('\', '/').Replace('\', '/')
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            "$hash *$relative"
        } |
        Sort-Object
)
$checksumPath = Join-Path $stageFull 'checksums.sha256'
[System.IO.File]::WriteAllLines($checksumPath, $checksumLines, (New-Object System.Text.UTF8Encoding($false)))
Assert-PackageChecksums -ProjectRoot $stageFull | Out-Null

$zipPath = Publish-PackageZipAtomically -ReleaseRoot $releaseRoot -StageRoot $stageFull -ZipPath $zipPath
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Write-Host "Portable package created: $zipPath"
Write-Host "SHA-256: $zipHash"
} finally {
    if ($null -ne $candidateBuildRoot -and (Test-Path -LiteralPath $candidateBuildRoot -PathType Container)) {
        Remove-SafeDirectory -ConfinementRoot (Join-Path $root 'build') -Path $candidateBuildRoot
    }
    if ($null -ne $updateLock) { $updateLock.Dispose() }
}
