[CmdletBinding(DefaultParameterSetName='Active')]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string]$ReleaseName = 'mql5-chm-mcp-windows-x64',

    [string]$OutputDirectory,

    [Parameter(Mandatory,ParameterSetName='Candidate')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$CandidateRevision,

    [Parameter(ParameterSetName='Candidate')]
    [switch]$AcceptAssetReduction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IndexMaintenance.ps1')

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

function Invoke-PortablePackageFinalCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowNull()][string]$CandidateBuildRoot,
        [AllowNull()][object]$UpdateLock,
        [hashtable]$InternalTestHooks
    )
    try {
        if (
            -not [string]::IsNullOrWhiteSpace($CandidateBuildRoot) -and
            (Test-Path -LiteralPath $CandidateBuildRoot -PathType Container)
        ) {
            $buildRoot = Join-Path $ProjectRoot 'build'
            if ($null -ne $InternalTestHooks -and $InternalTestHooks.ContainsKey('RemoveCandidateBuildRoot')) {
                & $InternalTestHooks.RemoveCandidateBuildRoot $buildRoot $CandidateBuildRoot
            } else {
                Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $CandidateBuildRoot
            }
        }
    } finally {
        if ($null -ne $UpdateLock) { $UpdateLock.Dispose() }
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
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$InternalTestHooks
    )

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

    $getExistingItemHook = if ($null -ne $InternalTestHooks -and $InternalTestHooks.ContainsKey('GetExistingItem')) {
        $getExistingItemHook = $InternalTestHooks['GetExistingItem']
        if (-not ($getExistingItemHook -is [scriptblock])) {
            throw 'GetExistingItem test hook must be a script block.'
        }
        $getExistingItemHook
    } else {
        $null
    }
    $existingItem = Get-FileSystemItemOrFallback -Path $cursor -InternalGetItem $getExistingItemHook
    $existingFullName = [IO.Path]::GetFullPath($existingItem.FullName)
    $existingAttributes = $existingItem.Attributes
    $isContainer = Test-FileSystemItemContainer -Item $existingItem
    if (($existingAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Package path resolves through a reparse point: $existingFullName"
    }
    if ($isContainer) {
        $anchor = Resolve-FullPath -Path $existingFullName -MustExist -PathType Container
        $existingBoundary = $anchor
    } else {
        if ($unresolved.Count -gt 0) { throw "Package path descends from an existing file: $existingFullName" }
        $unresolved.Insert(0, [IO.Path]::GetFileName($existingFullName))
        $anchor = Resolve-FullPath -Path (Split-Path -Parent $existingFullName) -MustExist -PathType Container
        $existingBoundary = $existingFullName
    }

    $volumeRoot = Get-FilesystemRootPath -Path $anchor
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "Cannot determine the volume root for package path: $fullPath" }
    $reparseParameters = @{}
    if ($null -ne $getExistingItemHook) { $reparseParameters.InternalTestHooks = @{GetItem=$getExistingItemHook} }
    Assert-NoReparsePoint -Root $volumeRoot -Path $existingBoundary @reparseParameters

    # Each entry maps one physical ancestor directory to the target's relative
    # components from that ancestor. This remains comparable when an alias is a
    # SUBST root whose lexical parent chain starts at the mapped directory.
    $entries = New-Object 'Collections.Generic.List[object]'
    $relativeParts = New-Object 'Collections.Generic.List[string]'
    foreach ($part in $unresolved) { $relativeParts.Add($part.ToLowerInvariant()) }
    $current = $anchor
    while ($true) {
        if ($current.TrimEnd('\','/').Equals($volumeRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) {
            $current = $volumeRoot
        }
        $current = Resolve-FullPath -Path $current -MustExist -PathType Container
        $identity = Get-PhysicalDirectoryIdentity -Path $current
        $entries.Add([pscustomobject]@{ Identity=$identity; Parts=@($relativeParts.ToArray()) })
        if ($current.TrimEnd('\','/').Equals($volumeRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) { break }

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
        [string]$ManifestPath,
        [string[]]$ProtectedSources = @()
    )
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    Assert-NoReparsePoint -Root $rootFull -Path $rootFull
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = "$ZipPath.manifest.json" }
    $manifestFull = Assert-PathWithin -Root $releaseFull -Path $ManifestPath
    $rootDescriptor = Get-PhysicalPathDescriptor -Path $rootFull
    $releaseDescriptor = Get-PhysicalPathDescriptor -Path $releaseFull
    $stageDescriptor = Get-PhysicalPathDescriptor -Path $stageFull
    $zipDescriptor = Get-PhysicalPathDescriptor -Path $zipFull
    $manifestDescriptor = Get-PhysicalPathDescriptor -Path $manifestFull
    if (Test-PhysicalDescriptorsEqual -FirstDescriptor $zipDescriptor -SecondDescriptor $manifestDescriptor) {
        throw 'Package ZIP and sidecar manifest must be distinct files.'
    }

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
        if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $manifestDescriptor -SecondDescriptor $sourceDescriptor) {
            throw "Package sidecar manifest overlaps a source or immutable path: $sourceFull"
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
    if (Test-PhysicalDescriptorsOverlap -FirstDescriptor $manifestDescriptor -SecondDescriptor $rootDescriptor) {
        $allowedManifestRoots = @((Join-Path $rootFull 'release'), (Join-Path $rootFull 'build'))
        if (@($allowedManifestRoots | Where-Object {
            $allowedManifestDescriptor = Get-PhysicalPathDescriptor -Path $_
            Test-PhysicalDescriptorWithinOrEqual -PathDescriptor $manifestDescriptor -RootDescriptor $allowedManifestDescriptor
        }).Count -eq 0) {
            throw 'Package sidecar manifest must not overwrite a protected project path.'
        }
    }
    return [pscustomobject]@{ ReleaseRoot=$releaseFull; StageRoot=$stageFull; ZipPath=$zipFull; ManifestPath=$manifestFull }
}

function Reset-OwnedPackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReleaseRoot, [Parameter(Mandatory)][string]$StageRoot)
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    Assert-NoReparsePoint -Root $releaseFull -Path $stageFull
    if (Test-Path -LiteralPath $stageFull) {
        $item = Get-FileSystemItemOrFallback -Path $stageFull
        if (-not (Test-FileSystemItemContainer -Item $item)) { throw "Package stage target is not a directory: $stageFull" }
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

function Write-CanonicalPortableActivePointer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ActiveRevision,
        [Parameter(Mandatory)][string]$ActivatedAt
    )

    if ($ActiveRevision -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Portable active revision is not a lowercase SHA-256 value.'
    }
    Assert-UtcIsoTimestamp -Value $ActivatedAt -Context 'portable active pointer activated_at'
    if ($ActivatedAt.IndexOfAny([char[]]"`r`n`"") -ge 0) {
        throw 'Portable active pointer timestamp contains an unsafe character.'
    }

    $target = Resolve-FullPath -Path $Path
    $json = '{"schema_version":2,"active_revision":"' + $ActiveRevision +
        '","previous_revision":null,"activated_at":"' + $ActivatedAt + '"}' + "`n"
    [IO.File]::WriteAllText($target, $json, (New-Object Text.UTF8Encoding($false)))
    return $target
}

function New-ReproduciblePackageZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$SevenZipPath
    )

    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    $sevenZipFull = Resolve-FullPath -Path $SevenZipPath -MustExist -PathType Leaf
    Assert-NoReparsePoint -Root $releaseFull -Path $stageFull
    if (Test-Path -LiteralPath $zipFull) { throw "Candidate ZIP path already exists: $zipFull" }

    $releasePrefix = $releaseFull.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $paths = New-Object 'Collections.Generic.List[string]'
    $pathNodes = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $stageFull -File -Recurse -Force) {
        Assert-NoReparsePoint -Root $stageFull -Path $file.FullName
        if (-not $file.FullName.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package file escaped its release root: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($releasePrefix.Length).Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.IndexOfAny([char[]]"`r`n") -ge 0) {
            throw "Package file has an unsafe archive name: $relative"
        }
        Add-PortableArchivePathNode -Nodes $pathNodes -Path $relative -Kind File -Context 'Package stage'
        $file.Attributes = [IO.FileAttributes]::Archive
        $paths.Add($relative)
    }
    if ($paths.Count -eq 0) { throw 'Package stage contains no files.' }

    $orderedPaths = [string[]]$paths.ToArray()
    [Array]::Sort($orderedPaths, [StringComparer]::OrdinalIgnoreCase)
    $listPath = Join-Path ([IO.Path]::GetTempPath()) ('mql5-chm-package-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllLines($listPath, $orderedPaths, (New-Object Text.UTF8Encoding($false)))
        Push-Location $releaseFull
        try {
            $result = Invoke-NativeCapture -FilePath $sevenZipFull -Arguments @(
                'a','-tzip','-mm=Deflate','-mx=9','-mfb=258','-mpass=15','-mmt=off',
                '-mtc=off','-mtm=off','-mta=off','-mcu=on','-sse','-spd','-scsUTF-8',
                '-bb0','-bd',$zipFull,('@' + $listPath)
            )
        } finally {
            Pop-Location
        }
        if ($result.ExitCode -ne 0) {
            throw "Pinned 7-Zip failed to create the canonical package archive. Exit code: $($result.ExitCode). $($result.Text)"
        }
    } finally {
        if (Test-Path -LiteralPath $listPath -PathType Leaf) { Remove-Item -LiteralPath $listPath -Force }
    }
    return (Resolve-FullPath -Path $zipFull -MustExist -PathType Leaf)
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
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    $archiveRoot = Split-Path -Leaf $stageFull
    if ([string]::IsNullOrWhiteSpace($archiveRoot)) { throw 'Package stage has no archive root name.' }
    $stagePrefix = $stageFull.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $expectedFiles = @{}
    $expectedNodes = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($directory in Get-ChildItem -LiteralPath $stageFull -Directory -Recurse -Force) {
        Assert-NoReparsePoint -Root $stageFull -Path $directory.FullName
        if (-not $directory.FullName.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package directory escaped its stage root: $($directory.FullName)"
        }
        $relative = $directory.FullName.Substring($stagePrefix.Length).Replace('\','/')
        Add-PortableArchivePathNode -Nodes $expectedNodes -Path "$archiveRoot/$relative" -Kind Directory -Context 'Package stage'
    }

    foreach ($file in Get-ChildItem -LiteralPath $stageFull -File -Recurse -Force) {
        Assert-NoReparsePoint -Root $stageFull -Path $file.FullName
        if (-not $file.FullName.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package file escaped its stage root: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($stagePrefix.Length).Replace('\','/')
        $archiveName = "$archiveRoot/$relative"
        Add-PortableArchivePathNode -Nodes $expectedNodes -Path $archiveName -Kind File -Context 'Package stage'
        if ($expectedFiles.ContainsKey($archiveName)) { throw "Case-folded package file collision: $archiveName" }
        $expectedFiles[$archiveName] = [pscustomobject]@{
            ArchiveName = $archiveName
            FullName = $file.FullName
            Length = [long]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    $expectedOrder = [string[]]@($expectedFiles.Values | ForEach-Object ArchiveName)
    [Array]::Sort($expectedOrder, [StringComparer]::OrdinalIgnoreCase)
    $seenFiles = @{}
    $archiveNodes = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($zipFull)
    try {
        if ($archive.Entries.Count -eq 0) { throw 'Candidate ZIP contains no entries.' }
        if ($archive.Entries.Count -ne $expectedOrder.Count) {
            throw "Candidate ZIP entry count does not match its stage: expected $($expectedOrder.Count), found $($archive.Entries.Count)."
        }
        for ($entryIndex = 0; $entryIndex -lt $archive.Entries.Count; $entryIndex++) {
            $entry = $archive.Entries[$entryIndex]
            $entryName = $entry.FullName.Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.StartsWith('/') -or $entryName.Contains([char]0)) {
                throw "Candidate ZIP contains an unsafe entry name: $entryName"
            }
            $isDirectory = $entryName.EndsWith('/') -or [string]::IsNullOrEmpty($entry.Name)
            Add-PortableArchivePathNode -Nodes $archiveNodes -Path $entryName -Kind $(if ($isDirectory) { 'Directory' } else { 'File' }) -Context 'Candidate ZIP'
            if ($isDirectory) {
                throw "Canonical package ZIP must not contain an explicit directory entry: $entryName"
            }
            if ($entryName -cne $expectedOrder[$entryIndex]) {
                throw "Candidate ZIP entry order is not canonical at position $entryIndex`: expected '$($expectedOrder[$entryIndex])', found '$entryName'."
            }
            if (-not $expectedFiles.ContainsKey($entryName)) { throw "Candidate ZIP contains an unexpected file: $entryName" }
            $expected = $expectedFiles[$entryName]
            if ($expected.ArchiveName -cne $entryName) { throw "Candidate ZIP changed package path casing: $entryName" }
            if ($seenFiles.ContainsKey($entryName)) { throw "Candidate ZIP contains a duplicate file: $entryName" }
            if ($entry.LastWriteTime.Year -ne 1980 -or $entry.LastWriteTime.Month -ne 1 -or
                $entry.LastWriteTime.Day -ne 1 -or $entry.LastWriteTime.Hour -ne 0 -or
                $entry.LastWriteTime.Minute -ne 0 -or $entry.LastWriteTime.Second -ne 0 -or
                [int]$entry.ExternalAttributes -ne 32) {
                throw "Candidate ZIP metadata is not canonical for: $entryName"
            }
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

function Test-JsonIntegerValue {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64]
}

function Assert-PackageZipSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$ExpectedFile
    )
    return Assert-PortableZipSidecar -ZipPath $ZipPath -ManifestPath $ManifestPath -ExpectedFile $ExpectedFile
}

function Write-PackageSidecarDurable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256
    )

    if ([IO.Path]::GetFileName($File) -cne $File -or $File -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'Portable ZIP sidecar file name is unsafe.'
    }
    if ($Bytes -lt 0) { throw 'Portable ZIP sidecar byte count must not be negative.' }
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Portable ZIP sidecar SHA-256 is invalid.' }

    $target = Resolve-FullPath -Path $Path
    if (Test-Path -LiteralPath $target) { throw "Prepared JSON path already exists: $target" }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $json = '{"schema_version":1,"file":"' + $File + '","bytes":' +
        $Bytes.ToString([Globalization.CultureInfo]::InvariantCulture) +
        ',"sha256":"' + $Sha256 + '"}' + "`n"
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $encoded = $utf8.GetBytes($json)
        $stream.Write($encoded, 0, $encoded.Length)
        $stream.Flush($true)
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
        throw
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $target
}

function Assert-PreparedPackageManifestShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath, [Parameter(Mandatory)][string]$ExpectedFile)
    $manifestFull = Resolve-FullPath -Path $ManifestPath -MustExist -PathType Leaf
    $manifest = Read-JsonFile -Path $manifestFull -Context 'orphaned portable ZIP sidecar manifest'
    Assert-ExactJsonProperties -Object $manifest -Names @('schema_version','file','bytes','sha256') -Context 'orphaned portable ZIP sidecar manifest'
    if (-not (Test-JsonIntegerValue $manifest.schema_version) -or [int64]$manifest.schema_version -ne 1 -or
        -not ($manifest.file -is [string]) -or [string]$manifest.file -cne $ExpectedFile -or
        -not (Test-JsonIntegerValue $manifest.bytes) -or [int64]$manifest.bytes -lt 0 -or
        -not ($manifest.sha256 -is [string]) -or [string]$manifest.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Orphaned portable ZIP sidecar manifest is malformed or belongs to a different release target.'
    }
    return $manifest
}

function Repair-PackagePreparedOrphans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$CanRebuild
    )
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    $manifestFull = Assert-PathWithin -Root $releaseFull -Path $ManifestPath
    $zipLeaf = [IO.Path]::GetFileName($zipFull)
    $manifestLeaf = [IO.Path]::GetFileName($manifestFull)
    $reserved = @(Get-ChildItem -LiteralPath $releaseFull -Force | Where-Object {
        $_.Name.StartsWith('.package-', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith(".$zipLeaf.backup-", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith(".$manifestLeaf.backup-", [StringComparison]::OrdinalIgnoreCase)
    })
    if ($reserved.Count -eq 0) { return [pscustomobject]@{State='none'} }

    $tokens = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $preparedZip = $null
    $preparedManifest = $null
    $writingZip = $null
    $writingManifest = $null
    foreach ($artifact in $reserved) {
        Assert-NoReparsePoint -Root $releaseFull -Path $artifact.FullName
        if (-not (Test-Path -LiteralPath $artifact.FullName -PathType Leaf)) { throw "Reserved package transaction artifact is not a regular file: $($artifact.FullName)" }
        if ($artifact.Name -cmatch '^\.package-([0-9a-f]{32})\.prepared\.zip$') {
            if ($null -ne $preparedZip) { throw 'Release output contains duplicate orphaned ZIP candidates.' }
            [void]$tokens.Add($Matches[1]); $preparedZip = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.package-([0-9a-f]{32})\.prepared\.manifest\.json$') {
            if ($null -ne $preparedManifest) { throw 'Release output contains duplicate orphaned sidecar candidates.' }
            [void]$tokens.Add($Matches[1]); $preparedManifest = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.package-([0-9a-f]{32})\.writing\.zip$') {
            if ($null -ne $writingZip) { throw 'Release output contains duplicate incomplete ZIP writes.' }
            [void]$tokens.Add($Matches[1]); $writingZip = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.package-([0-9a-f]{32})\.writing\.manifest\.json$') {
            if ($null -ne $writingManifest) { throw 'Release output contains duplicate incomplete sidecar writes.' }
            [void]$tokens.Add($Matches[1]); $writingManifest = $artifact.FullName
        } else {
            throw "Release output contains malformed or unbound reserved package transaction debris: $($artifact.Name)"
        }
    }
    if ($tokens.Count -ne 1) { throw 'Release output contains ambiguous prepared package candidates from different transaction tokens.' }
    if (($null -ne $writingZip -and $null -ne $preparedZip) -or ($null -ne $writingManifest -and $null -ne $preparedManifest)) {
        throw 'Release output contains both writing and prepared artifacts for the same package transaction item.'
    }

    $canonicalPairValid = (Test-Path -LiteralPath $zipFull -PathType Leaf) -and (Test-Path -LiteralPath $manifestFull -PathType Leaf)
    if ($canonicalPairValid) { Assert-PackageZipSidecar -ZipPath $zipFull -ManifestPath $manifestFull -ExpectedFile $zipLeaf | Out-Null }
    $hasWriting = $null -ne $writingZip -or $null -ne $writingManifest
    if ($hasWriting -and -not $canonicalPairValid -and -not $CanRebuild) {
        throw 'Incomplete portable payload writes were preserved until package rebuildability is proven.'
    }
    $preparedValid = $true
    try {
        if ($null -ne $preparedManifest) { Assert-PreparedPackageManifestShape -ManifestPath $preparedManifest -ExpectedFile $zipLeaf | Out-Null }
        if ($null -ne $preparedZip) { Assert-PortableZipInternalChecksumClosure -ZipPath $preparedZip | Out-Null }
        if ($null -ne $preparedZip -and $null -ne $preparedManifest) {
            Assert-PackageZipSidecar -ZipPath $preparedZip -ManifestPath $preparedManifest -ExpectedFile $zipLeaf | Out-Null
        }
    } catch {
        $preparedValid = $false
        if (-not $canonicalPairValid -and -not $CanRebuild) { throw }
    }
    if ($hasWriting -or -not $preparedValid) {
        foreach ($candidate in @($writingZip,$writingManifest,$preparedZip,$preparedManifest)) {
            if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { Remove-Item -LiteralPath $candidate -Force }
        }
        return [pscustomobject]@{State='removed'}
    }
    if ($null -ne $preparedZip -and $null -ne $preparedManifest -and -not $canonicalPairValid) {
        $journalName = ".$zipLeaf.publication-transaction.json"
        Publish-PreparedFileSetTransaction -Root $releaseFull -JournalName $journalName -TransactionRole portable-zip -ExpectedTargetNames @($zipLeaf,$manifestLeaf) -Items @(
            [pscustomobject]@{PreparedPath=$preparedZip;TargetPath=$zipFull},
            [pscustomobject]@{PreparedPath=$preparedManifest;TargetPath=$manifestFull}
        ) | Out-Null
        Assert-PackageZipSidecar -ZipPath $zipFull -ManifestPath $manifestFull -ExpectedFile $zipLeaf | Out-Null
        return [pscustomobject]@{State='published'}
    }
    if (-not $canonicalPairValid -and -not $CanRebuild) {
        throw 'Incomplete pre-journal portable publication cannot be discarded until package rebuildability is proven; all prepared bytes were preserved.'
    }

    # Exact-token candidates are app-owned pre-journal debris. The canonical
    # pair was validated by the caller, or the caller proved it can rebuild.
    foreach ($prepared in @($preparedZip,$preparedManifest)) {
        if ($null -ne $prepared) { Remove-Item -LiteralPath $prepared -Force }
    }
    return [pscustomobject]@{State='removed'}
}

function Repair-PackageZipPublicationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$DeferPreparedOrphans,
        [switch]$CanRebuildPreparedOrphans
    )
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    $manifestFull = Assert-PathWithin -Root $releaseFull -Path $ManifestPath
    if ((Split-Path -Parent $zipFull) -cne $releaseFull -or (Split-Path -Parent $manifestFull) -cne $releaseFull) {
        throw 'Portable ZIP publication targets must be direct children of the selected release directory.'
    }
    $zipLeaf = Assert-TransactionLeafName -Name ([IO.Path]::GetFileName($zipFull)) -Context 'portable ZIP target'
    $manifestLeaf = Assert-TransactionLeafName -Name ([IO.Path]::GetFileName($manifestFull)) -Context 'portable sidecar target'
    if ($manifestLeaf -cne "$zipLeaf.manifest.json") { throw 'Portable ZIP sidecar name does not match the selected release ZIP.' }
    $journalName = ".$zipLeaf.publication-transaction.json"

    $publicationJournals = @(Get-ChildItem -LiteralPath $releaseFull -Force | Where-Object {
        $_.Name.EndsWith('.publication-transaction.json', [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($journal in $publicationJournals) {
        if ($journal.Name -cne $journalName) {
            throw "Release output contains a publication journal for a different release context: $($journal.Name)"
        }
    }
    $journalPath = Join-Path $releaseFull $journalName
    if ((Test-Path -LiteralPath $journalPath) -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw "Package publication journal is not a file: $journalPath" }
    Repair-PreparedFileSetTransaction -Root $releaseFull -JournalName $journalName -ExpectedRole portable-zip -ExpectedTargetNames @($zipLeaf,$manifestLeaf) | Out-Null

    $zipExists = Test-Path -LiteralPath $zipFull -PathType Leaf
    $manifestExists = Test-Path -LiteralPath $manifestFull -PathType Leaf
    if ((Test-Path -LiteralPath $zipFull) -and -not $zipExists) { throw "Package ZIP target is not a regular file: $zipFull" }
    if ((Test-Path -LiteralPath $manifestFull) -and -not $manifestExists) { throw "Package sidecar target is not a regular file: $manifestFull" }
    if ($manifestExists -and -not $zipExists) { throw 'A portable ZIP sidecar exists without its ZIP; refusing an unexplained release state.' }
    if ($zipExists -and $manifestExists) { Assert-PackageZipSidecar -ZipPath $zipFull -ManifestPath $manifestFull -ExpectedFile $zipLeaf | Out-Null }
    if (-not $DeferPreparedOrphans) {
        Repair-PackagePreparedOrphans -ReleaseRoot $releaseFull -ZipPath $zipFull -ManifestPath $manifestFull -CanRebuild:$CanRebuildPreparedOrphans | Out-Null
    }
    return [pscustomobject]@{ZipPath=$zipFull;ManifestPath=$manifestFull;JournalName=$journalName}
}

function Publish-PackageZipAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$ManifestPath,
        [string]$SevenZipPath
    )
    $releaseFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    $stageFull = Assert-PathWithin -Root $releaseFull -Path $StageRoot
    $zipFull = Assert-PathWithin -Root $releaseFull -Path $ZipPath
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = "$ZipPath.manifest.json" }
    if ([string]::IsNullOrWhiteSpace($SevenZipPath)) {
        $defaultToolRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            [IO.Path]::GetFullPath((Get-Location).Path)
        } else {
            Split-Path -Parent $PSScriptRoot
        }
        $SevenZipPath = Join-Path $defaultToolRoot 'tools\7z.exe'
    }
    $manifestFull = Assert-PathWithin -Root $releaseFull -Path $ManifestPath
    $journalName = "." + [IO.Path]::GetFileName($zipFull) + '.publication-transaction.json'
    $journalPath = Join-Path $releaseFull $journalName
    Repair-PackageZipPublicationContext -ReleaseRoot $releaseFull -ZipPath $zipFull -ManifestPath $manifestFull -CanRebuildPreparedOrphans | Out-Null

    $token = [Guid]::NewGuid().ToString('N')
    $writingZip = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ".package-$token.writing.zip")
    $writingManifest = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ".package-$token.writing.manifest.json")
    $temporaryZip = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ".package-$token.prepared.zip")
    $temporaryManifest = Assert-PathWithin -Root $releaseFull -Path (Join-Path $releaseFull ".package-$token.prepared.manifest.json")
    try {
        New-ReproduciblePackageZip -ReleaseRoot $releaseFull -StageRoot $stageFull -ZipPath $writingZip -SevenZipPath $SevenZipPath | Out-Null
        $zipStream = [IO.File]::Open($writingZip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { $zipStream.Flush($true) } finally { $zipStream.Dispose() }
        Assert-PackageZipMatchesStage -StageRoot $stageFull -ZipPath $writingZip | Out-Null
        [IO.File]::Move($writingZip,$temporaryZip)
        $candidateItem = Get-FileSystemItemOrFallback -Path $temporaryZip
        $candidateZipHash = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-PackageSidecarDurable -Path $writingManifest -File ([IO.Path]::GetFileName($zipFull)) -Bytes ([int64]$candidateItem.Length) -Sha256 $candidateZipHash | Out-Null
        Assert-PreparedPackageManifestShape -ManifestPath $writingManifest -ExpectedFile ([IO.Path]::GetFileName($zipFull)) | Out-Null
        [IO.File]::Move($writingManifest,$temporaryManifest)
        Assert-PackageZipSidecar -ZipPath $temporaryZip -ManifestPath $temporaryManifest -ExpectedFile ([IO.Path]::GetFileName($zipFull)) | Out-Null
        Publish-PreparedFileSetTransaction -Root $releaseFull -JournalName $journalName -TransactionRole portable-zip -ExpectedTargetNames @([IO.Path]::GetFileName($zipFull),[IO.Path]::GetFileName($manifestFull)) -Items @(
            [pscustomobject]@{PreparedPath=$temporaryZip;TargetPath=$zipFull},
            [pscustomobject]@{PreparedPath=$temporaryManifest;TargetPath=$manifestFull}
        ) | Out-Null
        return Assert-PackageZipSidecar -ZipPath $zipFull -ManifestPath $manifestFull
    } finally {
        foreach ($writing in @($writingZip,$writingManifest)) {
            if (Test-Path -LiteralPath $writing -PathType Leaf) { Remove-Item -LiteralPath $writing -Force }
        }
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            foreach ($temporary in @($temporaryZip,$temporaryManifest)) {
                if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
            }
        }
    }
}

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
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
$manifestCandidate = [IO.Path]::GetFullPath("$zipCandidate.manifest.json")
$protectedProjectSources = @('runtime','scripts','licenses','config','tools','data','revisions','maintenance','app') | ForEach-Object { Join-Path $root $_ }
$outputPlan = Assert-PackageOutputPlan -Root $root -ReleaseRoot $releaseRoot -StageRoot $stageCandidate -ZipPath $zipCandidate -ManifestPath $manifestCandidate -ProtectedSources $protectedProjectSources
if ($portablePrebuiltMode -and (Test-PhysicalPathsOverlap -First $outputPlan.StageRoot -Second $root)) {
    throw 'Portable repack output must be a non-overlapping directory outside the verified source package.'
}
$maintenanceRoot = Join-Path $root 'maintenance'
if ($portablePrebuiltMode -and -not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) { throw 'Verified portable package is missing its maintenance lock directory.' }
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$updateLock = $null
$candidateBuildRoot = $null
try {
    $updateLock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -IdentityRoot $root -TimeoutSeconds 120
    # Output recovery is deliberately first under the maintenance mutex. A
    # later runtime, provenance, revision, or bundle check must not strand a
    # recoverable ZIP/sidecar publication.
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        if (Test-Path -LiteralPath $releaseRoot) { throw "Package release path is not a directory: $releaseRoot" }
        New-Item -ItemType Directory -Path $releaseRoot -ErrorAction Stop | Out-Null
    }
    $releaseRoot = Resolve-FullPath -Path $releaseRoot -MustExist -PathType Container
    $outputPlan = Assert-PackageOutputPlan -Root $root -ReleaseRoot $releaseRoot -StageRoot $stageCandidate -ZipPath $zipCandidate -ManifestPath $manifestCandidate -ProtectedSources $protectedProjectSources
    Repair-PackageZipPublicationContext -ReleaseRoot $outputPlan.ReleaseRoot -ZipPath $outputPlan.ZipPath -ManifestPath $outputPlan.ManifestPath -DeferPreparedOrphans | Out-Null
    if ($layoutMode -eq 'incomplete-development') { throw 'Development build inputs are incomplete; refusing to package stale prebuilt application bundles.' }
    if ($layoutMode -eq 'unverified-portable') { throw 'Portable prebuilt mode requires checksums.sha256; refusing to execute unverified bundled tools.' }
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    Assert-NoPendingRevisionStageInstall -ProjectRoot $root
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    if ($portablePrebuiltMode) {
        Assert-PackageChecksums -ProjectRoot $root | Out-Null
        Write-Host 'Using checksum-verified prebuilt application bundles from the portable package.'
    }
    foreach ($relativePath in @('runtime','tools','app','scripts')) {
        $candidatePath = Join-Path $root $relativePath
        if (Test-Path -LiteralPath $candidatePath) { Assert-NoReparsePoint -Root $root -Path $candidatePath }
    }
    # Candidate acceptance invokes the database inspector. Repair and
    # provenance-check Node before any candidate-controlled bytes can cause a
    # subprocess launch, then bind that exact verified path into inspection.
    $node = Ensure-PinnedNodeRuntime -ProjectRoot $root -NoDownload:$portablePrebuiltMode
    Assert-NoReservedNodeRuntimeArtifacts -RuntimeRoot (Join-Path $root 'runtime')
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ($candidateMode) {
        $activeBase = Assert-ManifestAndCorpus -ProjectRoot $root
        if ([string]$activeBase.IndexRevision -ceq $CandidateRevision) { throw 'CandidateRevision is already active; use default final packaging instead.' }
        $acceptedCandidate = Assert-CandidateActivationAccepted `
            -ProjectRoot $root `
            -CandidateIndexRevision $CandidateRevision `
            -BaseRevision $activeBase `
            -NodePath $node `
            -AcceptAssetReduction:$AcceptAssetReduction `
            -RequireCurrentSources `
            -RequireCurrentPolicy
        $selected = $acceptedCandidate.Candidate
        if ([int]$selected.ManifestSchemaVersion -ne 3) { throw 'Inactive candidate packaging requires a manifest-schema-3 revision.' }
    } else {
        if ([int]$pointer.schema_version -ne 2) { throw 'Portable packaging requires an index-identity active pointer. Stage and apply the v1.2 rebuild first, or use -CandidateRevision for an inactive validated schema-3 index.' }
        $selected = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index -RequireCurrent -RequireCurrentSources -RequireCurrentPolicy
    }
    $sevenZipPair = Ensure-PinnedSevenZipRuntime -ProjectRoot $root -NoDownload:$portablePrebuiltMode
    Assert-NoReservedSevenZipRuntimeArtifacts -ToolsRoot (Join-Path $root 'tools')
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
        Invoke-NativeChecked -FilePath $node -Arguments @(
            (Join-Path $root 'scripts\Generate-BundledNotices.mjs'),
            '--check',
            '--project-root', $root,
            '--metafile', $metaPath,
            '--metafile-label', 'build/esbuild-meta.json'
        ) -FailureMessage 'Bundled dependency notice coverage is missing or stale.'
        foreach ($fileName in @('server.mjs','indexer.mjs')) {
            $candidateBundle = Resolve-FullPath -Path (Join-Path $applicationSource $fileName) -MustExist -PathType Leaf
            $productionBundle = Resolve-FullPath -Path (Join-Path $root "app\$fileName") -MustExist -PathType Leaf
            if ((Get-FileHash -LiteralPath $candidateBundle -Algorithm SHA256).Hash -cne
                (Get-FileHash -LiteralPath $productionBundle -Algorithm SHA256).Hash) {
                throw "Candidate bundle differs from the tracked production bundle: $fileName. Run the checked-in build script before packaging."
            }
        }
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
$outputPlan = Assert-PackageOutputPlan -Root $root -ReleaseRoot $releaseRoot -StageRoot $stageCandidate -ZipPath $zipCandidate -ManifestPath $manifestCandidate -ProtectedSources @($protectedProjectSources + @($applicationSource,$selected.Root))
$stageRoot = Reset-OwnedPackageStage -ReleaseRoot $releaseRoot -StageRoot $outputPlan.StageRoot
$zipPath = $outputPlan.ZipPath
$manifestPath = $outputPlan.ManifestPath
Assert-NoReparsePoint -Root $releaseRoot -Path $zipPath

foreach ($directoryName in @('runtime', 'scripts', 'licenses', 'config')) {
    Copy-DirectorySafe -Root $root -Source (Join-Path $root $directoryName) -Destination (Join-Path $stageRoot $directoryName)
}
Copy-DirectorySafe -Root $root -Source $applicationSource -Destination (Join-Path $stageRoot 'app')
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'tools') | Out-Null
foreach ($toolName in @($sevenZipPair.ExeName, $sevenZipPair.DllName, '7zip.provenance.json')) {
    $toolPath = Resolve-FullPath -Path (Join-Path $root "tools\$toolName") -MustExist -PathType Leaf
    Copy-Item -LiteralPath $toolPath -Destination (Join-Path $stageRoot "tools\$toolName")
}
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'data') | Out-Null
Write-CanonicalPortableActivePointer `
    -Path (Join-Path $stageRoot 'data\active.json') `
    -ActiveRevision ([string]$selected.IndexRevision) `
    -ActivatedAt $(if ($candidateMode) { [string]$selected.Manifest.indexed_at } else { [string]$pointer.activated_at }) | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'revisions') | Out-Null
Copy-DirectorySafe -Root $root -Source $selected.Root -Destination (Join-Path $stageRoot "revisions\$($selected.IndexRevision)")
$portableMaintenanceRoot = Join-Path $stageRoot 'maintenance'
New-Item -ItemType Directory -Path $portableMaintenanceRoot -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $portableMaintenanceRoot '.update.lock'), (New-Object byte[] 0))

$rootFiles = @(
    'Install-Codex.ps1',
    'Rebuild-Index.ps1',
    'Uninstall-Codex.ps1',
    'Package-Portable.ps1',
    'Check-DocumentationUpdates.ps1',
    'Update-Documentation.ps1',
    'Rollback-Documentation.ps1',
    'package.json',
    'README.md',
    'SPEC.md'
)
foreach ($fileName in $rootFiles) {
    $sourcePath = Resolve-FullPath -Path (Join-Path $root $fileName) -MustExist -PathType Leaf
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stageRoot $fileName)
}

$stageFull = [System.IO.Path]::GetFullPath($stageRoot).TrimEnd('\', '/')
$checksumEntries = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $stageFull -Recurse -File -Force) {
    if ($file.Name -eq 'checksums.sha256') { continue }
    $relative = $file.FullName.Substring($stageFull.Length).TrimStart('\', '/').Replace('\', '/')
    if (@('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -contains $relative) { continue }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $checksumEntries.Add($relative, $hash)
}
$checksumLines = @($checksumEntries.GetEnumerator() | ForEach-Object { "$($_.Value) *$($_.Key)" })
$checksumPath = Join-Path $stageFull 'checksums.sha256'
[System.IO.File]::WriteAllLines($checksumPath, $checksumLines, (New-Object System.Text.UTF8Encoding($false)))
Assert-PackageChecksums -ProjectRoot $stageFull | Out-Null

$publication = Publish-PackageZipAtomically -ReleaseRoot $releaseRoot -StageRoot $stageFull -ZipPath $zipPath -ManifestPath $manifestPath -SevenZipPath $sevenZipPair.Extractor
Write-Host "Portable package created: $($publication.ZipPath)"
Write-Host "Sidecar manifest: $($publication.ManifestPath)"
Write-Host "Bytes: $($publication.Bytes)"
Write-Host "SHA-256: $($publication.Sha256)"
} finally {
    Invoke-PortablePackageFinalCleanup -ProjectRoot $root -CandidateBuildRoot $candidateBuildRoot -UpdateLock $updateLock
}
