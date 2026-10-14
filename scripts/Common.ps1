Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

$script:PinnedNodeVersion = 'v24.17.0'
$script:PinnedNodeArchiveSha256 = 'f2aa33b35b75aca5f3f7b85675a6f6423201053e9381911e64961f3bda2528ab'
$script:PinnedNodeExecutableSha256 = 'c6335d08331c23d68b9f2b18adb102002d76ef150b47248e954c507e0d033664'
$script:PinnedNodeLicenseSha256 = '8efdacdc1cfa3460aeb7fe98e3c54337b971d5da70e6eee292b73b981acb220c'
$script:PinnedSevenZipVersion = '26.02'
$script:PinnedSevenZipArtifactSha256 = 'db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e'
$script:PinnedSevenZipExecutableSha256 = '83967f1b02b43c4efeda302795722c809e0e81b8307de73558d10484d5676a7d'
$script:PinnedSevenZipLibrarySha256 = '69fd4df057985c40e510e2fac182881c7f85e90aa13ec703f763a8fdb2ce61f8'
$script:PinnedSevenZipLicenseSha256 = '519ac0a4bded9c18ea02e0afb71f663d8c47373bd9facd3ac96a79f51d77765d'
$script:ManifestSchemaVersion = 3
$script:LegacyManifestSchemaVersion = 2
$script:ActivePointerSchemaVersion = 2
$script:IndexContract = 'mql5-chm-index-v3-assets-v4'
$script:SupportedIndexContracts = @('mql5-chm-index-v3-assets-v1','mql5-chm-index-v3-assets-v2','mql5-chm-index-v3-assets-v3','mql5-chm-index-v3-assets-v4')
$script:ExpectedTotalTopics = 4827
$script:MaximumStatusMessageChars = 500

function Get-Mql5CorpusDefinition {
    return @(
        [pscustomobject]@{
            Id = 'mql5'; FileName = 'mql5.chm'
            Sha256 = 'B6B3338A985E1EFEDC2C87FA478F648D7DE53E1DAA6D2A8A9E5359B8878E23FA'
            TopicCount = 4134
            DownloadUri = 'https://www.mql5.com/files/docs/mql5.chm'
            MinimumBytes = 102400; MaximumBytes = 104857600
        },
        [pscustomobject]@{
            Id = 'mql5book'; FileName = 'mql5book.chm'
            Sha256 = '4C0D0E6CE858B410F63969FC5D6B64076DA73AE7F4C010C212B6993D018A1F17'
            TopicCount = 581
            DownloadUri = 'https://www.mql5.com/files/book/mql5book.chm?v=2'
            MinimumBytes = 102400; MaximumBytes = 104857600
        },
        [pscustomobject]@{
            Id = 'neuronetworksbook'; FileName = 'neuronetworksbook.chm'
            Sha256 = 'FE9470E6AC9452E34ECC54CD80DDDF59475C8AE23CAC7B5EF071B17F1C32D8F5'
            TopicCount = 112
            DownloadUri = 'https://www.mql5.com/files/book/neuronetworksbook.chm?v=2'
            MinimumBytes = 102400; MaximumBytes = 104857600
        }
    )
}

function Assert-CurrentCorpusSourceIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][int]$TopicCount
    )
    $expectedSha256 = ([string]$Definition.Sha256).ToLowerInvariant()
    if ($Sha256.ToLowerInvariant() -cne $expectedSha256) {
        throw "Current source '$([string]$Definition.Id)' SHA-256 does not match the release definition."
    }
    if ($TopicCount -ne [int]$Definition.TopicCount) {
        throw "Current source '$([string]$Definition.Id)' topic count does not match the release definition."
    }
}

function Get-CanonicalImagePolicySha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $policyPath = Resolve-FullPath -Path (Join-Path $root 'config\mql5-image-policy.json') -MustExist -PathType Leaf
    Assert-NoReparsePoint -Root $root -Path $policyPath
    $utf8 = New-Object Text.UTF8Encoding($false,$true)
    try { $text = [IO.File]::ReadAllText($policyPath,$utf8) }
    catch { throw "MQL5 image policy is not valid UTF-8: $($_.Exception.Message)" }
    $canonicalText = $text.Replace("`r`n","`n").Replace("`r","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($canonicalText)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-CurrentImagePolicyIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$PolicySha256
    )
    $currentPolicySha256 = Get-CanonicalImagePolicySha256 -ProjectRoot $ProjectRoot
    if ($PolicySha256 -cne $currentPolicySha256) {
        throw 'Revision image policy does not match the current release policy.'
    }
}

function Assert-IndexContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Contract,
        [switch]$RequireCurrent
    )
    if ($script:SupportedIndexContracts -cnotcontains $Contract) {
        throw "Manifest index_contract '$Contract' is unsupported. Supported contracts: $($script:SupportedIndexContracts -join ', ')."
    }
    if ($RequireCurrent -and $Contract -cne $script:IndexContract) {
        throw "The active schema-3 revision uses rollback-only index contract '$Contract'. Current revisions require '$script:IndexContract'."
    }
}

function Get-Mql5ChmLayoutMode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    # checksums.sha256 is the portable package trust boundary. Treat it as
    # authoritative even if an attacker adds development-looking markers.
    if (Test-Path -LiteralPath (Join-Path $root 'checksums.sha256') -PathType Leaf) { return 'portable' }
    # Once a tree carries the portable ownership marker, removal or corruption
    # of its checksum manifest must never downgrade it to development trust.
    if (Test-Path -LiteralPath (Join-Path $root '.mql5-chm-package-root')) { return 'unverified-portable' }
    $requiredDevelopmentFiles = @(
        'scripts\build.mjs',
        'package.json',
        'src\server.mjs',
        'src\indexer.mjs',
        'config\mql5-query-expansions.json',
        'config\mql5-image-policy.json',
        'scripts\inspect-database.mjs',
        'node_modules\esbuild\package.json'
    )
    $developmentMarkers = @('package.json','src','node_modules')
    $completeDevelopmentTree = @($requiredDevelopmentFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) }).Count -eq 0
    if ($completeDevelopmentTree) { return 'development' }
    $hasDevelopmentMarker = @($developmentMarkers | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) }).Count -gt 0
    if ($hasDevelopmentMarker) { return 'incomplete-development' }
    return 'unverified-portable'
}

function Test-FileSystemItemContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)

    $providerProperty = $Item.PSObject.Properties['PSIsContainer']
    if ($null -ne $providerProperty) { return [bool]$providerProperty.Value }
    return (($Item.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
}

function Get-FileSystemItemOrFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][scriptblock]$InternalGetItem
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $item = if ($null -eq $InternalGetItem) {
        Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    } else {
        & $InternalGetItem $fullPath
    }
    if ($null -ne $item) { return $item }

    # Windows PowerShell 5.1's FileSystem provider can acknowledge an extended
    # volume-GUID path but emit no object. Preserve the same file metadata
    # contract with the underlying .NET filesystem types.
    if ([IO.Directory]::Exists($fullPath)) {
        return New-Object IO.DirectoryInfo -ArgumentList $fullPath
    }
    if ([IO.File]::Exists($fullPath)) {
        return New-Object IO.FileInfo -ArgumentList $fullPath
    }
    throw "Path does not exist: $fullPath"
}

function Resolve-FullPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MustExist,
        [ValidateSet('Any', 'Leaf', 'Container')][string]$PathType = 'Any'
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $MustExist) { return $fullPath }
    $item = Get-FileSystemItemOrFallback -Path $fullPath
    $isContainer = Test-FileSystemItemContainer -Item $item
    if ($PathType -eq 'Leaf' -and $isContainer) { throw "Expected a file but found a directory: $fullPath" }
    if ($PathType -eq 'Container' -and -not $isContainer) { throw "Expected a directory but found a file: $fullPath" }
    return [System.IO.Path]::GetFullPath($item.FullName)
}

function Assert-PathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowRoot
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($AllowRoot) {
            # A drive root must remain C:\, rather than the drive-relative C:.
            $filesystemRoot = Get-FilesystemRootPath -Path $Path
            if ($pathFull.Equals($filesystemRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) { return $filesystemRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar }
            return $pathFull
        }
        throw "Refusing to use the confinement root itself as a target: $pathFull"
    }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its confinement root. Root='$rootFull' Path='$pathFull'"
    }
    return $pathFull
}

function Get-FilesystemRootPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    foreach ($pattern in @(
        '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\',
        '^\\\\\?\\UNC\\[^\\]+\\[^\\]+\\',
        '^\\\\\?\\[A-Za-z]:\\'
    )) {
        $match = [regex]::Match($full, $pattern)
        if ($match.Success) { return $match.Value }
    }
    return [IO.Path]::GetPathRoot($full)
}

function Assert-NoReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$InternalTestHooks
    )
    $itemParameters = @{}
    if ($null -ne $InternalTestHooks) {
        $unexpectedHooks = @($InternalTestHooks.Keys | Where-Object { [string]$_ -cne 'GetItem' })
        if ($unexpectedHooks.Count -gt 0 -or -not ($InternalTestHooks['GetItem'] -is [scriptblock])) {
            throw 'Assert-NoReparsePoint test hooks are invalid.'
        }
        $itemParameters.InternalGetItem = $InternalTestHooks['GetItem']
    }
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    $volumeRoot = Get-FilesystemRootPath -Path $rootFull
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "Cannot determine the filesystem root for confinement path: $rootFull" }
    $ancestorCursor = $volumeRoot
    $ancestorRelative = $rootFull.Substring($volumeRoot.Length).TrimStart('\','/')
    $ancestorSegments = if ([string]::IsNullOrWhiteSpace($ancestorRelative)) { @() } else { @($ancestorRelative -split '[\\/]') }
    foreach ($segment in $ancestorSegments) {
        $ancestorCursor = Join-Path $ancestorCursor $segment
        $ancestorItem = Get-FileSystemItemOrFallback -Path $ancestorCursor @itemParameters
        if (($ancestorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a confinement root beneath a reparse point: $($ancestorItem.FullName)"
        }
    }
    $pathFull = Assert-PathWithin -Root $rootFull -Path $Path -AllowRoot
    $relative = $pathFull.Substring($rootFull.TrimEnd('\', '/').Length).TrimStart('\', '/')
    $cursor = $rootFull
    $segments = if ([string]::IsNullOrWhiteSpace($relative)) { @() } else { @($relative -split '[\\/]') }
    foreach ($segment in $segments) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-FileSystemItemOrFallback -Path $cursor @itemParameters
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to cross a reparse point: $($item.FullName)"
            }
        }
    }
}

function Reset-SafeDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfinementRoot, [Parameter(Mandatory)][string]$Path)
    $rootFull = Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    $pathFull = Assert-PathWithin -Root $rootFull -Path $Path
    Assert-NoReparsePoint -Root $rootFull -Path $pathFull
    if (Test-Path -LiteralPath $pathFull) { Remove-Item -LiteralPath $pathFull -Recurse -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $pathFull) { throw "Directory still exists after cleanup: $pathFull" }
    New-Item -ItemType Directory -Path $pathFull -ErrorAction Stop | Out-Null
    return $pathFull
}

function Remove-SafeDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfinementRoot, [Parameter(Mandatory)][string]$Path)
    $rootFull = Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    $pathFull = Assert-PathWithin -Root $rootFull -Path $Path
    Assert-NoReparsePoint -Root $rootFull -Path $pathFull
    if (Test-Path -LiteralPath $pathFull) { Remove-Item -LiteralPath $pathFull -Recurse -Force -ErrorAction Stop }
}

function Assert-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Expected
    )
    $fullPath = Resolve-FullPath -Path $Path -MustExist -PathType Leaf
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash
    if (-not $actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-256 mismatch for '$fullPath'. Expected $Expected, got $actual."
    }
    return $actual.ToLowerInvariant()
}

function Invoke-NativeChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$FailureMessage = 'Native command failed.',
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 1800
    )
    $result = Invoke-NativeProcessWithTimeout -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -FailureMessage $FailureMessage
    if (-not [string]::IsNullOrEmpty($result.Text)) {
        $result.Text | Out-Host
    }
}

function Invoke-NativeCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 300
    )
    return Invoke-NativeProcessWithTimeout -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -AllowNonZeroExit
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

function New-NativeProcessJob {
    [CmdletBinding()]
    param()

    if ($null -eq ('Mql5ChmMcp.NativeProcessJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Mql5ChmMcp
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectBasicLimitInformation
    {
        internal long PerProcessUserTimeLimit;
        internal long PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSetSize;
        internal UIntPtr MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass;
        internal uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        internal ulong ReadOperationCount;
        internal ulong WriteOperationCount;
        internal ulong OtherOperationCount;
        internal ulong ReadTransferCount;
        internal ulong WriteTransferCount;
        internal ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectExtendedLimitInformation
    {
        internal JobObjectBasicLimitInformation BasicLimitInformation;
        internal IoCounters IoInfo;
        internal UIntPtr ProcessMemoryLimit;
        internal UIntPtr JobMemoryLimit;
        internal UIntPtr PeakProcessMemoryUsed;
        internal UIntPtr PeakJobMemoryUsed;
    }

    public sealed class NativeProcessJob : IDisposable
    {
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private SafeFileHandle handle;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            SafeFileHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);

        public NativeProcessJob()
        {
            IntPtr rawHandle = CreateJobObjectW(IntPtr.Zero, null);
            if (rawHandle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the native process containment job.");
            }

            handle = new SafeFileHandle(rawHandle, true);
            IntPtr information = IntPtr.Zero;
            try
            {
                JobObjectExtendedLimitInformation limits = new JobObjectExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                int size = Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation));
                information = Marshal.AllocHGlobal(size);
                Marshal.StructureToPtr(limits, information, false);
                if (!SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformationClass,
                    information,
                    checked((uint)size)))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not configure the native process containment job.");
                }
            }
            catch
            {
                handle.Dispose();
                handle = null;
                throw;
            }
            finally
            {
                if (information != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(information);
                }
            }
        }

        public void Assign(Process process)
        {
            if (process == null) throw new ArgumentNullException("process");
            ThrowIfDisposed();
            if (!AssignProcessToJobObject(handle, process.Handle))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not assign the native bootstrap to its containment job.");
            }
        }

        public void Terminate(uint exitCode)
        {
            ThrowIfDisposed();
            if (!TerminateJobObject(handle, exitCode))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not terminate the native process containment job.");
            }
        }

        private void ThrowIfDisposed()
        {
            if (handle == null || handle.IsClosed || handle.IsInvalid)
            {
                throw new ObjectDisposedException("NativeProcessJob");
            }
        }

        public void Dispose()
        {
            if (handle == null) return;
            handle.Dispose();
            handle = null;
        }
    }
}
'@
    }
    return New-Object Mql5ChmMcp.NativeProcessJob
}

function Get-NativeBootstrapScript {
    [CmdletBinding()]
    param()
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $payloadLine = [Console]::In.ReadLine()
    $payloadMarker = 'MQL5CHMMCP1:'
    $payloadMarkerIndex = if ($null -eq $payloadLine) { -1 } else { $payloadLine.IndexOf($payloadMarker, [StringComparison]::Ordinal) }
    if ($payloadMarkerIndex -lt 0) { throw 'The native bootstrap did not receive a valid launch payload.' }
    $payloadBase64 = $payloadLine.Substring($payloadMarkerIndex + $payloadMarker.Length)
    if ([string]::IsNullOrEmpty($payloadBase64)) { throw 'The native bootstrap received an empty launch payload.' }
    $strictUtf8 = New-Object Text.UTF8Encoding($false,$true)
    try {
        $payloadBytes = [Convert]::FromBase64String($payloadBase64)
    } catch {
        throw 'The native bootstrap launch payload is not valid base64.'
    }
    $payloadText = $strictUtf8.GetString($payloadBytes)
    $payload = ConvertFrom-Json -InputObject $payloadText -ErrorAction Stop
    $filePath = [string]$payload.file_path
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not [IO.Path]::IsPathRooted($filePath)) {
        throw 'The native bootstrap received an invalid executable path.'
    }
    $workingDirectory = [string]$payload.working_directory
    if ([string]::IsNullOrWhiteSpace($workingDirectory) -or -not [IO.Path]::IsPathRooted($workingDirectory)) {
        throw 'The native bootstrap received an invalid working directory.'
    }
    $extension = [IO.Path]::GetExtension($filePath)
    if ($extension.Equals('.cmd', [StringComparison]::OrdinalIgnoreCase) -or
        $extension.Equals('.bat', [StringComparison]::OrdinalIgnoreCase)) {
        $argumentValues = [string[]]@($payload.argument_values | ForEach-Object { [string]$_ })
        if (@($argumentValues | Where-Object {
            $_.IndexOf([char]0) -ge 0 -or $_.IndexOfAny([char[]]"`r`n") -ge 0
        }).Count -gt 0) {
            throw 'Batch command arguments must not contain NUL, CR, or LF characters.'
        }
        if (@($argumentValues | Where-Object { $_.IndexOf('"') -ge 0 }).Count -gt 0) {
            throw 'Batch command arguments containing quotes cannot be transported safely.'
        }
        $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
            throw 'Cannot locate the trusted Windows system directory for batch process execution.'
        }
        $commandProcessor = [IO.Path]::GetFullPath((Join-Path $systemDirectory 'cmd.exe'))
        $expectedCommandProcessor = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($systemDirectory)) 'cmd.exe'))
        if (-not $commandProcessor.Equals($expectedCommandProcessor, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $commandProcessor -PathType Leaf)) {
            throw 'The batch command processor did not resolve to the trusted Windows system path.'
        }
        $variablePrefix = 'MQL5CHM_BATCH_' + [Guid]::NewGuid().ToString('N').ToUpperInvariant()
        $environmentNames = New-Object 'System.Collections.Generic.List[string]'
        $targetVariable = $variablePrefix + '_TARGET'
        $environmentNames.Add($targetVariable)
        [Environment]::SetEnvironmentVariable($targetVariable, $filePath, [EnvironmentVariableTarget]::Process)
        $commandParts = New-Object 'System.Collections.Generic.List[string]'
        $commandParts.Add('"%'+ $targetVariable + '%"')
        for ($argumentIndex = 0; $argumentIndex -lt $argumentValues.Count; $argumentIndex++) {
            if ($argumentValues[$argumentIndex].Length -eq 0) {
                $commandParts.Add('""')
                continue
            }
            $argumentVariable = $variablePrefix + '_ARG_' + $argumentIndex.ToString([Globalization.CultureInfo]::InvariantCulture)
            $environmentNames.Add($argumentVariable)
            [Environment]::SetEnvironmentVariable($argumentVariable, $argumentValues[$argumentIndex], [EnvironmentVariableTarget]::Process)
            $commandParts.Add('"%' + $argumentVariable + '%"')
        }
        # Each private variable reference is already inside literal quote
        # context. cmd.exe does not recursively expand percent sequences that
        # occur inside a variable value, and delayed expansion stays disabled.
        $commandText = '"' + ($commandParts -join ' ') + '"'
        $nativePreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        if ($null -ne $nativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        try {
            & $commandProcessor '/d' '/v:off' '/s' '/c' $commandText
            $batchExitCode = [int]$LASTEXITCODE
        } finally {
            foreach ($environmentName in $environmentNames) {
                [Environment]::SetEnvironmentVariable($environmentName, $null, [EnvironmentVariableTarget]::Process)
            }
        }
        exit $batchExitCode
    }
    if (-not $extension.Equals('.exe', [StringComparison]::OrdinalIgnoreCase) -and
        -not $extension.Equals('.com', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The native bootstrap received an unsupported target type.'
    }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Mql5ChmMcp
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NativeStartupInfo
    {
        internal int cb;
        internal string lpReserved;
        internal string lpDesktop;
        internal string lpTitle;
        internal int dwX;
        internal int dwY;
        internal int dwXSize;
        internal int dwYSize;
        internal int dwXCountChars;
        internal int dwYCountChars;
        internal int dwFillAttribute;
        internal int dwFlags;
        internal short wShowWindow;
        internal short cbReserved2;
        internal IntPtr lpReserved2;
        internal IntPtr hStdInput;
        internal IntPtr hStdOutput;
        internal IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeProcessInformation
    {
        internal IntPtr hProcess;
        internal IntPtr hThread;
        internal uint dwProcessId;
        internal uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeJobBasicLimitInformation
    {
        internal long PerProcessUserTimeLimit;
        internal long PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSetSize;
        internal UIntPtr MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass;
        internal uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeIoCounters
    {
        internal ulong ReadOperationCount;
        internal ulong WriteOperationCount;
        internal ulong OtherOperationCount;
        internal ulong ReadTransferCount;
        internal ulong WriteTransferCount;
        internal ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeJobExtendedLimitInformation
    {
        internal NativeJobBasicLimitInformation BasicLimitInformation;
        internal NativeIoCounters IoInfo;
        internal UIntPtr ProcessMemoryLimit;
        internal UIntPtr JobMemoryLimit;
        internal UIntPtr PeakProcessMemoryUsed;
        internal UIntPtr PeakJobMemoryUsed;
    }

    public static class NativeSuspendedLauncher
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const int StartfUseStdHandles = 0x00000100;
        private const int StdInputHandle = -10;
        private const int StdOutputHandle = -11;
        private const int StdErrorHandle = -12;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const uint Infinite = 0xffffffff;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitTimeout = 0x00000102;
        private const uint HandleFlagInherit = 0x00000001;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref NativeStartupInfo startupInfo,
            out NativeProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        private static string QuoteArgument(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\r', '\n', '"' }) < 0)
            {
                return value;
            }
            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    slashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', (slashes * 2) + 1);
                    quoted.Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0)
                {
                    quoted.Append('\\', slashes);
                    slashes = 0;
                }
                quoted.Append(character);
            }
            if (slashes > 0) quoted.Append('\\', slashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        public static int Run(string executable, string argumentLine, string workingDirectory)
        {
            IntPtr job = IntPtr.Zero;
            IntPtr information = IntPtr.Zero;
            NativeProcessInformation process = new NativeProcessInformation();
            bool created = false;
            bool assigned = false;
            bool completed = false;
            int result = 0;
            Exception primaryFailure = null;
            List<Exception> cleanupFailures = new List<Exception>();
            try
            {
                if (String.IsNullOrWhiteSpace(executable) ||
                    String.IsNullOrWhiteSpace(workingDirectory) ||
                    executable.IndexOf('\0') >= 0 ||
                    workingDirectory.IndexOf('\0') >= 0 ||
                    (argumentLine != null && argumentLine.IndexOf('\0') >= 0))
                {
                    throw new ArgumentException("The contained native target path, arguments, or working directory are invalid.");
                }
                if (argumentLine == null) argumentLine = String.Empty;

                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the target containment job.");
                }

                NativeJobExtendedLimitInformation limits = new NativeJobExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                int informationSize = Marshal.SizeOf(typeof(NativeJobExtendedLimitInformation));
                information = Marshal.AllocHGlobal(informationSize);
                Marshal.StructureToPtr(limits, information, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformationClass,
                    information,
                    checked((uint)informationSize)))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure the target containment job.");
                }

                NativeStartupInfo startup = new NativeStartupInfo();
                startup.cb = Marshal.SizeOf(typeof(NativeStartupInfo));
                startup.dwFlags = StartfUseStdHandles;
                startup.hStdInput = GetStdHandle(StdInputHandle);
                startup.hStdOutput = GetStdHandle(StdOutputHandle);
                startup.hStdError = GetStdHandle(StdErrorHandle);
                IntPtr invalidHandle = new IntPtr(-1);
                foreach (IntPtr standardHandle in new[] { startup.hStdInput, startup.hStdOutput, startup.hStdError })
                {
                    if (standardHandle == IntPtr.Zero || standardHandle == invalidHandle)
                    {
                        throw new Win32Exception("The native bootstrap has an invalid standard handle.");
                    }
                    if (!SetHandleInformation(standardHandle, HandleFlagInherit, HandleFlagInherit))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not make a native standard handle inheritable.");
                    }
                }
                string commandLineText = QuoteArgument(executable) +
                    (String.IsNullOrEmpty(argumentLine) ? String.Empty : " " + argumentLine);
                if (commandLineText.Length > 32766)
                {
                    throw new ArgumentException("The contained native target command line exceeds the Windows limit.");
                }
                StringBuilder commandLine = new StringBuilder(commandLineText);

                if (!CreateProcessW(
                    executable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended | CreateNoWindow,
                    IntPtr.Zero,
                    workingDirectory,
                    ref startup,
                    out process))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the suspended native target.");
                }
                created = true;

                if (!AssignProcessToJobObject(job, process.hProcess))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not assign the suspended native target to its containment job.");
                }
                assigned = true;

                if (ResumeThread(process.hThread) == 0xffffffff)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resume the contained native target.");
                }
                if (WaitForSingleObject(process.hProcess, Infinite) != WaitObject0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for the contained native target.");
                }
                uint exitCode;
                if (!GetExitCodeProcess(process.hProcess, out exitCode))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the contained native target exit code.");
                }
                result = unchecked((int)exitCode);
                completed = true;
            }
            catch (Exception error)
            {
                primaryFailure = error;
            }
            finally
            {
                if (created && !assigned)
                {
                    try
                    {
                        if (!TerminateProcess(process.hProcess, 1))
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not terminate the unassigned suspended native target.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                }
                if (created && assigned && !completed)
                {
                    try
                    {
                        if (!TerminateJobObject(job, 1))
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not terminate the assigned native target job.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                }
                if (job != IntPtr.Zero)
                {
                    try
                    {
                        if (!CloseHandle(job))
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not close the target containment job.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                    job = IntPtr.Zero;
                }
                if (created && !completed)
                {
                    try
                    {
                        uint cleanupWait = WaitForSingleObject(process.hProcess, 5000);
                        if (cleanupWait == WaitTimeout)
                        {
                            throw new TimeoutException("The contained native target did not terminate during bounded cleanup.");
                        }
                        if (cleanupWait != WaitObject0)
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for the contained native target during cleanup.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                }
                if (process.hThread != IntPtr.Zero)
                {
                    try
                    {
                        if (!CloseHandle(process.hThread))
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not close the contained native target thread handle.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                }
                if (process.hProcess != IntPtr.Zero)
                {
                    try
                    {
                        if (!CloseHandle(process.hProcess))
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not close the contained native target process handle.");
                        }
                    }
                    catch (Exception error)
                    {
                        cleanupFailures.Add(error);
                    }
                }
                if (information != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(information);
                    information = IntPtr.Zero;
                }
            }
            if (primaryFailure != null)
            {
                if (cleanupFailures.Count == 0) throw primaryFailure;
                cleanupFailures.Insert(0, primaryFailure);
                throw new AggregateException("The contained native target failed and cleanup also encountered errors.", cleanupFailures);
            }
            if (cleanupFailures.Count > 0)
            {
                throw new AggregateException("The contained native target cleanup failed.", cleanupFailures);
            }
            return result;
        }
    }
}
"@
    $targetExitCode = [Mql5ChmMcp.NativeSuspendedLauncher]::Run(
        $filePath,
        [string]$payload.argument_line,
        $workingDirectory
    )
    exit ([int]$targetExitCode)
} catch {
    [Console]::Error.WriteLine('Native bootstrap failed: ' + $_.Exception.Message)
    exit 255
}
'@
    return $bootstrap
}

function Get-NativeBootstrapEncodedCommand {
    [CmdletBinding()]
    param()
    $loader = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $bootstrapLine = [Console]::In.ReadLine()
    $bootstrapMarker = 'MQL5CHMBOOT1:'
    $bootstrapMarkerIndex = if ($null -eq $bootstrapLine) { -1 } else { $bootstrapLine.IndexOf($bootstrapMarker, [StringComparison]::Ordinal) }
    if ($bootstrapMarkerIndex -lt 0) { throw 'The native bootstrap loader did not receive a valid script payload.' }
    $bootstrapBase64 = $bootstrapLine.Substring($bootstrapMarkerIndex + $bootstrapMarker.Length)
    $strictUtf8 = New-Object Text.UTF8Encoding($false,$true)
    $bootstrapText = $strictUtf8.GetString([Convert]::FromBase64String($bootstrapBase64))
    & ([ScriptBlock]::Create($bootstrapText))
} catch {
    [Console]::Error.WriteLine('Native bootstrap loader failed: ' + $_.Exception.Message)
    exit 255
}
'@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
}

function Invoke-NativeProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 300,
        [string]$FailureMessage = 'Native process failed.',
        [switch]$AllowNonZeroExit
    )
    $executable = Resolve-FullPath -Path $FilePath -MustExist -PathType Leaf
    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw 'Cannot locate the trusted Windows system directory for native process containment.'
    }
    $bootstrapExecutable = Resolve-FullPath -Path (Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe') -MustExist -PathType Leaf
    $expectedBootstrap = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($systemDirectory)) 'WindowsPowerShell\v1.0\powershell.exe'))
    if (-not $bootstrapExecutable.Equals($expectedBootstrap, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The native process bootstrap did not resolve to the trusted Windows system path: $bootstrapExecutable"
    }
    $workingDirectory = Resolve-FullPath -Path (Get-Location -PSProvider FileSystem).ProviderPath -MustExist -PathType Container
    $argumentLine = (@($Arguments | ForEach-Object { ConvertTo-WindowsNativeArgument -Value ([string]$_) }) -join ' ')
    $extension = [IO.Path]::GetExtension($executable)
    $isBatchTarget = (
        $extension.Equals('.cmd', [StringComparison]::OrdinalIgnoreCase) -or
        $extension.Equals('.bat', [StringComparison]::OrdinalIgnoreCase)
    )
    if (-not $extension.Equals('.exe', [StringComparison]::OrdinalIgnoreCase) -and
        -not $extension.Equals('.com', [StringComparison]::OrdinalIgnoreCase) -and
        -not $isBatchTarget) {
        throw "Native process execution supports only .exe, .com, .cmd, and .bat targets: $executable"
    }
    if ($isBatchTarget) {
        foreach ($argumentValue in @($Arguments | ForEach-Object { [string]$_ })) {
            if ($argumentValue.IndexOf([char]0) -ge 0 -or $argumentValue.IndexOfAny([char[]]"`r`n") -ge 0) {
                throw 'Batch command arguments must not contain NUL, CR, or LF characters.'
            }
            if ($argumentValue.IndexOf('"') -ge 0) {
                throw 'Batch command arguments containing quotes cannot be transported safely.'
            }
        }
    }
    $payloadJson = [pscustomobject]@{
        file_path = $executable
        argument_line = $argumentLine
        argument_values = [string[]]@($Arguments | ForEach-Object { [string]$_ })
        working_directory = $workingDirectory
    } | ConvertTo-Json -Compress -Depth 3
    $payload = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false,$true)).GetBytes($payloadJson))
    $bootstrapPayload = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false,$true)).GetBytes((Get-NativeBootstrapScript)))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $bootstrapExecutable
    $startInfo.Arguments = (@(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        (Get-NativeBootstrapEncodedCommand)
    ) | ForEach-Object { ConvertTo-WindowsNativeArgument -Value ([string]$_) }) -join ' '
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutTask = $null
    $stderrTask = $null
    $job = $null
    $processStarted = $false
    $assignedToJob = $false
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        $job = New-NativeProcessJob
        if (-not $process.Start()) { throw "Could not start native process: $executable" }
        $processStarted = $true
        $job.Assign($process)
        $assignedToJob = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $handoffTask = $process.StandardInput.WriteLineAsync(
            'MQL5CHMBOOT1:' + $bootstrapPayload + "`n" +
            'MQL5CHMMCP1:' + $payload
        )
        $remainingMilliseconds = [Math]::Max(
            [int64]0,
            ([int64]$TimeoutSeconds * 1000) - $deadline.ElapsedMilliseconds
        )
        if ($remainingMilliseconds -le 0 -or -not $handoffTask.Wait([int]$remainingMilliseconds)) {
            try {
                $job.Terminate(1)
            } catch {
                throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline during launch and could not be terminated: $executable", $_.Exception)
            }
            throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline during launch: $executable")
        }
        [void]$handoffTask.GetAwaiter().GetResult()
        $process.StandardInput.Close()

        $remainingMilliseconds = [Math]::Max(
            [int64]0,
            ([int64]$TimeoutSeconds * 1000) - $deadline.ElapsedMilliseconds
        )
        if ($remainingMilliseconds -le 0 -or -not $process.WaitForExit([int]$remainingMilliseconds)) {
            try {
                $job.Terminate(1)
            } catch {
                throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline and could not be terminated: $executable", $_.Exception)
            }
            if (-not $process.WaitForExit(5000)) {
                throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline and its bootstrap did not terminate: $executable")
            }
            throw [TimeoutException]::new("Native process exceeded its $TimeoutSeconds-second deadline: $executable")
        }
        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        # Closing the outer kill-on-close job after the bootstrap exits terminates
        # any batch descendants before they can keep the redirected pipes open.
        $job.Dispose()
        $job = $null
        $drainTask = [Threading.Tasks.Task]::WhenAll(
            [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        )
        $remainingMilliseconds = [Math]::Max(
            [int64]0,
            ([int64]$TimeoutSeconds * 1000) - $deadline.ElapsedMilliseconds
        )
        $drained = $drainTask.IsCompleted
        if (-not $drained -and $remainingMilliseconds -gt 0) {
            $completedTask = [Threading.Tasks.Task]::WhenAny(
                [Threading.Tasks.Task[]]@(
                    $drainTask,
                    [Threading.Tasks.Task]::Delay([int]$remainingMilliseconds)
                )
            ).GetAwaiter().GetResult()
            $drained = [object]::ReferenceEquals($completedTask, $drainTask)
        }
        if (-not $drained) {
            throw [TimeoutException]::new("Native process output exceeded its $TimeoutSeconds-second deadline: $executable")
        }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $text = (($stdout,$stderr | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join [Environment]::NewLine).TrimEnd("`r","`n")
        $lines = if ([string]::IsNullOrEmpty($text)) { @() } else { @($text -split '\r?\n') }
        $diagnostic = Get-NativeDiagnosticTail -Text $text
        if ($exitCode -ne 0 -and -not $AllowNonZeroExit) {
            $suffix = if ([string]::IsNullOrWhiteSpace($diagnostic)) { '' } else { " $diagnostic" }
            throw "$FailureMessage Exit code: $exitCode.$suffix"
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Lines = $lines
            Text = $text
            DiagnosticTail = $diagnostic
        }
    } finally {
        if ($null -ne $job) {
            try { $job.Dispose() } catch {}
        }
        if ($processStarted -and -not $process.HasExited) {
            try {
                if (-not $assignedToJob) { $process.Kill() }
                if (-not $process.WaitForExit(5000)) { $process.Kill() }
            } catch {}
        }
        try { $process.StandardInput.Dispose() } catch {}
        try { $process.StandardOutput.Dispose() } catch {}
        try { $process.StandardError.Dispose() } catch {}
        $process.Dispose()
    }
}

function Resolve-NodeExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$RequireBundled)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $bundled = Join-Path $root 'runtime\node.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) {
        $nodePath = Resolve-FullPath -Path $bundled -MustExist -PathType Leaf
    } elseif ($RequireBundled) {
        throw "Bundled Node.js runtime is missing: $bundled"
    } else {
        $command = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { $command = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($null -eq $command) { throw "Node.js $script:PinnedNodeVersion is required." }
        $nodePath = Resolve-FullPath -Path $command.Source -MustExist -PathType Leaf
    }
    $versionResult = Invoke-NativeCapture -FilePath $nodePath -Arguments @('--version')
    if ($versionResult.ExitCode -ne 0 -or $versionResult.Text.Trim() -ne $script:PinnedNodeVersion) {
        throw "Expected Node.js $script:PinnedNodeVersion at '$nodePath', got '$($versionResult.Text.Trim())'."
    }
    return $nodePath
}

function Get-PhysicalDirectoryIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    $runningOnWindows = if ($null -ne $isWindowsVariable) { [bool]$isWindowsVariable.Value } else { $env:OS -eq 'Windows_NT' }
    if (-not $runningOnWindows) { throw 'The MQL5 CHM maintenance lock requires Windows filesystem identity support.' }

    if ($null -eq ('Mql5ChmMcp.LockIdentityNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Mql5ChmMcp
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct FileId128
    {
        internal ulong Low;
        internal ulong High;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileIdInfo
    {
        internal ulong VolumeSerialNumber;
        internal FileId128 FileId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ByHandleFileInformation
    {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    public static class LockIdentityNative
    {
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileIdInfoClass = 18;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int fileInformationClass,
            out FileIdInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation fileInformation);

        public static string GetDirectoryIdentity(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                0,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the maintenance lock directory.");

                ByHandleFileInformation legacy;
                if (!GetFileInformationByHandle(handle, out legacy))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not identify the maintenance lock directory.");
                if ((legacy.FileAttributes & FileAttributeDirectory) == 0)
                    throw new InvalidOperationException("The maintenance lock parent is not a directory.");
                if ((legacy.FileAttributes & FileAttributeReparsePoint) != 0)
                    throw new InvalidOperationException("The maintenance lock parent is a reparse point.");

                FileIdInfo modern;
                if (GetFileInformationByHandleEx(handle, FileIdInfoClass, out modern, (uint)Marshal.SizeOf(typeof(FileIdInfo))))
                {
                    return string.Format(
                        CultureInfo.InvariantCulture,
                        "fileid128:{0:x16}:{1:x16}{2:x16}",
                        modern.VolumeSerialNumber,
                        modern.FileId.High,
                        modern.FileId.Low);
                }

                return string.Format(
                    CultureInfo.InvariantCulture,
                    "fileid64:{0:x8}:{1:x8}{2:x8}",
                    legacy.VolumeSerialNumber,
                    legacy.FileIndexHigh,
                    legacy.FileIndexLow);
            }
        }
    }
}
'@ -ErrorAction Stop
    }

    $fullPath = Resolve-FullPath -Path $Path -MustExist -PathType Container
    return [Mql5ChmMcp.LockIdentityNative]::GetDirectoryIdentity($fullPath)
}

function Enter-ExclusiveFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [string]$IdentityRoot,
        [scriptblock]$InternalMutexFactory
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    $parentExistedAtEntry = Test-Path -LiteralPath $parent -PathType Container
    if ((Test-Path -LiteralPath $parent) -and -not $parentExistedAtEntry) { throw "Maintenance lock parent is not a directory: $parent" }
    $lockName = [IO.Path]::GetFileName($fullPath)
    if ([string]::IsNullOrWhiteSpace($lockName)) { throw "Lock path must identify a file name: $fullPath" }
    if ([string]::IsNullOrWhiteSpace($IdentityRoot)) {
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw 'IdentityRoot is required when the maintenance lock directory does not yet exist.'
        }
        $IdentityRoot = $parent
    }
    $identityRootFull = Resolve-FullPath -Path $IdentityRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $identityRootFull -Path $identityRootFull
    $fullPath = Assert-PathWithin -Root $identityRootFull -Path $fullPath
    Assert-NoReparsePoint -Root $identityRootFull -Path $fullPath
    $rootPrefix = $identityRootFull.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $relativeLockPath = $fullPath.Substring($rootPrefix.Length).Replace('/','\')
    # Lexical paths are not a safe mutex identity on Windows: DOS, SUBST,
    # 8.3, and volume-GUID spellings can identify the same physical directory.
    # Bind the mutex to the existing project's filesystem ID plus the intended
    # relative lock path. This identity is stable before and after creation of
    # a fresh clone's maintenance directory.
    $physicalRootIdentity = Get-PhysicalDirectoryIdentity -Path $identityRootFull
    $mutexIdentity = $physicalRootIdentity + "`n" + $relativeLockPath.ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexIdentity)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $mutexName = "Global\Mql5ChmMcp-$digest"
    try {
        $mutex = if ($null -eq $InternalMutexFactory) { New-Object Threading.Mutex($false, $mutexName) } else { & $InternalMutexFactory $mutexName }
    } catch { throw "Could not open the machine-global maintenance mutex '$mutexName'; no maintenance files were changed. $($_.Exception.Message)" }
    if ($null -eq $mutex -or $null -eq $mutex.PSObject.Methods['WaitOne'] -or $null -eq $mutex.PSObject.Methods['ReleaseMutex']) {
        if ($null -ne $mutex -and $null -ne $mutex.PSObject.Methods['Dispose']) { $mutex.Dispose() }
        throw 'The machine-global maintenance mutex factory returned an invalid mutex; no maintenance files were changed.'
    }
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for the exclusive lock after $TimeoutSeconds seconds: $fullPath" }
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            if (Test-Path -LiteralPath $parent) { throw "Maintenance lock parent is not a directory: $parent" }
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $parent = Resolve-FullPath -Path $parent -MustExist -PathType Container
        Assert-NoReparsePoint -Root $identityRootFull -Path $parent
        Assert-NoReparsePoint -Root $identityRootFull -Path $fullPath
        if (Test-Path -LiteralPath $fullPath) {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Maintenance lock marker is not a regular file: $fullPath" }
            $marker = Get-FileSystemItemOrFallback -Path $fullPath
            if (($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [int64]$marker.Length -ne 0) {
                throw "Maintenance lock marker must be a zero-byte regular file: $fullPath"
            }
        } elseif ($parentExistedAtEntry) {
            # A first-use crash can occur after this process creates the
            # development maintenance directory but before it creates the
            # marker. Recover only that narrow, empty-directory state. A tree
            # carrying either portable trust marker must continue to fail
            # closed when its checksummed marker is missing.
            $layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $identityRootFull
            $expectedMaintenanceParent = [IO.Path]::GetFullPath((Join-Path $identityRootFull 'maintenance'))
            $parentEntries = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop)
            if ($lockName -cne '.update.lock' -or $parent -cne $expectedMaintenanceParent -or
                $layoutMode -cnotin @('development','incomplete-development') -or $parentEntries.Count -ne 0) {
                throw "Existing maintenance directory is missing its zero-byte lock marker: $fullPath"
            }
            $markerStream = New-Object IO.FileStream($fullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::WriteThrough)
            try { $markerStream.Flush($true) } finally { $markerStream.Dispose() }
        } else {
            $markerStream = New-Object IO.FileStream($fullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::WriteThrough)
            try { $markerStream.Flush($true) } finally { $markerStream.Dispose() }
        }
        $lease = [pscustomobject]@{ Mutex=$mutex; Name=$mutexName; Released=$false; Path=$fullPath }
        $lease | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            if (-not $this.Released) {
                $this.Mutex.ReleaseMutex()
                $this.Mutex.Dispose()
                $this.Released = $true
            }
        }
        return $lease
    } catch {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() }
        } else { $mutex.Dispose() }
        throw
    }
}

function Enter-PackageOutputMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$ReleaseName,
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 120,
        [scriptblock]$InternalMutexFactory
    )

    $releaseRootFull = Resolve-FullPath -Path $ReleaseRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $releaseRootFull -Path $releaseRootFull
    $physicalRootIdentity = Get-PhysicalDirectoryIdentity -Path $releaseRootFull
    # Publication recovery and prepared artifacts are release-root scoped, so
    # every release name and source clone targeting this physical root shares
    # one mutex.
    $mutexIdentity = $physicalRootIdentity
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexIdentity)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $mutexName = "Global\Mql5ChmMcp-Package-$digest"
    try {
        $mutex = if ($null -eq $InternalMutexFactory) { New-Object Threading.Mutex($false, $mutexName) } else { & $InternalMutexFactory $mutexName }
    } catch {
        throw "Could not open the machine-global package output mutex '$mutexName'; no package payload or publication was changed. $($_.Exception.Message)"
    }
    if ($null -eq $mutex -or $null -eq $mutex.PSObject.Methods['WaitOne'] -or $null -eq $mutex.PSObject.Methods['ReleaseMutex']) {
        if ($null -ne $mutex -and $null -ne $mutex.PSObject.Methods['Dispose']) { $mutex.Dispose() }
        throw 'The machine-global package output mutex factory returned an invalid mutex; no package payload or publication was changed.'
    }
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for the package output mutex after $TimeoutSeconds seconds: $releaseRootFull\$ReleaseName" }
        $lease = [pscustomobject]@{ Mutex=$mutex; Name=$mutexName; Released=$false; ReleaseRoot=$releaseRootFull; ReleaseName=$ReleaseName }
        $lease | Add-Member ScriptMethod Dispose {
            if (-not $this.Released) {
                $this.Mutex.ReleaseMutex()
                $this.Mutex.Dispose()
                $this.Released = $true
            }
        }
        return $lease
    } catch {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() }
        } else { $mutex.Dispose() }
        throw
    }
}

function Get-RequiredJsonProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name, [string]$Context = 'JSON object')
    if ($null -eq $Object) { throw "$Context is null; expected property '$Name'." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    return $property.Value
}

function Resolve-CodexExecutable {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pathDirectories = New-Object System.Collections.Generic.List[string]
    foreach ($rawDirectory in ([string]$env:Path).Split([IO.Path]::PathSeparator)) {
        $directory = [Environment]::ExpandEnvironmentVariables(([string]$rawDirectory).Trim().Trim('"'))
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        try {
            $directory = [IO.Path]::GetFullPath($directory)
        } catch {
            continue
        }
        $pathDirectories.Add($directory)
    }

    # Preserve PATH directory precedence. Within each directory, prefer npm's
    # command shim before real executable files.
    # Do not use Get-Command here: Windows App Execution Aliases can resolve as
    # applications even when the current process cannot execute them.
    foreach ($directory in $pathDirectories) {
        foreach ($candidateName in @('codex.cmd','codex.exe','codex.com')) {
            try {
                $candidate = Join-Path $directory $candidateName
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop)) { continue }
                $candidate = Resolve-FullPath -Path $candidate -MustExist -PathType Leaf
                if ($seen.Add($candidate)) { $candidates.Add($candidate) }
            } catch {
                continue
            }
        }
    }

    # Codex Desktop keeps runnable CLI builds outside PATH. Prefer the most
    # recently installed cache entry, with a full-path tie-break for stability.
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        try {
            $desktopDirectories = @(Get-ChildItem -LiteralPath $desktopBin -Directory -ErrorAction Stop)
        } catch {
            $desktopDirectories = @()
        }
        $desktopCandidates = @(
            foreach ($directory in $desktopDirectories) {
                $candidate = Join-Path $directory.FullName 'codex.exe'
                try {
                    if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
                        Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
                    }
                } catch {}
            }
        ) | Sort-Object -Property `
            @{Expression={$_.LastWriteTimeUtc.Ticks};Descending=$true}, `
            @{Expression={$_.FullName};Descending=$false}
        foreach ($candidateFile in $desktopCandidates) {
            try {
                $candidate = Resolve-FullPath -Path $candidateFile.FullName -MustExist -PathType Leaf
                if ($seen.Add($candidate)) { $candidates.Add($candidate) }
            } catch {
                continue
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw 'Codex CLI was not found in PATH or the Codex Desktop executable cache.'
    }

    foreach ($candidate in $candidates) {
        try {
            $probe = Invoke-NativeCapture -FilePath $candidate -Arguments @('--version') -TimeoutSeconds 5
            $version = ([string]$probe.Text).Trim()
            if (
                $probe.ExitCode -eq 0 -and
                $version -match '^codex-cli\s+\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
            ) {
                return $candidate
            }
        } catch {
            continue
        }
    }

    throw "Codex CLI candidates were found, but none passed a bounded '--version' capability probe: $($candidates -join ', ')"
}

function Enter-CodexRegistrationMutex {
    [CmdletBinding()]
    param([ValidateRange(1,3600)][int]$TimeoutSeconds = 120)

    $mutexName = 'Global\Mql5ChmMcp-CodexRegistration-v1'
    try { $mutex = New-Object Threading.Mutex($false, $mutexName) } catch {
        throw "Unable to open the machine-global Codex registration mutex '$mutexName': $($_.Exception.Message)"
    }
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for the machine-global Codex registration mutex '$mutexName'." }
        $lease = [pscustomobject]@{ Mutex=$mutex; Name=$mutexName; Released=$false }
        $lease | Add-Member ScriptMethod Dispose {
            if (-not $this.Released) {
                $this.Mutex.ReleaseMutex()
                $this.Mutex.Dispose()
                $this.Released = $true
            }
        }
        return $lease
    } catch {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() }
        } else { $mutex.Dispose() }
        throw
    }
}

function Copy-StreamToFileBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateRange(1,536870912)][int64]$MaximumBytes,
        [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken,
        [AllowNull()][Security.Cryptography.HashAlgorithm]$HashAlgorithm
    )
    $destinationFull = Resolve-FullPath -Path $Destination
    $parent = Resolve-FullPath -Path (Split-Path -Parent $destinationFull) -MustExist -PathType Container
    Assert-NoReparsePoint -Root $parent -Path $destinationFull
    if (Test-Path -LiteralPath $destinationFull) { throw "Download destination already exists: $destinationFull" }
    $output = $null
    try {
        $output = New-Object IO.FileStream($destinationFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::WriteThrough)
        $buffer = New-Object byte[] 1048576
        [int64]$total = 0
        while ($true) {
            $CancellationToken.ThrowIfCancellationRequested()
            $read = $Stream.ReadAsync($buffer, 0, $buffer.Length, $CancellationToken).GetAwaiter().GetResult()
            if ($read -eq 0) {
                if ($null -ne $HashAlgorithm) {
                    [void]$HashAlgorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                }
                break
            }
            if ($total -gt ($MaximumBytes - $read)) { throw "Download exceeded the $MaximumBytes-byte limit." }
            if ($null -ne $HashAlgorithm) {
                [void]$HashAlgorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
            }
            $CancellationToken.ThrowIfCancellationRequested()
            $output.Write($buffer, 0, $read)
            $total += $read
        }
        $output.Flush($true)
        return $total
    } catch {
        if ($null -ne $output) { $output.Dispose(); $output = $null }
        if (Test-Path -LiteralPath $destinationFull -PathType Leaf) { Remove-Item -LiteralPath $destinationFull -Force }
        throw
    } finally {
        if ($null -ne $output) { $output.Dispose() }
    }
}

function Invoke-BoundedNodeJsDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 300,
        [ValidateRange(1,67108864)][int64]$MaximumBytes = 67108864
    )
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Host -cne 'nodejs.org' -or
        -not $Uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($Uri.UserInfo) -or -not [string]::IsNullOrEmpty($Uri.Fragment)) {
        throw 'Node.js downloads must use a credential-free HTTPS URL on nodejs.org with the default port.'
    }
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    if ($handler.PSObject.Properties.Name -contains 'SslProtocols') {
        $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
    }
    $client = New-Object Net.Http.HttpClient($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $Uri)
    [void]$request.Headers.UserAgent.ParseAdd('mql5-chm-mcp-packager/1.3.13')
    $response = $null
    $stream = $null
    $deadline = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) { throw "Node.js download returned HTTP $([int]$response.StatusCode)." }
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and [int64]$contentLength -gt $MaximumBytes) {
            throw "Node.js download declares $contentLength bytes, above the $MaximumBytes-byte limit."
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        return Copy-StreamToFileBounded -Stream $stream -Destination $Destination -MaximumBytes $MaximumBytes -CancellationToken $deadline.Token
    } catch {
        if ($deadline.IsCancellationRequested) { throw "Node.js download exceeded its $TimeoutSeconds-second deadline." }
        throw
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $deadline.Dispose()
    }
}

function Copy-FileDurable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $sourceFull = Resolve-FullPath -Path $Source -MustExist -PathType Leaf
    $destinationFull = Resolve-FullPath -Path $Destination
    if (Test-Path -LiteralPath $destinationFull) { throw "Durable copy destination already exists: $destinationFull" }
    $sourceStream = [IO.File]::Open($sourceFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $output = $null
    try {
        $output = New-Object IO.FileStream($destinationFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::WriteThrough)
        $sourceStream.CopyTo($output, 1048576)
        $output.Flush($true)
    } catch {
        if ($null -ne $output) { $output.Dispose(); $output = $null }
        if (Test-Path -LiteralPath $destinationFull -PathType Leaf) { Remove-Item -LiteralPath $destinationFull -Force }
        throw
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        $sourceStream.Dispose()
    }
    return $destinationFull
}

function Assert-InternalNodeRuntimeTestHooks {
    [CmdletBinding()]
    param([hashtable]$Hooks)

    if ($null -eq $Hooks) { return }
    $allowed = @(
        'ExpectedArchiveSha256',
        'DownloadArchive',
        'ExpandArchive',
        'PeMachineTypeProbe',
        'FileVersionProbe',
        'NativeVersionProbe',
        'PublicationCheckpoint'
    )
    foreach ($key in @($Hooks.Keys)) {
        if ($key -isnot [string] -or $allowed -cnotcontains [string]$key) {
            throw "Unsupported internal Node runtime test hook '$key'."
        }
    }
    foreach ($required in @('ExpectedArchiveSha256','DownloadArchive','ExpandArchive')) {
        if (-not $Hooks.ContainsKey($required)) { throw "Internal Node runtime test hooks are missing '$required'." }
    }
    if ($Hooks.ExpectedArchiveSha256 -isnot [string] -or [string]$Hooks.ExpectedArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Internal Node runtime archive SHA-256 must be a lowercase 64-character hexadecimal string.'
    }
    foreach ($scriptblockName in @('DownloadArchive','ExpandArchive','PeMachineTypeProbe','FileVersionProbe','NativeVersionProbe','PublicationCheckpoint')) {
        if ($Hooks.ContainsKey($scriptblockName) -and $Hooks[$scriptblockName] -isnot [scriptblock]) {
            throw "Internal Node runtime test hook '$scriptblockName' must be a script block."
        }
    }
}

function ConvertTo-ExtendedWindowsPath {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $fullPath }
    if ($fullPath.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $fullPath.Substring(2) }
    return '\\?\' + $fullPath
}

function Get-WindowsExecutableVersionInfo {
    param([Parameter(Mandatory)][string]$Path)
    # FileInfo.VersionInfo can return empty metadata for a valid long path in
    # PowerShell 7. Query the Windows version resource using its extended path.
    try {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo((ConvertTo-ExtendedWindowsPath $Path))
        if ([string]::IsNullOrWhiteSpace($info.FileVersion)) { throw 'No readable Windows version resource.' }
        return $info
    } catch {
        throw "Windows executable metadata is unavailable for '$Path': $($_.Exception.Message)"
    }
}

function Get-PinnedNodeFileVersion {
    param([Parameter(Mandatory)][string]$Path)
    try { return [string](Get-WindowsExecutableVersionInfo $Path).FileVersion }
    catch { return '' }
}

function Get-SevenZipNativeCapability {
    param([Parameter(Mandatory)][string]$ExePath, [scriptblock]$InternalNativeInfoProbe)
    # A verified binary can fail because of native path or DLL-loading limits.
    # Retain a bounded diagnostic rather than treating that as file damage.
    try {
        $probe = if ($null -eq $InternalNativeInfoProbe) { Invoke-NativeCapture -FilePath $ExePath -Arguments @('i') }
            else { & $InternalNativeInfoProbe $ExePath }
        if ($null -eq $probe -or $null -eq $probe.PSObject.Properties['ExitCode'] -or
            $null -eq $probe.PSObject.Properties['Text']) { throw 'The native probe returned no supported result.' }
        if ([int]$probe.ExitCode -eq 0 -and [string]$probe.Text -match '(?m)^7-Zip 26\.02 \(x64\)' -and
            [string]$probe.Text -match '(?im)^\s*.*Chm\s+chm\b') {
            return [pscustomobject]@{State='verified';Reason=$null}
        }
        $detail = "Native probe exit code $($probe.ExitCode); version banner or CHM codec unavailable. $($probe.Text)"
    } catch { $detail = 'Native probe failed: ' + $_.Exception.Message }
    $detail = $detail -replace '[\x00-\x1f\x7f]', ' '
    if ($detail.Length -gt 1024) { $detail = $detail.Substring(0,1024) + ' [truncated]' }
    return [pscustomobject]@{State='execution_unavailable';Reason=$detail}
}

function Assert-SevenZipRuntimeAvailability {
    param([Parameter(Mandatory)]$Assessment, [Parameter(Mandatory)][string]$ExePath)
    if ($Assessment.State -ceq 'metadata_unavailable') {
        throw "7-Zip files match their pinned hashes but Windows version metadata is unavailable: $($Assessment.Reason). No repair download or replacement is performed for this condition; pending evidence is retained. Check file access and Windows version-resource support, then retry."
    }
    if ($Assessment.State -ceq 'execution_unavailable') {
        throw "Verified 7-Zip binaries cannot complete the native version/CHM codec probe at '$ExePath'. No repair download or replacement is performed for this condition; pending evidence is retained. Retry from a shorter package path and a supported working directory; check DLL loading or execution restrictions if it persists. $($Assessment.Reason)"
    }
}

function Test-PinnedNodeRuntimePair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$LicensePath,
        [scriptblock]$InternalPeMachineTypeProbe,
        [scriptblock]$InternalFileVersionProbe,
        [scriptblock]$InternalNativeVersionProbe
    )
    if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf) -or -not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { return $false }
    $node = Get-FileSystemItemOrFallback -Path $NodePath
    $license = Get-FileSystemItemOrFallback -Path $LicensePath
    if (($node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($license.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing a Node.js runtime pair containing a reparse point.'
    }
    if ([int64]$node.Length -ne 92299080 -or [int64]$license.Length -ne 159872) { return $false }
    if ((Get-FileHash -LiteralPath $node.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:PinnedNodeExecutableSha256 -or
        (Get-FileHash -LiteralPath $license.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:PinnedNodeLicenseSha256) { return $false }
    $machineType = if ($null -eq $InternalPeMachineTypeProbe) { Get-PeMachineType -Path $node.FullName } else { & $InternalPeMachineTypeProbe $node.FullName }
    $fileVersion = if ($null -eq $InternalFileVersionProbe) { Get-PinnedNodeFileVersion -Path $node.FullName } else { [string](& $InternalFileVersionProbe $node.FullName) }
    if ([int]$machineType -ne 0x8664 -or $fileVersion -cne '24.17.0') { return $false }
    $version = if ($null -eq $InternalNativeVersionProbe) {
        Invoke-NativeCapture -FilePath $node.FullName -Arguments @('--version')
    } else {
        & $InternalNativeVersionProbe $node.FullName
    }
    if ($null -eq $version -or $null -eq $version.PSObject.Properties['ExitCode'] -or $null -eq $version.PSObject.Properties['Text']) { return $false }
    return $version.ExitCode -eq 0 -and $version.Text.Trim() -ceq $script:PinnedNodeVersion
}

function Test-Mql5ChmRegistrationStructure {
    [CmdletBinding()]
    param([AllowNull()][object]$Registration)
    if ($null -eq $Registration -or $Registration -is [array] -or $Registration -isnot [pscustomobject]) { return $false }
    $nameProperty = $Registration.PSObject.Properties['name']
    $enabledProperty = $Registration.PSObject.Properties['enabled']
    $transportProperty = $Registration.PSObject.Properties['transport']
    if ($null -eq $nameProperty -or $nameProperty.Value -isnot [string] -or [string]$nameProperty.Value -cne 'mql5-chm' -or
        $null -eq $enabledProperty -or $enabledProperty.Value -isnot [bool] -or $null -eq $transportProperty) { return $false }
    $transport = $transportProperty.Value
    if ($null -eq $transport -or $transport -is [array] -or $transport -isnot [pscustomobject]) { return $false }
    foreach ($requiredString in @('type','command')) {
        $property = $transport.PSObject.Properties[$requiredString]
        if ($null -eq $property -or $property.Value -isnot [string]) { return $false }
    }
    $argsProperty = $transport.PSObject.Properties['args']
    if ($null -eq $argsProperty -or $argsProperty.Value -isnot [array]) { return $false }
    foreach ($value in @($argsProperty.Value)) { if ($value -isnot [string]) { return $false } }

    $envProperty = $transport.PSObject.Properties['env']
    if ($null -ne $envProperty -and $null -ne $envProperty.Value) {
        $envValue = $envProperty.Value
        if ($envValue -is [array] -or -not ($envValue -is [pscustomobject] -or $envValue -is [Collections.IDictionary])) { return $false }
        $envEntries = if ($envValue -is [Collections.IDictionary]) {
            @($envValue.Keys | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=$envValue[$_]} })
        } else { @($envValue.PSObject.Properties) }
        foreach ($entry in $envEntries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Name) -or $entry.Value -isnot [string]) { return $false }
        }
    }
    $envVarsProperty = $transport.PSObject.Properties['env_vars']
    if ($null -ne $envVarsProperty -and $null -ne $envVarsProperty.Value) {
        if ($envVarsProperty.Value -isnot [array]) { return $false }
        foreach ($value in @($envVarsProperty.Value)) { if ($value -isnot [string]) { return $false } }
    }
    $cwdProperty = $transport.PSObject.Properties['cwd']
    if ($null -ne $cwdProperty -and $null -ne $cwdProperty.Value -and $cwdProperty.Value -isnot [string]) { return $false }
    foreach ($filterName in @('enabled_tools','disabled_tools')) {
        $filterProperty = $Registration.PSObject.Properties[$filterName]
        if ($null -eq $filterProperty -or $null -eq $filterProperty.Value) { continue }
        if ($filterProperty.Value -isnot [array]) { return $false }
        foreach ($value in @($filterProperty.Value)) { if ($value -isnot [string]) { return $false } }
    }
    return $true
}

function Get-CodexMcpRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CodexPath)

    $result = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'list', '--json')
    if ($result.ExitCode -ne 0) { throw "Unable to list Codex MCP registrations. $($result.Text)" }
    $listText = $result.Text.Trim()
    if (-not $listText.StartsWith('[') -or -not $listText.EndsWith(']')) {
        throw 'Codex returned a non-array JSON value for its MCP registrations.'
    }
    try {
        # Windows PowerShell 5.1 writes a JSON array as one pipeline object,
        # including an empty Object[] for "[]". Assign first, then enumerate it
        # so empty and populated arrays have the same shape as PowerShell 7.
        $parsedRegistrations = $listText | ConvertFrom-Json -ErrorAction Stop
        $registrations = @($parsedRegistrations)
    } catch {
        throw "Codex returned invalid JSON for its MCP registrations: $($_.Exception.Message)"
    }
    $matches = @()
    foreach ($registration in $registrations) {
        if ($null -eq $registration -or $null -eq $registration.PSObject.Properties['name'] -or
            -not ($registration.name -is [string])) {
            throw 'Codex returned a malformed MCP registration list entry.'
        }
        if ([string]$registration.name -ceq 'mql5-chm') { $matches += $registration }
    }
    if ($matches.Count -gt 1) { throw 'Codex returned duplicate mql5-chm registrations.' }
    if ($matches.Count -eq 0) { return $null }

    $details = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'get', 'mql5-chm', '--json')
    if ($details.ExitCode -ne 0) { throw "Codex listed mql5-chm but could not read it. $($details.Text)" }
    $detailText = $details.Text.Trim()
    if (-not $detailText.StartsWith('{') -or -not $detailText.EndsWith('}')) {
        throw 'Codex returned a non-object JSON value for the mql5-chm registration.'
    }
    try { $detail = $detailText | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "Codex returned invalid JSON for the mql5-chm registration: $($_.Exception.Message)"
    }
    if (-not (Test-Mql5ChmRegistrationStructure -Registration $detail)) {
        throw 'Codex returned registration details that are malformed or do not identify the exact mql5-chm entry.'
    }
    return $detail
}

function Test-Mql5ChmRegistrationOwned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Registration,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    try {
        $transportProperty = $Registration.PSObject.Properties['transport']
        if ($null -eq $transportProperty) { return $false }
        $transport = $transportProperty.Value
        if ($null -eq $transport -or $transport -is [array] -or
            -not ($transport -is [pscustomobject] -or $transport -is [Collections.IDictionary])) { return $false }
        $typeProperty = $transport.PSObject.Properties['type']
        $commandProperty = $transport.PSObject.Properties['command']
        if ($null -eq $typeProperty -or $null -eq $commandProperty) { return $false }
        $typeValue = $typeProperty.Value
        $commandValue = $commandProperty.Value
        if ($typeValue -isnot [string] -or $commandValue -isnot [string]) { return $false }
        $type = [string]$typeValue
        $command = [string]$commandValue
        $argumentsProperty = $transport.PSObject.Properties['args']
        if ($null -eq $argumentsProperty) { return $false }
        $rawArguments = $argumentsProperty.Value
        if ($null -eq $rawArguments -or -not ($rawArguments -is [Array])) { return $false }
        $arguments = @($rawArguments)
        if ($arguments.Count -ne 1 -or -not ($arguments[0] -is [string])) { return $false }
        $serverArgument = [string]$arguments[0]
        $commandIsAbsolute = [IO.Path]::IsPathRooted($command) -and
            ($command -match '^[A-Za-z]:[\\/]' -or $command -match '^\\\\[^\\/]+[\\/][^\\/]+')
        $serverIsAbsolute = [IO.Path]::IsPathRooted($serverArgument) -and
            ($serverArgument -match '^[A-Za-z]:[\\/]' -or $serverArgument -match '^\\\\[^\\/]+[\\/][^\\/]+')
        if ($type -cne 'stdio' -or
            -not $commandIsAbsolute -or -not $serverIsAbsolute) { return $false }

        $registeredNode = [IO.Path]::GetFullPath($command)
        $registeredServer = [IO.Path]::GetFullPath([string]$arguments[0])
        $expectedNode = [IO.Path]::GetFullPath($NodePath)
        $expectedServer = [IO.Path]::GetFullPath($ServerPath)
        return (
            $registeredNode.Equals($expectedNode, [StringComparison]::OrdinalIgnoreCase) -and
            $registeredServer.Equals($expectedServer, [StringComparison]::OrdinalIgnoreCase)
        )
    } catch {
        return $false
    }
}

function Test-Mql5ChmRegistrationEquivalent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Registration,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    if (-not (Test-Mql5ChmRegistrationOwned -Registration $Registration -NodePath $NodePath -ServerPath $ServerPath)) {
        return $false
    }
    try {
        $transport = Get-RequiredJsonProperty -Object $Registration -Name 'transport' -Context 'Codex registration'
        $envProperty = $transport.PSObject.Properties['env']
        if ($null -ne $envProperty -and $null -ne $envProperty.Value) {
            $envValue = $envProperty.Value
            $emptyMap = if ($envValue -is [Collections.IDictionary]) {
                $envValue.Count -eq 0
            } elseif ($envValue -is [pscustomobject]) {
                @($envValue.PSObject.Properties).Count -eq 0
            } else { $false }
            if (-not $emptyMap) { return $false }
        }

        $envVarsProperty = $transport.PSObject.Properties['env_vars']
        if ($null -ne $envVarsProperty -and $null -ne $envVarsProperty.Value) {
            $envVars = $envVarsProperty.Value
            if ($envVars -is [string] -or -not ($envVars -is [Collections.IEnumerable]) -or @($envVars).Count -ne 0) { return $false }
        }

        $cwdProperty = $transport.PSObject.Properties['cwd']
        if ($null -ne $cwdProperty -and $null -ne $cwdProperty.Value) {
            $cwd = $cwdProperty.Value
            $packageRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ServerPath)))
            if ($cwd -isnot [string] -or -not [IO.Path]::IsPathRooted($cwd) -or
                -not ($cwd -match '^[A-Za-z]:[\\/]' -or $cwd -match '^\\\\[^\\/]+[\\/][^\\/]+') -or
                -not [IO.Path]::GetFullPath($cwd).TrimEnd('\','/').Equals($packageRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }

        foreach ($filterName in @('enabled_tools','disabled_tools')) {
            $filterProperty = $Registration.PSObject.Properties[$filterName]
            if ($null -eq $filterProperty -or $null -eq $filterProperty.Value) { continue }
            $filterValue = $filterProperty.Value
            # A present allowlist, including [], restricts exposed tools. Only
            # an absent/null allowlist is equivalent to an unfiltered install.
            if ($filterName -ceq 'enabled_tools') { return $false }
            if ($filterValue -is [string] -or -not ($filterValue -is [Collections.IEnumerable]) -or @($filterValue).Count -ne 0) { return $false }
        }

        return $true
    } catch {
        return $false
    }
}

function Test-Mql5ChmRegistrationMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Registration,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )
    return Test-Mql5ChmRegistrationEquivalent -Registration $Registration -NodePath $NodePath -ServerPath $ServerPath
}

function Install-CodexMql5ChmRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    $registrationLock = Enter-CodexRegistrationMutex
    try {
    $existing = Get-CodexMcpRegistration -CodexPath $CodexPath
    if ($null -ne $existing) {
        if (-not (Test-Mql5ChmRegistrationEquivalent -Registration $existing -NodePath $NodePath -ServerPath $ServerPath)) {
            throw "A conflicting Codex MCP registration named 'mql5-chm' already exists. Remove it explicitly before installing this package."
        }
        $enabled = Get-RequiredJsonProperty -Object $existing -Name 'enabled' -Context 'Codex registration'
        if (-not ($enabled -is [bool]) -or -not $enabled) {
            throw 'The existing mql5-chm registration points to this package but is disabled or malformed. Refusing to replace it automatically.'
        }
        return [pscustomobject]@{ State='already-installed'; Registration=$existing }
    }

    $failureMessage = $null
    # A timeout or launch failure can follow a completed write, so it takes the
    # same ownership-checked rollback path as a nonzero exit.
    try {
        $add = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'add', 'mql5-chm', '--', $NodePath, $ServerPath)
    } catch {
        $add = [pscustomobject]@{ ExitCode=-1; Text="Codex add command failed: $($_.Exception.Message)" }
    }
    if ($add.ExitCode -ne 0) {
        $failureMessage = "Failed to register mql5-chm with Codex. Exit code: $($add.ExitCode). $($add.Text)"
    } else {
        try {
            $installed = Get-CodexMcpRegistration -CodexPath $CodexPath
            $enabled = if ($null -eq $installed) { $null } else { Get-RequiredJsonProperty -Object $installed -Name 'enabled' -Context 'Codex registration' }
            if ($null -ne $installed -and
                (Test-Mql5ChmRegistrationEquivalent -Registration $installed -NodePath $NodePath -ServerPath $ServerPath) -and
                $enabled -is [bool] -and $enabled) {
                return [pscustomobject]@{ State='installed'; Registration=$installed }
            }
            $failureMessage = 'Codex reported success, but the installed mql5-chm registration was missing, disabled, malformed, or did not match the verified package paths.'
        } catch {
            $failureMessage = "Codex reported success, but post-install validation failed: $($_.Exception.Message)"
        }
    }

    try { $current = Get-CodexMcpRegistration -CodexPath $CodexPath } catch {
        throw "$failureMessage Rollback was withheld because the current registration could not be inspected safely: $($_.Exception.Message)"
    }
    if ($null -eq $current) { throw "$failureMessage No mql5-chm registration remains." }
    if (-not (Test-Mql5ChmRegistrationOwned -Registration $current -NodePath $NodePath -ServerPath $ServerPath)) {
        throw "$failureMessage Rollback was withheld because the registration now targets a different package."
    }

    try {
        $remove = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'remove', 'mql5-chm')
    } catch {
        $remove = [pscustomobject]@{ ExitCode=-1; Text="Codex remove command failed: $($_.Exception.Message)" }
    }
    $removeFailure = if ($remove.ExitCode -ne 0) { " Automatic rollback command reported exit code $($remove.ExitCode): $($remove.Text)" } else { '' }
    try { $afterRemoval = Get-CodexMcpRegistration -CodexPath $CodexPath } catch {
        throw "$failureMessage$removeFailure Automatic rollback ran, but its postcondition could not be verified: $($_.Exception.Message)"
    }
    if ($null -ne $afterRemoval) {
        throw "$failureMessage$removeFailure Automatic rollback did not leave the registration absent; the observed entry was preserved and no second removal was attempted."
    }
    if ($remove.ExitCode -ne 0) { throw "$failureMessage$removeFailure The registration is nevertheless confirmed absent." }
    throw "$failureMessage The newly created registration was rolled back."
    } finally {
        $registrationLock.Dispose()
    }
}

function Uninstall-CodexMql5ChmRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    $registrationLock = Enter-CodexRegistrationMutex
    try {
    $existing = Get-CodexMcpRegistration -CodexPath $CodexPath
    if ($null -eq $existing) { return [pscustomobject]@{ State='absent' } }
    if (-not (Test-Mql5ChmRegistrationOwned -Registration $existing -NodePath $NodePath -ServerPath $ServerPath)) {
        throw "The mql5-chm registration belongs to a different package path; refusing to remove it."
    }
    try {
        $remove = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'remove', 'mql5-chm')
    } catch {
        $remove = [pscustomobject]@{ ExitCode=-1; Text="Codex remove command failed: $($_.Exception.Message)" }
    }
    $removeFailure = if ($remove.ExitCode -ne 0) { "Codex remove reported exit code $($remove.ExitCode): $($remove.Text)" } else { $null }
    try { $afterRemoval = Get-CodexMcpRegistration -CodexPath $CodexPath } catch {
        $prefix = if ($null -eq $removeFailure) { 'Codex remove ran' } else { $removeFailure }
        throw "$prefix, but the uninstall postcondition could not be inspected safely: $($_.Exception.Message)"
    }
    if ($null -ne $afterRemoval) {
        $prefix = if ($null -eq $removeFailure) { 'Codex reported successful removal' } else { $removeFailure }
        throw "$prefix, but an mql5-chm registration is still present; the observed entry was preserved and no second removal was attempted."
    }
    if ($null -ne $removeFailure) { throw "$removeFailure, but the mql5-chm registration is confirmed absent." }
    return [pscustomobject]@{ State='removed' }
    } finally {
        $registrationLock.Dispose()
    }
}

function Resolve-ClaudeExecutable {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $directories = New-Object System.Collections.Generic.List[string]
    foreach ($rawDirectory in ([string]$env:Path).Split([IO.Path]::PathSeparator)) {
        $directory = [Environment]::ExpandEnvironmentVariables(([string]$rawDirectory).Trim().Trim('"'))
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        try { $directories.Add([IO.Path]::GetFullPath($directory)) } catch { continue }
    }
    # The native installer places claude.exe here even when PATH is not updated.
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $directories.Add((Join-Path $env:USERPROFILE '.local\bin')) }
    foreach ($directory in $directories) {
        foreach ($candidateName in @('claude.exe','claude.cmd')) {
            try {
                $candidate = Join-Path $directory $candidateName
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop)) { continue }
                $candidate = Resolve-FullPath -Path $candidate -MustExist -PathType Leaf
                if ($seen.Add($candidate)) { $candidates.Add($candidate) }
            } catch { continue }
        }
    }
    if ($candidates.Count -eq 0) { throw 'Claude Code CLI was not found in PATH or the native installer location.' }
    foreach ($candidate in $candidates) {
        try {
            $probe = Invoke-NativeCapture -FilePath $candidate -Arguments @('--version') -TimeoutSeconds 15
            if ($probe.ExitCode -eq 0 -and ([string]$probe.Text).Trim() -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\s+\(Claude Code\)$') {
                return $candidate
            }
        } catch { continue }
    }
    throw "Claude Code CLI candidates were found, but none passed a bounded '--version' capability probe: $($candidates -join ', ')"
}

function Enter-ClaudeRegistrationMutex {
    [CmdletBinding()]
    param([ValidateRange(1,3600)][int]$TimeoutSeconds = 120)

    $mutexName = 'Global\Mql5ChmMcp-ClaudeRegistration-v1'
    try { $mutex = New-Object Threading.Mutex($false, $mutexName) } catch {
        throw "Unable to open the machine-global Claude Code registration mutex '$mutexName': $($_.Exception.Message)"
    }
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for the machine-global Claude Code registration mutex '$mutexName'." }
        $lease = [pscustomobject]@{ Mutex=$mutex; Name=$mutexName; Released=$false }
        $lease | Add-Member ScriptMethod Dispose {
            if (-not $this.Released) {
                $this.Mutex.ReleaseMutex()
                $this.Mutex.Dispose()
                $this.Released = $true
            }
        }
        return $lease
    } catch {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() }
        } else { $mutex.Dispose() }
        throw
    }
}

function Get-ClaudeUserConfigPath {
    [CmdletBinding()]
    param()
    # Claude Code keeps user- and local-scope MCP entries in .claude.json:
    # inside CLAUDE_CONFIG_DIR when set, otherwise in the user's home.
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
        return [IO.Path]::GetFullPath((Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'))
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude.json'))
}

function Get-CaseSensitiveJsonMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$Keys
    )
    # Claude's configuration can hold project keys that differ only by case,
    # which ConvertFrom-Json rejects. Return the selected member's JSON text,
    # or its property names with -Keys; $null when a member is absent.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $document = [Text.Json.JsonDocument]::Parse($Text)
        try {
            $element = $document.RootElement
            foreach ($name in $Path) {
                if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { return $null }
                $next = [Text.Json.JsonElement]::new()
                if (-not $element.TryGetProperty([string]$name, [ref]$next)) { return $null }
                $element = $next
            }
            if ($Keys) {
                if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { return $null }
                return ,@($element.EnumerateObject() | ForEach-Object { $_.Name })
            }
            return $element.GetRawText()
        } finally { $document.Dispose() }
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $value = $serializer.DeserializeObject($Text)
    foreach ($name in $Path) {
        if ($value -isnot [Collections.Generic.IDictionary[string,object]] -or -not $value.ContainsKey($name)) { return $null }
        $value = $value[$name]
    }
    if ($Keys) {
        if ($value -isnot [Collections.Generic.IDictionary[string,object]]) { return $null }
        return ,@($value.Keys)
    }
    return $serializer.Serialize($value)
}

function ConvertTo-Mql5ChmClaudeRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryJson)
    # Present a Claude entry in the registration shape used by the shared
    # ownership/equivalence checks. Claude entries have no enabled flag or
    # tool filters in the server entry itself. Require an object root before
    # deserialization: PowerShell 7 unwraps a singleton array.
    $trimmedEntry = $EntryJson.Trim()
    if (-not $trimmedEntry.StartsWith('{') -or -not $trimmedEntry.EndsWith('}')) {
        throw 'Claude Code returned a malformed mql5-chm registration.'
    }
    $entry = $trimmedEntry | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $entry -or $entry -is [array] -or $entry -isnot [pscustomobject]) {
        throw 'Claude Code returned a malformed mql5-chm registration.'
    }
    foreach ($unsupported in @('url','headers')) {
        if ($null -ne $entry.PSObject.Properties[$unsupported]) { throw 'The mql5-chm Claude Code registration is not a stdio entry.' }
    }
    $typeProperty = $entry.PSObject.Properties['type']
    $type = if ($null -eq $typeProperty -or $null -eq $typeProperty.Value) { 'stdio' } else { $typeProperty.Value }
    $commandProperty = $entry.PSObject.Properties['command']
    $argsProperty = $entry.PSObject.Properties['args']
    if ($type -isnot [string] -or $null -eq $commandProperty -or $commandProperty.Value -isnot [string] -or
        ($null -ne $argsProperty -and $null -ne $argsProperty.Value -and $argsProperty.Value -isnot [array])) {
        throw 'Claude Code returned a malformed mql5-chm registration.'
    }
    $arguments = if ($null -eq $argsProperty -or $null -eq $argsProperty.Value) { @() } else { @($argsProperty.Value) }
    foreach ($value in $arguments) { if ($value -isnot [string]) { throw 'Claude Code returned a malformed mql5-chm registration.' } }
    $transport = [pscustomobject]@{ type=$type; command=[string]$commandProperty.Value; args=[object[]]$arguments }
    $envProperty = $entry.PSObject.Properties['env']
    if ($null -ne $envProperty) { $transport | Add-Member NoteProperty env $envProperty.Value }
    $registration = [pscustomobject]@{ name='mql5-chm'; enabled=$true; transport=$transport }
    if (-not (Test-Mql5ChmRegistrationStructure -Registration $registration)) {
        throw 'Claude Code returned a malformed mql5-chm registration.'
    }
    return $registration
}

function Get-ClaudeMcpRegistrations {
    [CmdletBinding()]
    param([string]$ConfigPath = (Get-ClaudeUserConfigPath))

    # Returns the user-scope entry plus any per-project (local-scope) entries
    # that take precedence over it in those projects.
    $result = [pscustomobject]@{ User=$null; LocalProjects=@() }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $result }
    $text = [IO.File]::ReadAllText($ConfigPath)
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }
    $entries = Get-ClaudeConfigMql5ChmEntries -Text $text
    if ($null -ne $entries.User) { $result.User = ConvertTo-Mql5ChmClaudeRegistration -EntryJson $entries.User }
    $result.LocalProjects = @($entries.LocalProjects)
    return $result
}

function Get-ClaudeConfigMql5ChmEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    # One case-sensitive parse of the whole configuration (it can hold many
    # projects): the user-scope entry's JSON text, and the projects that
    # define their own local-scope mql5-chm entry.
    $user = $null
    $local = New-Object System.Collections.Generic.List[string]
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $objectKind = [Text.Json.JsonValueKind]::Object
        $document = [Text.Json.JsonDocument]::Parse($Text)
        try {
            $root = $document.RootElement
            if ($root.ValueKind -eq $objectKind) {
                $servers = [Text.Json.JsonElement]::new()
                $entry = [Text.Json.JsonElement]::new()
                if ($root.TryGetProperty('mcpServers', [ref]$servers) -and $servers.ValueKind -eq $objectKind -and
                    $servers.TryGetProperty('mql5-chm', [ref]$entry)) { $user = $entry.GetRawText() }
                $projects = [Text.Json.JsonElement]::new()
                if ($root.TryGetProperty('projects', [ref]$projects) -and $projects.ValueKind -eq $objectKind) {
                    foreach ($project in $projects.EnumerateObject()) {
                        $projectValue = $project.Value
                        $projectServers = [Text.Json.JsonElement]::new()
                        if ($projectValue.ValueKind -eq $objectKind -and
                            $projectValue.TryGetProperty('mcpServers', [ref]$projectServers) -and
                            $projectServers.ValueKind -eq $objectKind -and
                            $projectServers.TryGetProperty('mql5-chm', [ref]$entry)) { $local.Add($project.Name) }
                    }
                }
            }
        } finally { $document.Dispose() }
    } else {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $root = $serializer.DeserializeObject($Text)
        $mapType = [Collections.Generic.IDictionary[string,object]]
        if ($root -is $mapType) {
            if ($root.ContainsKey('mcpServers') -and $root['mcpServers'] -is $mapType -and $root['mcpServers'].ContainsKey('mql5-chm')) {
                $user = $serializer.Serialize($root['mcpServers']['mql5-chm'])
            }
            if ($root.ContainsKey('projects') -and $root['projects'] -is $mapType) {
                foreach ($key in $root['projects'].Keys) {
                    $project = $root['projects'][$key]
                    if ($project -is $mapType -and $project.ContainsKey('mcpServers') -and $project['mcpServers'] -is $mapType -and
                        $project['mcpServers'].ContainsKey('mql5-chm')) { $local.Add([string]$key) }
                }
            }
        }
    }
    return [pscustomobject]@{ User=$user; LocalProjects=$local.ToArray() }
}

function Install-ClaudeMql5ChmRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudePath,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    $registrationLock = Enter-ClaudeRegistrationMutex
    try {
    $existing = (Get-ClaudeMcpRegistrations).User
    if ($null -ne $existing) {
        if (-not (Test-Mql5ChmRegistrationEquivalent -Registration $existing -NodePath $NodePath -ServerPath $ServerPath)) {
            throw "A conflicting Claude Code user-scope MCP registration named 'mql5-chm' already exists. Remove it explicitly before installing this package."
        }
        return [pscustomobject]@{ State='already-installed'; Registration=$existing; LocalProjects=@((Get-ClaudeMcpRegistrations).LocalProjects) }
    }

    $failureMessage = $null
    # A timeout or launch failure can follow a completed write, so it takes the
    # same ownership-checked rollback path as a nonzero exit.
    try {
        $add = Invoke-NativeCapture -FilePath $ClaudePath -Arguments @('mcp', 'add', '--scope', 'user', 'mql5-chm', '--', $NodePath, $ServerPath) -TimeoutSeconds 120
    } catch {
        $add = [pscustomobject]@{ ExitCode=-1; Text="Claude Code add command failed: $($_.Exception.Message)" }
    }
    if ($add.ExitCode -ne 0) {
        $failureMessage = "Failed to register mql5-chm with Claude Code. Exit code: $($add.ExitCode). $($add.Text)"
    } else {
        try {
            $state = Get-ClaudeMcpRegistrations
            if ($null -ne $state.User -and (Test-Mql5ChmRegistrationEquivalent -Registration $state.User -NodePath $NodePath -ServerPath $ServerPath)) {
                return [pscustomobject]@{ State='installed'; Registration=$state.User; LocalProjects=@($state.LocalProjects) }
            }
            $failureMessage = 'Claude Code reported success, but the user-scope mql5-chm registration was missing, malformed, or did not match the verified package paths.'
        } catch {
            $failureMessage = "Claude Code reported success, but post-install validation failed: $($_.Exception.Message)"
        }
    }

    try { $current = (Get-ClaudeMcpRegistrations).User } catch {
        throw "$failureMessage Rollback was withheld because the current registration could not be inspected safely: $($_.Exception.Message)"
    }
    if ($null -eq $current) { throw "$failureMessage No mql5-chm user-scope registration remains." }
    if (-not (Test-Mql5ChmRegistrationOwned -Registration $current -NodePath $NodePath -ServerPath $ServerPath)) {
        throw "$failureMessage Rollback was withheld because the registration now targets a different package."
    }
    try {
        $remove = Invoke-NativeCapture -FilePath $ClaudePath -Arguments @('mcp', 'remove', '--scope', 'user', 'mql5-chm') -TimeoutSeconds 120
    } catch {
        $remove = [pscustomobject]@{ ExitCode=-1; Text="Claude Code remove command failed: $($_.Exception.Message)" }
    }
    $removeFailure = if ($remove.ExitCode -ne 0) { " Automatic rollback command reported exit code $($remove.ExitCode): $($remove.Text)" } else { '' }
    try { $afterRemoval = (Get-ClaudeMcpRegistrations).User } catch {
        throw "$failureMessage$removeFailure Automatic rollback ran, but its postcondition could not be verified: $($_.Exception.Message)"
    }
    if ($null -ne $afterRemoval) {
        throw "$failureMessage$removeFailure Automatic rollback did not leave the registration absent; the observed entry was preserved and no second removal was attempted."
    }
    if ($remove.ExitCode -ne 0) { throw "$failureMessage$removeFailure The registration is nevertheless confirmed absent." }
    throw "$failureMessage The newly created registration was rolled back."
    } finally {
        $registrationLock.Dispose()
    }
}

function Uninstall-ClaudeMql5ChmRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudePath,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    $registrationLock = Enter-ClaudeRegistrationMutex
    try {
    $existing = (Get-ClaudeMcpRegistrations).User
    if ($null -eq $existing) { return [pscustomobject]@{ State='absent' } }
    if (-not (Test-Mql5ChmRegistrationOwned -Registration $existing -NodePath $NodePath -ServerPath $ServerPath)) {
        throw 'The Claude Code mql5-chm registration belongs to a different package path; refusing to remove it.'
    }
    try {
        $remove = Invoke-NativeCapture -FilePath $ClaudePath -Arguments @('mcp', 'remove', '--scope', 'user', 'mql5-chm') -TimeoutSeconds 120
    } catch {
        $remove = [pscustomobject]@{ ExitCode=-1; Text="Claude Code remove command failed: $($_.Exception.Message)" }
    }
    $removeFailure = if ($remove.ExitCode -ne 0) { "Claude Code remove reported exit code $($remove.ExitCode): $($remove.Text)" } else { $null }
    try { $afterRemoval = (Get-ClaudeMcpRegistrations).User } catch {
        $prefix = if ($null -eq $removeFailure) { 'Claude Code remove ran' } else { $removeFailure }
        throw "$prefix, but the uninstall postcondition could not be inspected safely: $($_.Exception.Message)"
    }
    if ($null -ne $afterRemoval) {
        $prefix = if ($null -eq $removeFailure) { 'Claude Code reported successful removal' } else { $removeFailure }
        throw "$prefix, but an mql5-chm user-scope registration is still present; the observed entry was preserved and no second removal was attempted."
    }
    if ($null -ne $removeFailure) { throw "$removeFailure, but the mql5-chm registration is confirmed absent." }
    return [pscustomobject]@{ State='removed' }
    } finally {
        $registrationLock.Dispose()
    }
}

function Assert-ExactJsonProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Object, [Parameter(Mandatory)][string[]]$Names, [string]$Context = 'JSON object')
    $actual = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) { if ($actual -cnotcontains $name) { throw "$Context is missing required property '$name'." } }
    foreach ($name in $actual) { if ($Names -cnotcontains $name) { throw "$Context contains unsupported property '$name'." } }
}

function Read-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Context = 'JSON file', [switch]$RequireObject)
    $full = Resolve-FullPath -Path $Path -MustExist -PathType Leaf
    try {
        $json = Get-Content -LiteralPath $full -Raw -Encoding UTF8
        # Inspect the serialized root before PowerShell can unwrap a singleton array.
        if ($RequireObject -and ($null -eq $json -or -not $json.TrimStart().StartsWith('{'))) { throw "$Context must be a JSON object." }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $json -DateKind String -ErrorAction Stop }
        return ConvertFrom-Json -InputObject $json -ErrorAction Stop
    } catch { throw "Invalid $Context '$full': $($_.Exception.Message)" }
}

function Get-RevisionJsonField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Object','String','NullableString','Integer','Boolean','Array')][string]$Type,
        [string]$Context = 'revision JSON',
        [long]$Minimum = 0
    )
    if ($Object -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1) { throw "$Context is missing required property '$Name'." }
    # Read the property directly, without pipeline enumeration or scalar casts.
    $value = $properties[0].Value
    $valid = switch ($Type) {
        'Object' { $value -is [pscustomobject] }
        'String' { $value -is [string] -and $value.Length -gt 0 -and $value -cnotmatch '[\x00-\x1f\x7f]' }
        'NullableString' { $null -eq $value -or ($value -is [string] -and $value -cnotmatch '[\x00-\x1f\x7f]') }
        'Boolean' { $value -is [bool] }
        'Array' { $value -is [Array] }
        'Integer' {
            $numeric = (Test-TransactionJsonInteger $value) -or $value -is [double] -or $value -is [single] -or $value -is [decimal]
            $numeric -and $value -ge $Minimum -and $value -le [long]9007199254740991 -and
                -not [double]::IsNaN([double]$value) -and -not [double]::IsInfinity([double]$value) -and
                [Math]::Truncate([double]$value) -eq [double]$value
        }
    }
    if (-not $valid) { throw "$Context.$Name must have JSON type $Type$(if ($Type -ceq 'Integer') { ' in the safe integer range' })." }
    return ,$value
}

function Assert-RevisionStageJournalTypes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Journal)
    Get-RevisionJsonField $Journal 'schema_version' Integer 'revision stage journal' -Minimum 1 | Out-Null
    foreach ($name in @('operation','index_revision','corpus_revision','candidate_tree_sha256','json_digest_contract','stage_report_canonical_sha256','stage_report_file_sha256','started_at')) {
        Get-RevisionJsonField $Journal $name String 'revision stage journal' | Out-Null
    }
    foreach ($name in @('base_index_revision','base_corpus_revision','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256')) {
        Get-RevisionJsonField $Journal $name NullableString 'revision stage journal' | Out-Null
    }
    foreach ($name in @('destination_existed','allow_legacy_active')) { Get-RevisionJsonField $Journal $name Boolean 'revision stage journal' | Out-Null }
    $report = Get-RevisionJsonField $Journal 'stage_report' Object 'revision stage journal'
    Assert-StagedRevisionReportTypes -Report $report
}

function Assert-StagedRevisionReportTypes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Report, [switch]$Legacy)
    $context = if ($Legacy) { 'legacy stage report' } else { 'stage report' }
    Get-RevisionJsonField $Report 'schema_version' Integer $context -Minimum 1 | Out-Null
    $names = if ($Legacy) { @('revision','base_revision','staged_at') } else { @('index_revision','corpus_revision','staged_at') }
    foreach ($name in $names) { Get-RevisionJsonField $Report $name String $context | Out-Null }
    if (-not $Legacy) {
        foreach ($name in @('base_index_revision','base_corpus_revision')) { Get-RevisionJsonField $Report $name NullableString $context | Out-Null }
    }
    Get-RevisionJsonField $Report 'validation_passed' Boolean $context | Out-Null
    foreach ($name in @('source_topic_counts','changes','required_rankings')) { Get-RevisionJsonField $Report $name Object $context | Out-Null }
    foreach ($source in $Report.source_topic_counts.PSObject.Properties) {
        $counts = Get-RevisionJsonField $Report.source_topic_counts $source.Name Object "$context.source_topic_counts"
        foreach ($name in @('base','candidate')) { Get-RevisionJsonField $counts $name Integer "$context.source_topic_counts.$($source.Name)" | Out-Null }
        Get-RevisionJsonField $counts 'delta' Integer "$context.source_topic_counts.$($source.Name)" -Minimum -9007199254740991 | Out-Null
    }
    $groups = @('changes')
    if (-not $Legacy) { Get-RevisionJsonField $Report 'asset_changes' Object $context | Out-Null; $groups += 'asset_changes' }
    foreach ($group in $groups) {
        $value = $Report.PSObject.Properties[$group].Value
        foreach ($property in $value.PSObject.Properties) {
            $name = $property.Name; $fieldContext = "$context.$group"
            if ($name -cmatch '(?:_count|_bytes)$') { Get-RevisionJsonField $value $name Integer $fieldContext | Out-Null }
            elseif ($name -cmatch '_delta$') { Get-RevisionJsonField $value $name Integer $fieldContext -Minimum -9007199254740991 | Out-Null }
            elseif ($name -cmatch '_truncated$' -or $name -ceq 'reduction_requires_review') { Get-RevisionJsonField $value $name Boolean $fieldContext | Out-Null }
            elseif ($name -cmatch '_ids$') {
                $ids = Get-RevisionJsonField $value $name Array $fieldContext
                foreach ($id in $ids) { if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or $id -match '[\x00-\x1f\x7f]') { throw "$fieldContext.$name must contain JSON strings." } }
            }
        }
    }
    foreach ($query in $Report.required_rankings.PSObject.Properties) {
        $ranking = Get-RevisionJsonField $Report.required_rankings $query.Name Object "$context.required_rankings"
        foreach ($name in @('title','source')) { Get-RevisionJsonField $ranking $name String "$context.required_rankings.$($query.Name)" | Out-Null }
    }
}

function Assert-RevisionManifestTypes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)
    $schema = Get-RevisionJsonField $Manifest 'schema_version' Integer 'manifest' -Minimum 1
    $database = Get-RevisionJsonField $Manifest 'database' Object 'manifest'
    foreach ($name in @('filename','sha256')) { Get-RevisionJsonField $database $name String 'manifest.database' | Out-Null }
    Get-RevisionJsonField $database 'bytes' Integer 'manifest.database' -Minimum 1 | Out-Null
    foreach ($name in @('corpus_sha256','indexed_at','build_timestamp')) { Get-RevisionJsonField $Manifest $name String 'manifest' | Out-Null }
    foreach ($name in @('total_topic_count','total_section_count','topic_link_count','resolved_topic_link_count','unresolved_topic_link_count')) { Get-RevisionJsonField $Manifest $name Integer 'manifest' | Out-Null }
    if ($null -ne $Manifest.PSObject.Properties['corpus_revision']) { Get-RevisionJsonField $Manifest 'corpus_revision' NullableString 'manifest' | Out-Null }
    $sources = Get-RevisionJsonField $Manifest 'sources' Object 'manifest'
    $sourceNames = @((Get-Mql5CorpusDefinition).Id)
    Assert-ExactJsonProperties -Object $sources -Names $sourceNames -Context 'manifest.sources'
    foreach ($id in $sourceNames) {
        $source = Get-RevisionJsonField $sources $id Object 'manifest.sources'
        $context = "manifest.sources.$id"
        foreach ($name in @('filename','sha256','retrieved_at')) { Get-RevisionJsonField $source $name String $context | Out-Null }
        foreach ($name in @('bytes','topic_count','section_count')) { Get-RevisionJsonField $source $name Integer $context -Minimum 1 | Out-Null }
        foreach ($name in @('http_last_modified','http_etag')) { Get-RevisionJsonField $source $name NullableString $context | Out-Null }
    }
    if ($schema -eq $script:ManifestSchemaVersion) {
        foreach ($name in @('corpus_revision','index_revision','index_contract')) { Get-RevisionJsonField $Manifest $name String 'manifest' | Out-Null }
        $assets = Get-RevisionJsonField $Manifest 'assets' Object 'manifest'
        foreach ($name in @('directory','catalog_sha256','tree_sha256','policy_sha256')) { Get-RevisionJsonField $assets $name String 'manifest.assets' | Out-Null }
        $counts = @('cataloged_count','exposed_count','excluded_count','occurrence_count','exposed_occurrence_count','total_bytes')
        foreach ($name in $counts) { Get-RevisionJsonField $assets $name Integer 'manifest.assets' | Out-Null }
        $bySource = Get-RevisionJsonField $assets 'by_source' Object 'manifest.assets'
        Assert-ExactJsonProperties -Object $bySource -Names $sourceNames -Context 'manifest.assets.by_source'
        foreach ($id in $sourceNames) {
            $source = Get-RevisionJsonField $bySource $id Object 'manifest.assets.by_source'
            foreach ($name in $counts) { Get-RevisionJsonField $source $name Integer "manifest.assets.by_source.$id" | Out-Null }
        }
    }
}

function Get-PeMachineType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = Resolve-FullPath -Path $Path -MustExist -PathType Leaf
    $stream = [IO.File]::OpenRead($full)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "File is not a PE image: $full" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 6)) { throw "PE header offset is invalid: $full" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "PE signature is invalid: $full" }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-SevenZipProvenance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $provenancePath = Join-Path $root 'tools\7zip.provenance.json'
    $provenance = Read-JsonFile -Path $provenancePath -Context '7-Zip provenance manifest' -RequireObject
    Assert-ExactJsonProperties -Object $provenance -Names @('schema_version','distribution','version','architecture','upstream_url','artifact_bytes','artifact_sha256','files','required_format') -Context '7-Zip provenance manifest'
    if ([int]$provenance.schema_version -ne 1 -or [string]$provenance.distribution -cne 'official-windows-x64-msi' -or
        [string]$provenance.version -cne $script:PinnedSevenZipVersion -or [string]$provenance.architecture -cne 'x64' -or
        [string]$provenance.upstream_url -cne 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.msi' -or
        [int64]$provenance.artifact_bytes -ne 1999872 -or [string]$provenance.artifact_sha256 -cne $script:PinnedSevenZipArtifactSha256 -or
        [string]$provenance.required_format -cne 'Chm') {
        throw '7-Zip provenance manifest does not match the pinned official Windows x64 26.02 distribution.'
    }
    Assert-ExactJsonProperties -Object $provenance.files -Names @('tools/7z.exe','tools/7z.dll','licenses/7ZIP-LICENSE.txt') -Context '7-Zip provenance files'
    $expectations = @(
        [pscustomobject]@{Relative='tools/7z.exe';Bytes=576000;Sha256=$script:PinnedSevenZipExecutableSha256;Version=$script:PinnedSevenZipVersion;Pe=$true},
        [pscustomobject]@{Relative='tools/7z.dll';Bytes=1906688;Sha256=$script:PinnedSevenZipLibrarySha256;Version=$script:PinnedSevenZipVersion;Pe=$true},
        [pscustomobject]@{Relative='licenses/7ZIP-LICENSE.txt';Bytes=6031;Sha256=$script:PinnedSevenZipLicenseSha256;Version=$null;Pe=$false}
    )
    foreach ($expected in $expectations) {
        $entry = $provenance.files.PSObject.Properties[$expected.Relative].Value
        $names = if ($expected.Pe) { @('bytes','sha256','file_version') } else { @('bytes','sha256') }
        Assert-ExactJsonProperties -Object $entry -Names $names -Context "7-Zip provenance entry '$($expected.Relative)'"
        if ([int64]$entry.bytes -ne [int64]$expected.Bytes -or [string]$entry.sha256 -cne [string]$expected.Sha256 -or
            ($expected.Pe -and [string]$entry.file_version -cne [string]$expected.Version)) {
            throw "7-Zip provenance entry does not match the pinned distribution: $($expected.Relative)"
        }
        $filePath = Resolve-FullPath -Path (Join-Path $root $expected.Relative.Replace('/','\')) -MustExist -PathType Leaf
        $item = Get-FileSystemItemOrFallback -Path $filePath
        if ([int64]$item.Length -ne [int64]$expected.Bytes -or
            (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$expected.Sha256) {
            throw "Pinned 7-Zip file failed provenance validation: $filePath"
        }
        if ($expected.Pe) {
            if ([string](Get-WindowsExecutableVersionInfo $filePath).FileVersion -cne [string]$expected.Version -or (Get-PeMachineType -Path $filePath) -ne 0x8664) {
                throw "Pinned 7-Zip file has the wrong version or architecture: $filePath"
            }
        }
    }
    $extractor = Resolve-FullPath -Path (Join-Path $root 'tools\7z.exe') -MustExist -PathType Leaf
    $capability = Get-SevenZipNativeCapability -ExePath $extractor
    Assert-SevenZipRuntimeAvailability -Assessment $capability -ExePath $extractor
    return [pscustomobject]@{ ExeName='7z.exe'; DllName='7z.dll'; Extractor=$extractor; Provenance=$provenancePath }
}

function Assert-UtcIsoTimestamp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value, [string]$Context = 'timestamp')
    if ($Value -notmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z\z') { throw "$Context must be an ISO-8601 UTC timestamp." }
    try { $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { throw "$Context must be an ISO-8601 UTC timestamp." }
    if ($parsed.Offset -ne [TimeSpan]::Zero) { throw "$Context must use UTC." }
}

function Invoke-AtomicFileReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReplacementPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$BackupPath
    )
    [IO.File]::Replace($ReplacementPath, $DestinationPath, $BackupPath, $true)
}

function Publish-PreparedAtomicFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$BackupPath
    )
    $committed = $false
    try {
        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            try {
                Invoke-AtomicFileReplace -ReplacementPath $TemporaryPath -DestinationPath $TargetPath -BackupPath $BackupPath
                $committed = $true
            } catch {
                $replaceFailure = $_.Exception
                $restored = $false
                if (-not (Test-Path -LiteralPath $TargetPath) -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
                    try {
                        [IO.File]::Move($BackupPath, $TargetPath)
                        $restored = $true
                    } catch {
                        # Retain both target-specific artifacts for locked recovery.
                    }
                }
                if ($restored) {
                    if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction Stop }
                    throw $replaceFailure
                }
                throw [IO.IOException]::new("Atomic replacement failed; target-specific recovery artifacts were retained for '$TargetPath'.", $replaceFailure)
            }
        } else {
            [IO.File]::Move($TemporaryPath, $TargetPath)
            $committed = $true
        }
    } finally {
        if ($committed) {
            if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $BackupPath -PathType Leaf) { Remove-Item -LiteralPath $BackupPath -Force -ErrorAction Stop }
        }
    }
}

function Write-JsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$ConfinementRoot)
    $root = Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    $target = Assert-PathWithin -Root $root -Path $Path
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Assert-NoReparsePoint -Root $root -Path $parent
    $leaf = [IO.Path]::GetFileName($target)
    $transactionId = [Guid]::NewGuid().ToString('N')
    $writing = Assert-PathWithin -Root $root -Path (Join-Path $parent (".$leaf.replace.writing-$transactionId"))
    $temporary = Assert-PathWithin -Root $root -Path (Join-Path $parent (".$leaf.replace.tmp-$transactionId"))
    $backup = Assert-PathWithin -Root $root -Path (Join-Path $parent (".$leaf.replace.backup-$transactionId"))
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $prepared = $false
    try {
        $stream = New-Object System.IO.FileStream($writing, 'CreateNew', 'Write', 'None')
        try { $bytes = $utf8.GetBytes($json); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($writing, $temporary)
        $prepared = $true
        Publish-PreparedAtomicFile -TemporaryPath $temporary -TargetPath $target -BackupPath $backup
    } catch {
        if (-not $prepared) {
            foreach ($incomplete in @($writing,$temporary)) {
                if (Test-Path -LiteralPath $incomplete -PathType Leaf) { Remove-Item -LiteralPath $incomplete -Force -ErrorAction Stop }
            }
        }
        throw
    }
}

function Assert-TransactionLeafName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Context = 'transaction file')
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.','..') -or
        [IO.Path]::GetFileName($Name) -cne $Name -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$Context must be one safe leaf name."
    }
    return $Name
}

function Test-FileDescriptorMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Sha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-FileSystemItemOrFallback -Path $Path
    return [int64]$item.Length -eq $Bytes -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $Sha256
}

function Assert-ExactTransactionTargetSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected
    )
    if ($Actual.Count -ne $Expected.Count) { throw 'Prepared file-set transaction target set does not match its intended context.' }
    $actualSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $Actual) {
        $leaf = Assert-TransactionLeafName -Name $name -Context 'transaction target'
        if (-not $actualSet.Add($leaf)) { throw 'Prepared file-set transaction contains duplicate target names.' }
    }
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $Expected) {
        $leaf = Assert-TransactionLeafName -Name $name -Context 'expected transaction target'
        if (-not $expectedSet.Add($leaf)) { throw 'Expected transaction target set contains duplicate names.' }
    }
    if (-not $actualSet.SetEquals($expectedSet)) { throw 'Prepared file-set transaction target set does not match its intended context.' }
}

function Assert-PreparedFileSetTransactionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalName,
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][object[]]$States,
        [Parameter(Mandatory)][ValidateSet('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')][string]$ExpectedRole,
        [Parameter(Mandatory)][string[]]$ExpectedTargetNames
    )
    if ([int]$Journal.schema_version -ne 2 -or [string]$Journal.role -cne $ExpectedRole) {
        throw "Prepared file-set transaction is not bound to the expected '$ExpectedRole' context."
    }
    Assert-ExactTransactionTargetSet -Actual @($States | ForEach-Object { [string]$_.Item.target }) -Expected $ExpectedTargetNames
    $journalLeaf = Assert-TransactionLeafName -Name $JournalName -Context 'transaction journal'
    $transactionId = [string]$Journal.transaction_id
    $byTarget = @{}
    foreach ($state in $States) { $byTarget[[string]$state.Item.target] = $state }

    if ($ExpectedRole -ceq 'node-runtime') {
        Assert-ExactTransactionTargetSet -Actual $ExpectedTargetNames -Expected @('LICENSE','node.exe')
        if ($journalLeaf -cne '.node-runtime-transaction.json') { throw 'Node runtime transaction journal name is invalid for its context.' }
        $licensePrepared = [string]$byTarget['LICENSE'].Item.prepared
        $nodePrepared = [string]$byTarget['node.exe'].Item.prepared
        if ($licensePrepared -cnotmatch '^\.node-license-([0-9a-f]{32})\.prepared$') { throw 'Node runtime license prepared name is not token-bound.' }
        $preparedToken = $Matches[1]
        if ($nodePrepared -cnotmatch '^\.node-([0-9a-f]{32})\.prepared$' -or $Matches[1] -cne $preparedToken) {
            throw 'Node runtime executable prepared name is not bound to the same token.'
        }
        $licenseItem = $byTarget['LICENSE'].Item
        $nodeItem = $byTarget['node.exe'].Item
        if ([int64]$licenseItem.new_bytes -ne 159872 -or [string]$licenseItem.new_sha256 -cne $script:PinnedNodeLicenseSha256 -or
            [int64]$nodeItem.new_bytes -ne 92299080 -or [string]$nodeItem.new_sha256 -cne $script:PinnedNodeExecutableSha256) {
            throw 'Node runtime transaction candidate descriptors do not match the pinned runtime pair.'
        }
    } elseif ($ExpectedRole -ceq 'sevenzip-license') {
        Assert-ExactTransactionTargetSet -Actual $ExpectedTargetNames -Expected @('7ZIP-LICENSE.txt')
        if ($journalLeaf -cne '.7zip-license-transaction.json') { throw '7-Zip license transaction journal name is invalid for its context.' }
        $licensePrepared = [string]$byTarget['7ZIP-LICENSE.txt'].Item.prepared
        if ($licensePrepared -cnotmatch '^\.7zip-license-([0-9a-f]{32})\.prepared$') { throw '7-Zip license prepared name is not token-bound.' }
        $licenseItem = $byTarget['7ZIP-LICENSE.txt'].Item
        if ([int64]$licenseItem.new_bytes -ne 6031 -or [string]$licenseItem.new_sha256 -cne $script:PinnedSevenZipLicenseSha256) {
            throw '7-Zip license transaction candidate descriptor does not match the pinned official license.'
        }
    } elseif ($ExpectedRole -ceq 'sevenzip-runtime') {
        Assert-ExactTransactionTargetSet -Actual $ExpectedTargetNames -Expected @('7z.dll','7z.exe')
        if ($journalLeaf -cne '.7zip-runtime-transaction.json') { throw '7-Zip runtime transaction journal name is invalid for its context.' }
        $dllPrepared = [string]$byTarget['7z.dll'].Item.prepared
        $exePrepared = [string]$byTarget['7z.exe'].Item.prepared
        if ($dllPrepared -cnotmatch '^\.7z-dll-([0-9a-f]{32})\.prepared$') { throw '7-Zip library prepared name is not token-bound.' }
        $preparedToken = $Matches[1]
        if ($exePrepared -cnotmatch '^\.7z-exe-([0-9a-f]{32})\.prepared$' -or $Matches[1] -cne $preparedToken) {
            throw '7-Zip executable prepared name is not bound to the same token.'
        }
        $dllItem = $byTarget['7z.dll'].Item
        $exeItem = $byTarget['7z.exe'].Item
        if ([int64]$dllItem.new_bytes -ne 1906688 -or [string]$dllItem.new_sha256 -cne $script:PinnedSevenZipLibrarySha256 -or
            [int64]$exeItem.new_bytes -ne 576000 -or [string]$exeItem.new_sha256 -cne $script:PinnedSevenZipExecutableSha256) {
            throw '7-Zip runtime transaction candidate descriptors do not match the pinned runtime pair.'
        }
    } else {
        if ($ExpectedTargetNames.Count -ne 2) { throw 'Portable ZIP transaction must have exactly two intended targets.' }
        $zipTarget = @($ExpectedTargetNames | Where-Object { $_.EndsWith('.zip', [StringComparison]::Ordinal) })
        if ($zipTarget.Count -ne 1) { throw 'Portable ZIP transaction has an invalid ZIP target.' }
        $zipLeaf = [string]$zipTarget[0]
        $manifestLeaf = "$zipLeaf.manifest.json"
        Assert-ExactTransactionTargetSet -Actual $ExpectedTargetNames -Expected @($zipLeaf,$manifestLeaf)
        if ($journalLeaf -cne ".$zipLeaf.publication-transaction.json") { throw 'Portable ZIP transaction journal name is invalid for its release target.' }
        $zipPrepared = [string]$byTarget[$zipLeaf].Item.prepared
        $manifestPrepared = [string]$byTarget[$manifestLeaf].Item.prepared
        if ($zipPrepared -cnotmatch '^\.package-([0-9a-f]{32})\.prepared\.zip$') { throw 'Portable ZIP prepared name is not token-bound.' }
        $preparedToken = $Matches[1]
        if ($manifestPrepared -cnotmatch '^\.package-([0-9a-f]{32})\.prepared\.manifest\.json$' -or $Matches[1] -cne $preparedToken) {
            throw 'Portable ZIP sidecar prepared name is not bound to the same token.'
        }
    }

    foreach ($state in $States) {
        $expectedBackup = ".$([string]$state.Item.target).backup-$transactionId"
        if ([string]$state.Item.backup -cne $expectedBackup) { throw 'Prepared file-set transaction backup name is not bound to its target and transaction.' }
    }
}

function Test-TransactionJsonInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64]
}

function Get-TransactionJsonValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Object -is [Collections.IDictionary]) {
        $containsKey = if ($null -ne $Object.PSObject.Methods['ContainsKey']) {
            $Object.ContainsKey($Name)
        } else {
            $Object.Contains($Name)
        }
        if (-not $containsKey) { return $null }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-TransactionJsonArrayProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Object -is [Collections.IDictionary]) {
        $containsKey = if ($null -ne $Object.PSObject.Methods['ContainsKey']) {
            $Object.ContainsKey($Name)
        } else {
            $Object.Contains($Name)
        }
        if (-not $containsKey) { return $false }
        return $Object[$Name] -is [Collections.IList]
    }
    $property = $Object.PSObject.Properties[$Name]
    return $null -ne $property -and $property.Value -is [Collections.IList]
}

function Get-TransactionJsonNumericView {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Parsed,
        [string]$Context = 'prepared file-set transaction journal'
    )
    if ($PSVersionTable.PSVersion.Major -gt 5) { return $Parsed }

    # Windows PowerShell 5.1's ConvertFrom-Json turns a token such as 5.0 into
    # Int64 5. JavaScriptSerializer preserves it as Decimal, allowing the
    # recovery format to enforce integer JSON representations on both hosts.
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 1048576
    try {
        $value = $serializer.DeserializeObject([IO.File]::ReadAllText($Path))
    } catch {
        throw "$Context numeric validation failed: $($_.Exception.Message)"
    }
    if (-not ($value -is [Collections.IDictionary])) {
        throw "$Context must be a JSON object."
    }
    return $value
}

function Add-PortableArchivePathNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string,object]]$Nodes,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('File','Directory')][string]$Kind,
        [Parameter(Mandatory)][string]$Context
    )

    $normalized = $Path.Replace('\','/')
    if ($Kind -ceq 'Directory') { $normalized = $normalized.TrimEnd([char[]]'/') }
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.StartsWith('/') -or $normalized.EndsWith('/')) {
        throw "$Context contains an invalid archive path node: $Path"
    }
    $segments = @($normalized -split '/')
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
        throw "$Context contains an invalid archive path node: $Path"
    }
    foreach ($segment in $segments) {
        if ($segment.Length -gt 255) {
            throw "$Context contains a Windows path component longer than 255 characters: $Path"
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)') {
            throw "$Context contains an invalid Windows archive path node: $Path"
        }
    }

    $nodePath = ''
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $nodePath = if ($index -eq 0) { [string]$segments[$index] } else { "$nodePath/$($segments[$index])" }
        $nodeKind = if ($index -eq $segments.Count - 1) { $Kind } else { 'Directory' }
        if ($Nodes.ContainsKey($nodePath)) {
            $existing = $Nodes[$nodePath]
            if ([string]$existing.Path -cne $nodePath) {
                throw "$Context contains a case-colliding path node: '$([string]$existing.Path)' and '$nodePath'."
            }
            if ([string]$existing.Kind -cne $nodeKind) {
                throw "$Context contains a file/directory path node conflict: $nodePath"
            }
            if ($index -eq $segments.Count - 1 -and $nodeKind -ceq 'File') {
                throw "$Context contains a duplicate file path node: $nodePath"
            }
            continue
        }
        $Nodes.Add($nodePath,[pscustomobject]@{Path=$nodePath;Kind=$nodeKind})
    }
}

function Assert-PortableZipInternalChecksumClosure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath)

    $zipFull = Resolve-FullPath -Path $ZipPath -MustExist -PathType Leaf
    $zipItem = Get-FileSystemItemOrFallback -Path $zipFull
    if (($zipItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Portable ZIP must not be a reparse point.' }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::OpenRead($zipFull)
    try {
        if ($archive.Entries.Count -eq 0) { throw 'Portable ZIP contains no entries.' }
        $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        $pathNodes = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        $explicitDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $rootName = $null
        $totalUncompressed = [int64]0
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName.Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.StartsWith('/') -or $entryName.Contains([char]0) -or
                $entryName -match '(^|/)\.\.?(/|$)' -or $entryName -match '//') {
                throw "Portable ZIP contains an unsafe entry name: $entryName"
            }
            $segments = @($entryName.TrimEnd('/') -split '/')
            if ($segments.Count -lt 1 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '[<>:"|?*\x00-\x1f]' }).Count -gt 0) {
                throw "Portable ZIP contains an invalid Windows entry path: $entryName"
            }
            if ($null -eq $rootName) { $rootName = [string]$segments[0] }
            if ([string]$segments[0] -cne $rootName) { throw 'Portable ZIP contains more than one top-level package root.' }
            $externalAttributes = [int64]$entry.ExternalAttributes
            $dosDirectory = (($externalAttributes -band [int64][IO.FileAttributes]::Directory) -ne 0)
            $dosDevice = (($externalAttributes -band [int64][IO.FileAttributes]::Device) -ne 0)
            $dosReparsePoint = (($externalAttributes -band [int64][IO.FileAttributes]::ReparsePoint) -ne 0)
            $unixType = (($externalAttributes -shr 16) -band 0xF000)
            if ($dosDevice -or $dosReparsePoint -or $unixType -eq 0xA000 -or
                ($unixType -ne 0 -and $unixType -ne 0x4000 -and $unixType -ne 0x8000)) {
                throw "Portable ZIP entry uses unsupported link or device attributes: $entryName"
            }
            $nameIsDirectory = $entryName.EndsWith('/') -or [string]::IsNullOrEmpty($entry.Name)
            $attributeIsDirectory = $dosDirectory -or $unixType -eq 0x4000
            if ($attributeIsDirectory -and -not $nameIsDirectory) {
                throw "Portable ZIP entry has a directory attribute without a canonical directory name: $entryName"
            }
            if ($nameIsDirectory -and $unixType -eq 0x8000) {
                throw "Portable ZIP directory entry has conflicting regular-file attributes: $entryName"
            }
            $isDirectory = $nameIsDirectory
            Add-PortableArchivePathNode -Nodes $pathNodes -Path $entryName -Kind $(if ($isDirectory) { 'Directory' } else { 'File' }) -Context 'Portable ZIP'
            if ($isDirectory) {
                if ([int64]$entry.Length -ne 0) { throw "Portable ZIP directory entry contains data: $entryName" }
                if (-not $explicitDirectories.Add($entryName.TrimEnd('/'))) {
                    throw "Portable ZIP contains a duplicate explicit directory entry: $entryName"
                }
                continue
            }
            if ($segments.Count -lt 2) { throw 'Portable ZIP contains a file outside its top-level package directory.' }
            if ([int64]$entry.Length -lt 0 -or [int64]$entry.Length -gt 536870912) { throw "Portable ZIP entry has an unsafe uncompressed size: $entryName" }
            $totalUncompressed += [int64]$entry.Length
            if ($totalUncompressed -gt 1073741824) { throw 'Portable ZIP exceeds the 1 GiB uncompressed package limit.' }
            if ($entries.ContainsKey($entryName)) {
                $existing = $entries[$entryName]
                $kind = if ([string]$existing.FullName -ceq $entryName) { 'duplicate' } else { 'case-colliding' }
                throw "Portable ZIP contains a $kind file entry: $entryName"
            }
            $entries.Add($entryName,$entry)
        }
        if ([string]::IsNullOrWhiteSpace($rootName)) { throw 'Portable ZIP has no package root.' }
        $checksumEntryName = "$rootName/checksums.sha256"
        if (-not $entries.ContainsKey($checksumEntryName) -or [string]$entries[$checksumEntryName].FullName.Replace('\','/') -cne $checksumEntryName) {
            throw 'Portable ZIP is missing its root checksums.sha256 file or changed its path casing.'
        }
        $checksumEntry = $entries[$checksumEntryName]
        if ([int64]$checksumEntry.Length -le 0 -or [int64]$checksumEntry.Length -gt 67108864) { throw 'Portable ZIP checksums.sha256 has an invalid size.' }
        $checksumStream = $checksumEntry.Open()
        try {
            $checksumBytes = New-Object byte[] ([int]$checksumEntry.Length)
            $offset = 0
            while ($offset -lt $checksumBytes.Length) {
                $read = $checksumStream.Read($checksumBytes,$offset,$checksumBytes.Length-$offset)
                if ($read -le 0) { throw 'Portable ZIP checksums.sha256 ended unexpectedly.' }
                $offset += $read
            }
        } finally { $checksumStream.Dispose() }
        $utf8 = New-Object Text.UTF8Encoding($false,$true)
        try { $checksumText = $utf8.GetString($checksumBytes) } catch { throw 'Portable ZIP checksums.sha256 is not valid UTF-8.' }
        $lines = @($checksumText -split "`r?`n")
        if ($lines.Count -gt 0 -and $lines[$lines.Count-1] -ceq '') { $lines = @($lines[0..($lines.Count-2)]) }
        if ($lines.Count -eq 0 -or @($lines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Portable ZIP checksums.sha256 is empty or contains blank lines.'
        }
        $checksummed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $lines) {
            if ([string]$line -cnotmatch '^([0-9a-f]{64}) \*([^\r\n]+)$') { throw 'Portable ZIP checksums.sha256 contains a malformed line.' }
            $expectedHash = [string]$Matches[1]
            $relative = [string]$Matches[2].Replace('\','/')
            if ($relative -ceq 'checksums.sha256' -or $relative.StartsWith('/') -or $relative -match '(^|/)\.\.?(/|$)' -or $relative -match '//') {
                throw "Portable ZIP checksums.sha256 contains an unsafe path: $relative"
            }
            $entryName = "$rootName/$relative"
            if (-not $checksummed.Add($entryName)) { throw "Portable ZIP checksums.sha256 contains a duplicate or case-colliding path: $relative" }
            if (-not $entries.ContainsKey($entryName) -or [string]$entries[$entryName].FullName.Replace('\','/') -cne $entryName) {
                throw "Portable ZIP checksums.sha256 references a missing or case-changed file: $relative"
            }
            $stream = $entries[$entryName].Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actualHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($actualHash -cne $expectedHash) { throw "Portable ZIP internal checksum mismatch: $relative" }
        }
        $allowedUnlisted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($relative in @('checksums.sha256','maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json')) {
            [void]$allowedUnlisted.Add("$rootName/$relative")
        }
        $unlisted = @($entries.Keys | Where-Object { -not $checksummed.Contains($_) -and -not $allowedUnlisted.Contains($_) } | Sort-Object)
        if ($unlisted.Count -gt 0) { throw "Portable ZIP contains file(s) outside its internal checksum closure: $($unlisted -join ', ')" }
        return $true
    } finally { $archive.Dispose() }
}

function Assert-PortableZipSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$ExpectedFile
    )
    $zipFull = Resolve-FullPath -Path $ZipPath -MustExist -PathType Leaf
    $manifestFull = Resolve-FullPath -Path $ManifestPath -MustExist -PathType Leaf
    $manifest = Read-JsonFile -Path $manifestFull -Context 'portable ZIP sidecar manifest' -RequireObject
    Assert-ExactJsonProperties -Object $manifest -Names @('schema_version','file','bytes','sha256') -Context 'portable ZIP sidecar manifest'
    $numericManifest = Get-TransactionJsonNumericView -Path $manifestFull -Parsed $manifest -Context 'portable ZIP sidecar manifest'
    $numericSchemaVersion = Get-TransactionJsonValue -Object $numericManifest -Name 'schema_version'
    $numericBytes = Get-TransactionJsonValue -Object $numericManifest -Name 'bytes'
    $zipItem = Get-FileSystemItemOrFallback -Path $zipFull
    if ([string]::IsNullOrWhiteSpace($ExpectedFile)) { $ExpectedFile = [IO.Path]::GetFileName($zipFull) }
    if (-not (Test-TransactionJsonInteger $numericSchemaVersion) -or [int64]$numericSchemaVersion -ne 1 -or
        -not ($manifest.file -is [string]) -or [string]$manifest.file -cne $ExpectedFile -or
        -not (Test-TransactionJsonInteger $numericBytes) -or [int64]$numericBytes -lt 0 -or
        [int64]$numericBytes -ne [int64]$zipItem.Length -or
        -not ($manifest.sha256 -is [string]) -or [string]$manifest.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Portable ZIP sidecar manifest is structurally invalid or does not describe its ZIP.'
    }
    $actualHash = (Get-FileHash -LiteralPath $zipFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne [string]$manifest.sha256) { throw 'Portable ZIP sidecar SHA-256 does not match its ZIP.' }
    Assert-PortableZipInternalChecksumClosure -ZipPath $zipFull | Out-Null
    return [pscustomobject]@{ZipPath=$zipFull;ManifestPath=$manifestFull;Bytes=[int64]$zipItem.Length;Sha256=$actualHash}
}

function Assert-PortableTransactionPairSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$States,
        [Parameter(Mandatory)][ValidateSet('candidate','prior')][string]$SetKind
    )
    $zipStates = @($States | Where-Object { ([string]$_.Item.target).EndsWith('.zip', [StringComparison]::Ordinal) })
    if ($zipStates.Count -ne 1) { throw 'Portable transaction does not have exactly one ZIP target.' }
    $zipState = $zipStates[0]
    $zipLeaf = [string]$zipState.Item.target
    $manifestStates = @($States | Where-Object { [string]$_.Item.target -ceq "$zipLeaf.manifest.json" })
    if ($manifestStates.Count -ne 1) { throw 'Portable transaction does not have the matching ZIP sidecar target.' }
    $manifestState = $manifestStates[0]

    if ($SetKind -ceq 'candidate') {
        $zipPresent = $null -ne $zipState.CandidateSource
        $manifestPresent = $null -ne $manifestState.CandidateSource
        $zipPath = $zipState.CandidateSource
        $manifestPath = $manifestState.CandidateSource
        $zipBytes = [int64]$zipState.Item.new_bytes
        $zipSha256 = [string]$zipState.Item.new_sha256
        $manifestBytes = [int64]$manifestState.Item.new_bytes
        $manifestSha256 = [string]$manifestState.Item.new_sha256
    } else {
        $zipPresent = [bool]$zipState.Item.old_present
        $manifestPresent = [bool]$manifestState.Item.old_present
        if (-not $zipPresent -and $manifestPresent) { throw 'Portable transaction prior set contains a sidecar without its ZIP.' }
        if (-not $zipPresent -or -not $manifestPresent) { return }
        $zipPath = $zipState.PriorSource
        $manifestPath = $manifestState.PriorSource
        $zipBytes = [int64]$zipState.Item.old_bytes
        $zipSha256 = [string]$zipState.Item.old_sha256
        $manifestBytes = [int64]$manifestState.Item.old_bytes
        $manifestSha256 = [string]$manifestState.Item.old_sha256
    }
    if (-not $zipPresent -or -not $manifestPresent -or $null -eq $zipPath -or $null -eq $manifestPath) {
        throw "Portable transaction $SetKind set is incomplete."
    }
    if (-not (Test-FileDescriptorMatch -Path $zipPath -Bytes $zipBytes -Sha256 $zipSha256) -or
        -not (Test-FileDescriptorMatch -Path $manifestPath -Bytes $manifestBytes -Sha256 $manifestSha256)) {
        throw "Portable transaction $SetKind pair does not match its journal descriptors."
    }
    Assert-PortableZipInternalChecksumClosure -ZipPath $zipPath | Out-Null
    $sidecar = Read-JsonFile -Path $manifestPath -Context "portable transaction $SetKind sidecar" -RequireObject
    Assert-ExactJsonProperties -Object $sidecar -Names @('schema_version','file','bytes','sha256') -Context "portable transaction $SetKind sidecar"
    $numericSidecar = Get-TransactionJsonNumericView -Path $manifestPath -Parsed $sidecar -Context "portable transaction $SetKind sidecar"
    $numericSchemaVersion = Get-TransactionJsonValue -Object $numericSidecar -Name 'schema_version'
    $numericBytes = Get-TransactionJsonValue -Object $numericSidecar -Name 'bytes'
    if (-not (Test-TransactionJsonInteger $numericSchemaVersion) -or [int64]$numericSchemaVersion -ne 1 -or
        -not ($sidecar.file -is [string]) -or [string]$sidecar.file -cne $zipLeaf -or
        -not (Test-TransactionJsonInteger $numericBytes) -or [int64]$numericBytes -ne $zipBytes -or
        -not ($sidecar.sha256 -is [string]) -or [string]$sidecar.sha256 -cne $zipSha256) {
        throw "Portable transaction $SetKind sidecar does not strictly describe its ZIP target and descriptor."
    }
}

function Get-PreparedFileSetTransactionDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$JournalName,
        [Parameter(Mandatory)][string]$JournalPath,
        [ValidateSet('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')][string]$ExpectedRole,
        [string[]]$ExpectedTargetNames
    )
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    $journalLeaf = Assert-TransactionLeafName -Name $JournalName -Context 'transaction journal'
    $sourcePath = Assert-PathWithin -Root $rootFull -Path $JournalPath
    Assert-NoReparsePoint -Root $rootFull -Path $sourcePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'Prepared file-set transaction journal is not a regular file.' }
    $journal = Read-JsonFile -Path $sourcePath -Context 'prepared file-set transaction journal' -RequireObject
    # Validate the original values before string casts or pipeline-returning
    # numeric helpers can enumerate a singleton JSON array into a scalar.
    Get-RevisionJsonField $journal 'schema_version' Integer 'prepared file-set transaction journal' -Minimum 1 | Out-Null
    foreach ($name in @('operation','transaction_id')) { Get-RevisionJsonField $journal $name String 'prepared file-set transaction journal' | Out-Null }
    Get-RevisionJsonField $journal 'items' Array 'prepared file-set transaction journal' | Out-Null
    $numericJournal = Get-TransactionJsonNumericView -Path $sourcePath -Parsed $journal
    $numericSchemaVersion = Get-TransactionJsonValue -Object $numericJournal -Name 'schema_version'
    if (-not (Test-TransactionJsonInteger $numericSchemaVersion)) {
        throw 'Prepared file-set transaction journal schema is invalid.'
    }
    $schemaVersion = [int]$journal.schema_version
    if ($schemaVersion -eq 1) {
        Assert-ExactJsonProperties -Object $journal -Names @('schema_version','operation','transaction_id','items') -Context 'prepared file-set transaction journal'
    } elseif ($schemaVersion -eq 2) {
        Assert-ExactJsonProperties -Object $journal -Names @('schema_version','operation','transaction_id','role','items') -Context 'prepared file-set transaction journal'
        Get-RevisionJsonField $journal 'role' String 'prepared file-set transaction journal' | Out-Null
        if ([string]$journal.role -cnotin @('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')) { throw 'Prepared file-set transaction journal role is invalid.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedRole)) { throw 'Role-bound transaction recovery requires its explicit expected context.' }
    } else {
        throw 'Prepared file-set transaction journal schema is invalid.'
    }
    if ([string]$journal.operation -cne 'publish-prepared-file-set' -or [string]$journal.transaction_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Prepared file-set transaction journal header is invalid.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRole) -and ($null -eq $ExpectedTargetNames -or $ExpectedTargetNames.Count -eq 0)) {
        throw 'Context-bound transaction recovery requires its exact intended target set.'
    }
    if (-not (Test-TransactionJsonArrayProperty -Object $numericJournal -Name 'items')) {
        throw 'Prepared file-set transaction items must be a JSON array.'
    }
    $items = @($journal.items)
    $numericItems = @(Get-TransactionJsonValue -Object $numericJournal -Name 'items')
    if ($numericItems.Count -ne $items.Count) { throw 'Prepared file-set transaction item count is invalid.' }
    if ($items.Count -lt 1 -or $items.Count -gt 16) { throw 'Prepared file-set transaction item count is invalid.' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$seen.Add($journalLeaf)
    $states = @()
    $itemIndex = -1
    foreach ($item in $items) {
        $itemIndex++
        $numericItem = $numericItems[$itemIndex]
        $numericNewBytes = Get-TransactionJsonValue -Object $numericItem -Name 'new_bytes'
        $numericOldBytes = Get-TransactionJsonValue -Object $numericItem -Name 'old_bytes'
        Assert-ExactJsonProperties -Object $item -Names @('target','prepared','backup','old_present','old_bytes','old_sha256','new_bytes','new_sha256') -Context 'prepared file-set transaction item'
        foreach ($name in @('target','prepared','backup','new_sha256')) { Get-RevisionJsonField $item $name String 'prepared file-set transaction item' | Out-Null }
        Get-RevisionJsonField $item 'old_present' Boolean 'prepared file-set transaction item' | Out-Null
        Get-RevisionJsonField $item 'new_bytes' Integer 'prepared file-set transaction item' | Out-Null
        Get-RevisionJsonField $item 'old_sha256' NullableString 'prepared file-set transaction item' | Out-Null
        $targetLeaf = Assert-TransactionLeafName -Name ([string]$item.target) -Context 'transaction target'
        $preparedLeaf = Assert-TransactionLeafName -Name ([string]$item.prepared) -Context 'transaction prepared file'
        $backupLeaf = Assert-TransactionLeafName -Name ([string]$item.backup) -Context 'transaction backup file'
        foreach ($leaf in @($targetLeaf,$preparedLeaf,$backupLeaf)) { if (-not $seen.Add($leaf)) { throw 'Prepared file-set transaction contains duplicate paths.' } }
        if (-not ($item.old_present -is [bool]) -or
            -not (Test-TransactionJsonInteger $numericNewBytes) -or [int64]$item.new_bytes -lt 0 -or
            [string]$item.new_sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Prepared file-set transaction item descriptor is invalid.'
        }
        if ([bool]$item.old_present) {
            Get-RevisionJsonField $item 'old_bytes' Integer 'prepared file-set transaction item' | Out-Null
            if (-not (Test-TransactionJsonInteger $numericOldBytes) -or [int64]$item.old_bytes -lt 0 -or
                [string]$item.old_sha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Prepared file-set transaction prior descriptor is invalid.'
            }
        } elseif ($null -ne $item.old_bytes -or $null -ne $item.old_sha256) {
            throw 'Prepared file-set transaction absent prior descriptor is invalid.'
        }
        $states += [pscustomobject]@{
            Item=$item
            Target=(Join-Path $rootFull $targetLeaf)
            Prepared=(Join-Path $rootFull $preparedLeaf)
            Backup=(Join-Path $rootFull $backupLeaf)
            CandidateSource=$null
            PriorSource=$null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRole)) {
        Assert-PreparedFileSetTransactionContext -JournalName $journalLeaf -Journal $journal -States $states -ExpectedRole $ExpectedRole -ExpectedTargetNames $ExpectedTargetNames
    }
    foreach ($state in $states) {
        foreach ($path in @($state.Target,$state.Prepared,$state.Backup)) {
            if (Test-Path -LiteralPath $path) {
                Assert-NoReparsePoint -Root $rootFull -Path $path
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Transaction path is not a regular file: $path" }
            }
        }
    }
    return [pscustomobject]@{Journal=$journal;States=$states;Root=$rootFull;JournalLeaf=$journalLeaf}
}

function Repair-PreparedFileSetTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$JournalName,
        [ValidateSet('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')][string]$ExpectedRole,
        [string[]]$ExpectedTargetNames
    )
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    $journalLeaf = Assert-TransactionLeafName -Name $JournalName -Context 'transaction journal'
    $journalPath = Assert-PathWithin -Root $rootFull -Path (Join-Path $rootFull $journalLeaf)
    if ((Test-Path -LiteralPath $journalPath) -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw 'Prepared file-set transaction journal is not a regular file.'
    }
    $escapedJournalLeaf = [Regex]::Escape($journalLeaf)
    $writingJournals = @(Get-ChildItem -LiteralPath $rootFull -Force | Where-Object {
        $_.Name -cmatch ("^" + $escapedJournalLeaf + "\.writing-([0-9a-f]{32})$")
    })
    $preparedJournals = @(Get-ChildItem -LiteralPath $rootFull -Force | Where-Object {
        $_.Name -cmatch ("^" + $escapedJournalLeaf + "\.prepared-([0-9a-f]{32})$") -or
        $_.Name -cmatch ("^\." + $escapedJournalLeaf + "\.replace\.tmp-([0-9a-f]{32})$")
    })
    if ($writingJournals.Count -gt 0) {
        if ($writingJournals.Count -ne 1 -or $preparedJournals.Count -gt 0 -or (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw 'A partial journal write coexists with other file-set transaction state; all evidence was preserved.'
        }
        $writingJournal = $writingJournals[0]
        if (-not (Test-Path -LiteralPath $writingJournal.FullName -PathType Leaf)) { throw 'Partial file-set transaction journal is not a regular file.' }
        Assert-NoReparsePoint -Root $rootFull -Path $writingJournal.FullName
        [void]($writingJournal.Name -cmatch ("^" + $escapedJournalLeaf + "\.writing-([0-9a-f]{32})$"))
        $writingToken = $Matches[1]
        $writingBackups = @(Get-ChildItem -LiteralPath $rootFull -Force | Where-Object { $_.Name.EndsWith(".backup-$writingToken",[StringComparison]::OrdinalIgnoreCase) })
        if ($writingBackups.Count -gt 0) { throw 'A partial journal write has target-backup debris; state is ambiguous and was preserved.' }
        Remove-Item -LiteralPath $writingJournal.FullName -Force
    }
    if ((Test-Path -LiteralPath $journalPath -PathType Leaf) -and $preparedJournals.Count -gt 0) {
        throw 'Canonical and prepared file-set transaction journals coexist; state is ambiguous and was preserved.'
    }
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf) -and $preparedJournals.Count -gt 0) {
        if ($preparedJournals.Count -ne 1) { throw 'Multiple prepared file-set transaction journals exist; state is ambiguous and was preserved.' }
        $preparedJournal = $preparedJournals[0]
        if (-not (Test-Path -LiteralPath $preparedJournal.FullName -PathType Leaf)) { throw 'Prepared file-set transaction journal is not a regular file.' }
        $definitionContext = @{}
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRole)) { $definitionContext=@{ExpectedRole=$ExpectedRole;ExpectedTargetNames=$ExpectedTargetNames} }
        $preparedDefinition = Get-PreparedFileSetTransactionDefinition -Root $rootFull -JournalName $journalLeaf -JournalPath $preparedJournal.FullName @definitionContext
        if ($preparedJournal.Name -cmatch ("^" + $escapedJournalLeaf + "\.prepared-([0-9a-f]{32})$") -and
            [string]$preparedDefinition.Journal.transaction_id -cne $Matches[1]) {
            throw 'Prepared file-set transaction journal name is not bound to its transaction id.'
        }
        [IO.File]::Move($preparedJournal.FullName, $journalPath)
    }
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return [pscustomobject]@{State='none'} }
    $definitionContext = @{}
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRole)) { $definitionContext=@{ExpectedRole=$ExpectedRole;ExpectedTargetNames=$ExpectedTargetNames} }
    $definition = Get-PreparedFileSetTransactionDefinition -Root $rootFull -JournalName $journalLeaf -JournalPath $journalPath @definitionContext
    $journal = $definition.Journal
    $states = @($definition.States)

    $candidateComplete = $true
    foreach ($state in $states) {
        $item = $state.Item
        if (Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256)) {
            $state.CandidateSource = $state.Target
        } elseif (Test-FileDescriptorMatch -Path $state.Prepared -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256)) {
            $state.CandidateSource = $state.Prepared
        } else {
            $candidateComplete = $false
        }
    }
    if ($candidateComplete) {
        if ([string]$ExpectedRole -ceq 'portable-zip') {
            Assert-PortableTransactionPairSemantics -States $states -SetKind candidate
        }
        # Validate every path before moving any file. Recovery must not partially
        # mutate one item and only then discover ambiguous debris in another.
        foreach ($state in $states) {
            $item = $state.Item
            if (Test-Path -LiteralPath $state.Target -PathType Leaf) {
                $targetIsCandidate = Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256)
                $targetIsPrior = [bool]$item.old_present -and
                    (Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256))
                if (-not $targetIsCandidate -and -not $targetIsPrior) { throw "Transaction target contains unknown bytes: $($state.Target)" }
                if ($state.CandidateSource -ceq $state.Prepared -and -not $targetIsPrior) {
                    throw "Prepared candidate cannot replace the current transaction target: $($state.Target)"
                }
            }
            if (Test-Path -LiteralPath $state.Prepared -PathType Leaf) {
                if (-not (Test-FileDescriptorMatch -Path $state.Prepared -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256))) {
                    throw "Prepared transaction debris contains unknown bytes: $($state.Prepared)"
                }
            }
            if (Test-Path -LiteralPath $state.Backup -PathType Leaf) {
                if (-not [bool]$item.old_present -or
                    -not (Test-FileDescriptorMatch -Path $state.Backup -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256))) {
                    throw "Backup transaction debris contains unknown bytes: $($state.Backup)"
                }
                if ($state.CandidateSource -ceq $state.Prepared -and (Test-Path -LiteralPath $state.Target -PathType Leaf)) {
                    throw "Transaction contains both a prior target and a prior backup: $($state.Target)"
                }
            }
        }
        foreach ($state in $states) {
            $item = $state.Item
            if ($state.CandidateSource -ceq $state.Prepared) {
                if (Test-Path -LiteralPath $state.Target -PathType Leaf) { [IO.File]::Move($state.Target, $state.Backup) }
                [IO.File]::Move($state.Prepared, $state.Target)
            }
        }
        foreach ($state in $states) {
            $item=$state.Item
            if (-not (Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256))) {
                throw "Published file set failed candidate validation: $($state.Target)"
            }
        }
        foreach ($state in $states) {
            if (Test-Path -LiteralPath $state.Prepared -PathType Leaf) {
                if (-not (Test-FileDescriptorMatch -Path $state.Prepared -Bytes ([int64]$state.Item.new_bytes) -Sha256 ([string]$state.Item.new_sha256))) { throw "Prepared transaction debris contains unknown bytes: $($state.Prepared)" }
                Remove-Item -LiteralPath $state.Prepared -Force
            }
            if (Test-Path -LiteralPath $state.Backup -PathType Leaf) {
                if (-not [bool]$state.Item.old_present -or
                    -not (Test-FileDescriptorMatch -Path $state.Backup -Bytes ([int64]$state.Item.old_bytes) -Sha256 ([string]$state.Item.old_sha256))) { throw "Backup transaction debris contains unknown bytes: $($state.Backup)" }
                Remove-Item -LiteralPath $state.Backup -Force
            }
        }
        Remove-Item -LiteralPath $journalPath -Force
        return [pscustomobject]@{State='committed'}
    }

    $oldComplete = $true
    foreach ($state in $states) {
        $item=$state.Item
        if (-not [bool]$item.old_present) { continue }
        $backupIsPrior = Test-FileDescriptorMatch -Path $state.Backup -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256)
        $targetIsPrior = Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256)
        if ($backupIsPrior -and $targetIsPrior) { throw "Transaction contains duplicate prior files: $($state.Target)" }
        if ($backupIsPrior) { $state.PriorSource = $state.Backup }
        elseif ($targetIsPrior) { $state.PriorSource = $state.Target }
        else { $oldComplete=$false }
    }
    if (-not $oldComplete) { throw 'Prepared file-set transaction contains neither a complete candidate nor a complete prior set; all artifacts were preserved.' }
    if ([string]$ExpectedRole -ceq 'portable-zip') {
        Assert-PortableTransactionPairSemantics -States $states -SetKind prior
    }

    # Preflight the complete rollback before changing any canonical path.
    foreach ($state in $states) {
        $item = $state.Item
        if (Test-Path -LiteralPath $state.Prepared -PathType Leaf) {
            if (-not (Test-FileDescriptorMatch -Path $state.Prepared -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256))) {
                throw "Prepared transaction debris contains unknown bytes: $($state.Prepared)"
            }
        }
        if (Test-Path -LiteralPath $state.Target -PathType Leaf) {
            $targetIsCandidate = Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256)
            $targetIsPrior = [bool]$item.old_present -and
                (Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256))
            if (-not $targetIsCandidate -and -not $targetIsPrior) { throw "Transaction target contains unknown bytes: $($state.Target)" }
        }
        if (Test-Path -LiteralPath $state.Backup -PathType Leaf) {
            if (-not [bool]$item.old_present -or
                -not (Test-FileDescriptorMatch -Path $state.Backup -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256))) {
                throw "Backup transaction debris contains unknown bytes: $($state.Backup)"
            }
        }
    }
    foreach ($state in $states) {
        $item = $state.Item
        if ((Test-Path -LiteralPath $state.Target -PathType Leaf) -and $state.PriorSource -cne $state.Target) {
            Remove-Item -LiteralPath $state.Target -Force
        }
        if ([bool]$item.old_present -and $state.PriorSource -ceq $state.Backup) { [IO.File]::Move($state.Backup, $state.Target) }
    }
    foreach ($state in $states) {
        $item=$state.Item
        if ([bool]$item.old_present) {
            if (-not (Test-FileDescriptorMatch -Path $state.Target -Bytes ([int64]$item.old_bytes) -Sha256 ([string]$item.old_sha256))) { throw "Restored file set failed prior-state validation: $($state.Target)" }
        } elseif (Test-Path -LiteralPath $state.Target) { throw "Restored file set retained a target that was previously absent: $($state.Target)" }
        if (Test-Path -LiteralPath $state.Prepared -PathType Leaf) {
            if (-not (Test-FileDescriptorMatch -Path $state.Prepared -Bytes ([int64]$item.new_bytes) -Sha256 ([string]$item.new_sha256))) { throw "Prepared transaction debris contains unknown bytes: $($state.Prepared)" }
            Remove-Item -LiteralPath $state.Prepared -Force
        }
        if (Test-Path -LiteralPath $state.Backup -PathType Leaf) { throw "Restored file set retained an unexpected backup: $($state.Backup)" }
    }
    Remove-Item -LiteralPath $journalPath -Force
    return [pscustomobject]@{State='rolled-back'}
}

function Publish-PreparedFileSetTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$JournalName,
        [Parameter(Mandatory)][object[]]$Items,
        [ValidateSet('node-runtime','sevenzip-license','sevenzip-runtime','portable-zip')][string]$TransactionRole,
        [string[]]$ExpectedTargetNames,
        [scriptblock]$InternalCheckpoint
    )
    $rootFull = Resolve-FullPath -Path $Root -MustExist -PathType Container
    $journalLeaf = Assert-TransactionLeafName -Name $JournalName -Context 'transaction journal'
    $journalPath = Join-Path $rootFull $journalLeaf
    if ($Items.Count -lt 1 -or $Items.Count -gt 16) { throw 'Prepared file-set publication item count is invalid.' }
    if (-not [string]::IsNullOrWhiteSpace($TransactionRole)) {
        if ($null -eq $ExpectedTargetNames -or $ExpectedTargetNames.Count -eq 0) { throw 'Context-bound publication requires its exact intended target set.' }
        $requestedTargets = @($Items | ForEach-Object { Assert-TransactionLeafName -Name ([IO.Path]::GetFileName([string]$_.TargetPath)) -Context 'transaction target' })
        Assert-ExactTransactionTargetSet -Actual $requestedTargets -Expected $ExpectedTargetNames
    }
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        $repairParameters = @{}
        if (-not [string]::IsNullOrWhiteSpace($TransactionRole)) {
            $repairParameters.ExpectedRole = $TransactionRole
            $repairParameters.ExpectedTargetNames = $ExpectedTargetNames
        }
        Repair-PreparedFileSetTransaction -Root $rootFull -JournalName $journalLeaf @repairParameters | Out-Null
    }
    $transactionId = [Guid]::NewGuid().ToString('N')
    $journalItems = @(); $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        $prepared = Resolve-FullPath -Path ([string]$item.PreparedPath) -MustExist -PathType Leaf
        $target = Resolve-FullPath -Path ([string]$item.TargetPath)
        if ((Split-Path -Parent $prepared) -cne $rootFull -or (Split-Path -Parent $target) -cne $rootFull) { throw 'Prepared and target files must be direct children of the transaction root.' }
        $preparedLeaf=Assert-TransactionLeafName ([IO.Path]::GetFileName($prepared)); $targetLeaf=Assert-TransactionLeafName ([IO.Path]::GetFileName($target))
        if (-not $seen.Add($preparedLeaf) -or -not $seen.Add($targetLeaf)) { throw 'Prepared file-set publication contains duplicate paths.' }
        $backupLeaf = ".$targetLeaf.backup-$transactionId"
        if (-not $seen.Add($backupLeaf)) { throw 'Prepared file-set publication backup path collided.' }
        $newItem=Get-FileSystemItemOrFallback -Path $prepared
        $oldPresent=Test-Path -LiteralPath $target -PathType Leaf
        if ((Test-Path -LiteralPath $target) -and -not $oldPresent) { throw "Transaction target is not a regular file: $target" }
        $oldItem=if($oldPresent){Get-FileSystemItemOrFallback -Path $target}else{$null}
        $journalItems += [ordered]@{
            target=$targetLeaf;prepared=$preparedLeaf;backup=$backupLeaf;old_present=[bool]$oldPresent
            old_bytes=if($oldPresent){[int64]$oldItem.Length}else{$null}
            old_sha256=if($oldPresent){(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
            new_bytes=[int64]$newItem.Length;new_sha256=(Get-FileHash -LiteralPath $prepared -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    if ([string]::IsNullOrWhiteSpace($TransactionRole)) {
        $journal=[ordered]@{schema_version=1;operation='publish-prepared-file-set';transaction_id=$transactionId;items=$journalItems}
    } else {
        $journal=[ordered]@{schema_version=2;operation='publish-prepared-file-set';transaction_id=$transactionId;role=$TransactionRole;items=$journalItems}
        $contextStates = @($journalItems | ForEach-Object {
            [pscustomobject]@{
                Item=$_
                CandidateSource=(Join-Path $rootFull $_.prepared)
                PriorSource=if ([bool]$_.old_present) { Join-Path $rootFull $_.target } else { $null }
            }
        })
        Assert-PreparedFileSetTransactionContext -JournalName $journalLeaf -Journal $journal -States $contextStates -ExpectedRole $TransactionRole -ExpectedTargetNames $ExpectedTargetNames
        if ($TransactionRole -ceq 'portable-zip') { Assert-PortableTransactionPairSemantics -States $contextStates -SetKind candidate }
    }
    $journalWritingPath = Join-Path $rootFull ("$journalLeaf.writing-$transactionId")
    $journalPreparedPath = Join-Path $rootFull ("$journalLeaf.prepared-$transactionId")
    $journalUtf8 = New-Object Text.UTF8Encoding($false)
    $journalJson = ($journal | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $journalStream = New-Object IO.FileStream($journalWritingPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $journalBytes = $journalUtf8.GetBytes($journalJson)
        $journalStream.Write($journalBytes,0,$journalBytes.Length)
        $journalStream.Flush($true)
    } finally { $journalStream.Dispose() }
    [IO.File]::Move($journalWritingPath,$journalPreparedPath)
    if ($null -ne $InternalCheckpoint) { & $InternalCheckpoint 'journal-prepared' -1 $journalPreparedPath $null | Out-Null }
    [IO.File]::Move($journalPreparedPath,$journalPath)
    $repairParameters = @{}
    if (-not [string]::IsNullOrWhiteSpace($TransactionRole)) { $repairParameters=@{ExpectedRole=$TransactionRole;ExpectedTargetNames=$ExpectedTargetNames} }
    try {
        if ($null -ne $InternalCheckpoint) { & $InternalCheckpoint 'journal-written' -1 $journalPath $null | Out-Null }
        for ($index=0; $index -lt $journalItems.Count; $index++) {
            $item=$journalItems[$index];$target=Join-Path $rootFull $item.target;$backup=Join-Path $rootFull $item.backup
            if ([bool]$item.old_present) {[IO.File]::Move($target,$backup)}
            if ($null -ne $InternalCheckpoint) { & $InternalCheckpoint 'prior-backed-up' $index $target $backup | Out-Null }
        }
        for ($index=0; $index -lt $journalItems.Count; $index++) {
            $item=$journalItems[$index];$prepared=Join-Path $rootFull $item.prepared;$target=Join-Path $rootFull $item.target
            if ($null -ne $InternalCheckpoint) { & $InternalCheckpoint 'before-candidate-publish' $index $target $prepared | Out-Null }
            [IO.File]::Move($prepared,$target)
            if ($null -ne $InternalCheckpoint) { & $InternalCheckpoint 'candidate-published' $index $target $prepared | Out-Null }
        }
        $recovery=Repair-PreparedFileSetTransaction -Root $rootFull -JournalName $journalLeaf @repairParameters
        if([string]$recovery.State -cne 'committed'){throw 'Prepared file-set publication unexpectedly rolled back.'}
    } catch {
        $publicationError=$_
        try{$recovery=Repair-PreparedFileSetTransaction -Root $rootFull -JournalName $journalLeaf @repairParameters}catch{throw "File-set publication failed and recovery was incomplete. Publication: $($publicationError.Exception.Message) Recovery: $($_.Exception.Message)"}
        if([string]$recovery.State -cne 'committed'){throw $publicationError}
    }
    return @($journalItems | ForEach-Object { Join-Path $rootFull $_.target })
}

function Get-ReservedNodeRuntimeArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $runtimeFull = Resolve-FullPath -Path $RuntimeRoot -MustExist -PathType Container
    return @(Get-ChildItem -LiteralPath $runtimeFull -Force | Where-Object {
        $_.Name.StartsWith('.node', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('.LICENSE.backup-', [StringComparison]::OrdinalIgnoreCase)
    })
}

function Assert-NoReservedNodeRuntimeArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $reserved = @(Get-ReservedNodeRuntimeArtifacts -RuntimeRoot $RuntimeRoot)
    if ($reserved.Count -gt 0) {
        throw "Runtime contains reserved Node transaction debris: $(@($reserved | ForEach-Object Name | Sort-Object) -join ', ')"
    }
}

function Repair-NodeRuntimePreparedOrphans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$LicensePath,
        [switch]$NoDownload,
        [hashtable]$PairValidationParameters = @{}
    )
    $runtimeFull = Resolve-FullPath -Path $RuntimeRoot -MustExist -PathType Container
    $reserved = @(Get-ReservedNodeRuntimeArtifacts -RuntimeRoot $runtimeFull)
    if ($reserved.Count -eq 0) { return [pscustomobject]@{State='none'} }

    $tokens = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $preparedNode = $null
    $preparedLicense = $null
    $writingNode = $null
    $writingLicense = $null
    foreach ($artifact in $reserved) {
        Assert-NoReparsePoint -Root $runtimeFull -Path $artifact.FullName
        if (-not (Test-Path -LiteralPath $artifact.FullName -PathType Leaf)) { throw "Reserved Node transaction artifact is not a regular file: $($artifact.FullName)" }
        if ($artifact.Name -cmatch '^\.node-([0-9a-f]{32})\.prepared$') {
            if ($null -ne $preparedNode) { throw 'Node runtime contains duplicate prepared executable candidates.' }
            [void]$tokens.Add($Matches[1]); $preparedNode = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.node-license-([0-9a-f]{32})\.prepared$') {
            if ($null -ne $preparedLicense) { throw 'Node runtime contains duplicate prepared license candidates.' }
            [void]$tokens.Add($Matches[1]); $preparedLicense = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.node-([0-9a-f]{32})\.writing$') {
            if ($null -ne $writingNode) { throw 'Node runtime contains duplicate incomplete executable writes.' }
            [void]$tokens.Add($Matches[1]); $writingNode = $artifact.FullName
        } elseif ($artifact.Name -cmatch '^\.node-license-([0-9a-f]{32})\.writing$') {
            if ($null -ne $writingLicense) { throw 'Node runtime contains duplicate incomplete license writes.' }
            [void]$tokens.Add($Matches[1]); $writingLicense = $artifact.FullName
        } else {
            throw "Runtime contains malformed or unbound reserved Node transaction debris: $($artifact.Name)"
        }
    }
    if ($tokens.Count -ne 1) { throw 'Node runtime contains ambiguous prepared candidates from different transaction tokens.' }
    if (($null -ne $writingNode -and $null -ne $preparedNode) -or ($null -ne $writingLicense -and $null -ne $preparedLicense)) {
        throw 'Node runtime contains both writing and prepared artifacts for the same transaction item.'
    }
    # Writing names are never referenced by a publication journal. They are
    # durable-copy work products and are safe to reclaim after the full
    # reserved namespace has been proven to belong to one transaction token.
    foreach ($writing in @($writingLicense,$writingNode)) {
        if ($null -ne $writing) { Remove-Item -LiteralPath $writing -Force }
    }

    $canonicalValid = Test-PinnedNodeRuntimePair -NodePath $NodePath -LicensePath $LicensePath @PairValidationParameters
    $invalidPrepared = @(
        if ($null -ne $preparedNode -and -not (Test-FileDescriptorMatch -Path $preparedNode -Bytes 92299080 -Sha256 $script:PinnedNodeExecutableSha256)) { $preparedNode }
        if ($null -ne $preparedLicense -and -not (Test-FileDescriptorMatch -Path $preparedLicense -Bytes 159872 -Sha256 $script:PinnedNodeLicenseSha256)) { $preparedLicense }
    )
    if ($invalidPrepared.Count -gt 0) {
        if (-not $canonicalValid -and $NoDownload) {
            throw 'A malformed pre-journal Node runtime candidate cannot repair the damaged offline runtime; its prepared artifacts were preserved.'
        }
        foreach ($prepared in @($preparedLicense,$preparedNode)) {
            if ($null -ne $prepared) { Remove-Item -LiteralPath $prepared -Force }
        }
        return [pscustomobject]@{State='removed'}
    }
    $candidateComplete = $null -ne $preparedNode -and $null -ne $preparedLicense
    if (-not $canonicalValid -and $candidateComplete) {
        Publish-PreparedFileSetTransaction -Root $runtimeFull -JournalName '.node-runtime-transaction.json' -TransactionRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') -Items @(
            [pscustomobject]@{PreparedPath=$preparedLicense;TargetPath=$LicensePath},
            [pscustomobject]@{PreparedPath=$preparedNode;TargetPath=$NodePath}
        ) | Out-Null
        return [pscustomobject]@{State='published'}
    }
    if (-not $canonicalValid -and $NoDownload) {
        throw 'An incomplete pre-journal Node runtime candidate cannot repair the damaged offline runtime; all artifacts were preserved.'
    }

    # The canonical pair is already valid, or online repair can recreate it.
    # These exact-token, hash-validated candidates are app-owned pre-journal debris.
    foreach ($prepared in @($preparedLicense,$preparedNode)) {
        if ($null -ne $prepared) { Remove-Item -LiteralPath $prepared -Force }
    }
    return [pscustomobject]@{State='removed'}
}

function Ensure-PinnedNodeRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$NoDownload,
        [hashtable]$InternalTestHooks
    )

    Assert-InternalNodeRuntimeTestHooks -Hooks $InternalTestHooks
    $pairValidationParameters = @{}
    if ($null -ne $InternalTestHooks) {
        if ($InternalTestHooks.ContainsKey('PeMachineTypeProbe')) { $pairValidationParameters.InternalPeMachineTypeProbe = $InternalTestHooks.PeMachineTypeProbe }
        if ($InternalTestHooks.ContainsKey('FileVersionProbe')) { $pairValidationParameters.InternalFileVersionProbe = $InternalTestHooks.FileVersionProbe }
        if ($InternalTestHooks.ContainsKey('NativeVersionProbe')) { $pairValidationParameters.InternalNativeVersionProbe = $InternalTestHooks.NativeVersionProbe }
    }

    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $runtimeRoot = Join-Path $root 'runtime'
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        if (Test-Path -LiteralPath $runtimeRoot) { throw "Runtime path is not a directory: $runtimeRoot" }
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
    }
    $runtimeRoot = Resolve-FullPath -Path $runtimeRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $runtimeRoot

    $nodePath = Join-Path $runtimeRoot 'node.exe'
    $runtimeLicense = Join-Path $runtimeRoot 'LICENSE'
    $journalName = '.node-runtime-transaction.json'
    $journalPath = Join-Path $runtimeRoot $journalName
    if ((Test-Path -LiteralPath $journalPath) -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw "Node runtime transaction journal is not a file: $journalPath" }
    Repair-PreparedFileSetTransaction -Root $runtimeRoot -JournalName $journalName -ExpectedRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') | Out-Null

    $sourceLicense = Resolve-FullPath -Path (Join-Path $root 'licenses\NODE-LICENSE.txt') -MustExist -PathType Leaf
    $sourceLicenseItem = Get-FileSystemItemOrFallback -Path $sourceLicense
    if ([int64]$sourceLicenseItem.Length -ne 159872 -or
        (Get-FileHash -LiteralPath $sourceLicense -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:PinnedNodeLicenseSha256) {
        throw 'The checked-in Node.js license does not match the pinned official v24.17.0 distribution.'
    }
    Repair-NodeRuntimePreparedOrphans -RuntimeRoot $runtimeRoot -NodePath $nodePath -LicensePath $runtimeLicense -NoDownload:$NoDownload -PairValidationParameters $pairValidationParameters | Out-Null
    Assert-NoReservedNodeRuntimeArtifacts -RuntimeRoot $runtimeRoot
    if (Test-PinnedNodeRuntimePair -NodePath $nodePath -LicensePath $runtimeLicense @pairValidationParameters) { return Resolve-FullPath -Path $nodePath -MustExist -PathType Leaf }
    if ($NoDownload) { throw 'The bundled Node.js v24.17.0 runtime pair is missing or invalid; portable repack mode will not download or repair tools.' }

    $buildRoot = Join-Path $root 'build'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        if (Test-Path -LiteralPath $buildRoot) { throw "Build path is not a directory: $buildRoot" }
        New-Item -ItemType Directory -Path $buildRoot | Out-Null
    }
    $buildRoot = Resolve-FullPath -Path $buildRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $buildRoot

    $token = [Guid]::NewGuid().ToString('N')
    $downloadRoot = Join-Path $buildRoot "node-download-$token"
    $expandRoot = Join-Path $buildRoot "node-expand-$token"
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null
    New-Item -ItemType Directory -Path $expandRoot | Out-Null
    $preparedLicense = Join-Path $runtimeRoot ".node-license-$token.prepared"
    $preparedNode = Join-Path $runtimeRoot ".node-$token.prepared"
    $writingLicense = Join-Path $runtimeRoot ".node-license-$token.writing"
    $writingNode = Join-Path $runtimeRoot ".node-$token.writing"
    try {
        $archiveName = 'node-v24.17.0-win-x64.zip'
        $archivePath = Join-Path $downloadRoot $archiveName
        Write-Host 'Downloading pinned official Node.js v24.17.0 Windows x64 runtime...'
        $archiveUri = [Uri]"https://nodejs.org/dist/v24.17.0/$archiveName"
        if ($null -eq $InternalTestHooks) {
            Invoke-BoundedNodeJsDownload -Uri $archiveUri -Destination $archivePath -TimeoutSeconds 300 -MaximumBytes 67108864 | Out-Null
        } else {
            & $InternalTestHooks.DownloadArchive $archiveUri $archivePath 300 ([int64]67108864) | Out-Null
        }
        Assert-NoReparsePoint -Root $downloadRoot -Path $archivePath
        $expectedArchiveSha256 = if ($null -eq $InternalTestHooks) { $script:PinnedNodeArchiveSha256 } else { [string]$InternalTestHooks.ExpectedArchiveSha256 }
        Assert-FileSha256 -Path $archivePath -Expected $expectedArchiveSha256 | Out-Null
        if ($null -eq $InternalTestHooks) {
            Expand-Archive -LiteralPath $archivePath -DestinationPath $expandRoot -Force
        } else {
            & $InternalTestHooks.ExpandArchive $archivePath $expandRoot | Out-Null
        }
        $distributionRoot = Resolve-FullPath -Path (Join-Path $expandRoot 'node-v24.17.0-win-x64') -MustExist -PathType Container
        Assert-NoReparsePoint -Root $expandRoot -Path $distributionRoot
        $extractedNode = Resolve-FullPath -Path (Join-Path $distributionRoot 'node.exe') -MustExist -PathType Leaf
        $extractedLicense = Resolve-FullPath -Path (Join-Path $distributionRoot 'LICENSE') -MustExist -PathType Leaf
        if (-not (Test-PinnedNodeRuntimePair -NodePath $extractedNode -LicensePath $extractedLicense @pairValidationParameters)) {
            throw 'Extracted Node.js files do not match the pinned v24.17.0 x64 runtime and license.'
        }
        if ((Get-FileHash -LiteralPath $extractedLicense -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            (Get-FileHash -LiteralPath $sourceLicense -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'Extracted Node.js license does not match the checked-in pinned license.'
        }

        Copy-FileDurable -Source $extractedLicense -Destination $writingLicense | Out-Null
        if (-not (Test-FileDescriptorMatch -Path $writingLicense -Bytes 159872 -Sha256 $script:PinnedNodeLicenseSha256)) { throw 'Prepared Node.js license copy failed validation.' }
        [IO.File]::Move($writingLicense,$preparedLicense)
        Copy-FileDurable -Source $extractedNode -Destination $writingNode | Out-Null
        if (-not (Test-FileDescriptorMatch -Path $writingNode -Bytes 92299080 -Sha256 $script:PinnedNodeExecutableSha256)) { throw 'Prepared Node.js executable copy failed validation.' }
        [IO.File]::Move($writingNode,$preparedNode)
        $publicationParameters = @{}
        if ($null -ne $InternalTestHooks -and $InternalTestHooks.ContainsKey('PublicationCheckpoint')) {
            $publicationParameters.InternalCheckpoint = $InternalTestHooks.PublicationCheckpoint
        }
        Publish-PreparedFileSetTransaction -Root $runtimeRoot -JournalName $journalName -TransactionRole node-runtime -ExpectedTargetNames @('LICENSE','node.exe') -Items @(
            [pscustomobject]@{PreparedPath=$preparedLicense;TargetPath=$runtimeLicense},
            [pscustomobject]@{PreparedPath=$preparedNode;TargetPath=$nodePath}
        ) @publicationParameters | Out-Null
        if (-not (Test-PinnedNodeRuntimePair -NodePath $nodePath -LicensePath $runtimeLicense @pairValidationParameters)) {
            throw 'Published Node.js runtime pair failed final validation.'
        }
        return Resolve-FullPath -Path $nodePath -MustExist -PathType Leaf
    } finally {
        foreach ($writing in @($writingLicense,$writingNode)) {
            if (Test-Path -LiteralPath $writing -PathType Leaf) { Remove-Item -LiteralPath $writing -Force }
        }
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            foreach ($prepared in @($preparedLicense,$preparedNode)) {
                if (Test-Path -LiteralPath $prepared -PathType Leaf) {
                    $expectedHash = if ($prepared -ceq $preparedNode) { $script:PinnedNodeExecutableSha256 } else { $script:PinnedNodeLicenseSha256 }
                    if ((Get-FileHash -LiteralPath $prepared -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) {
                        Remove-Item -LiteralPath $prepared -Force
                    }
                }
            }
        }
        foreach ($temporaryRoot in @($downloadRoot,$expandRoot)) {
            if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
                Remove-SafeDirectory -ConfinementRoot $buildRoot -Path $temporaryRoot
            }
        }
    }
}

function Assert-ChecksumManifestSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { throw 'Checksum manifest contains a malformed line.' }
        $relative = $Matches[2].Trim().Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|/)\.\.(/|$)' -or -not $seen.Add($relative)) { throw 'Checksum manifest contains an unsafe or duplicate path.' }
    }
    if ($seen.Count -eq 0) { throw 'Checksum manifest is empty.' }
    return $true
}

function Repair-TargetSpecificAtomicFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfinementRoot,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][scriptblock]$ValidateCanonical,
        [ValidateRange(1,1073741824)][int64]$MaximumArtifactBytes = 1048576
    )
    $root = Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    $target = Assert-PathWithin -Root $root -Path $TargetPath
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    Assert-NoReparsePoint -Root $root -Path $parent
    $leaf = [Regex]::Escape([IO.Path]::GetFileName($target))
    $artifacts = @(Get-ChildItem -LiteralPath $parent -File -Force | Where-Object { $_.Name -match "^\.$leaf\.replace\.(?:writing|tmp|backup)-[0-9a-f]{32}$" })
    if ($artifacts.Count -eq 0) { return }
    foreach ($artifact in $artifacts) {
        if (($artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $artifact.Length -gt $MaximumArtifactBytes) { throw "Unsafe atomic-replacement artifact: $($artifact.FullName)" }
    }
    $ids = @($artifacts | ForEach-Object { if ($_.Name -match '-([0-9a-f]{32})$') { $Matches[1] } } | Select-Object -Unique)
    if ($ids.Count -ne 1 -or $artifacts.Count -gt 2) { throw "Ambiguous atomic-replacement artifacts for '$target'." }
    $writing = $artifacts | Where-Object Name -match '\.replace\.writing-' | Select-Object -First 1
    $temporary = $artifacts | Where-Object Name -match '\.replace\.tmp-' | Select-Object -First 1
    $backup = $artifacts | Where-Object Name -match '\.replace\.backup-' | Select-Object -First 1
    if ($null -ne $writing) {
        if ($artifacts.Count -ne 1) { throw "An incomplete atomic write coexists with publication artifacts for '$target'." }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            & $ValidateCanonical $target | Out-Null
        } elseif (Test-Path -LiteralPath $target) {
            throw "Atomic replacement target is not a file: $target"
        }
        # A writing leaf has never crossed the prepared-name boundary, so no
        # canonical mutation can depend on it.
        Remove-Item -LiteralPath $writing.FullName -Force -ErrorAction Stop
        return
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        & $ValidateCanonical $target | Out-Null
    } elseif (Test-Path -LiteralPath $target) {
        throw "Atomic replacement target is not a file: $target"
    } else {
        $source = if ($null -ne $backup) { $backup } else { $temporary }
        if ($null -eq $source) { throw "Atomic replacement has no recoverable source for '$target'." }
        [IO.File]::Move($source.FullName, $target)
        try {
            & $ValidateCanonical $target | Out-Null
        } catch {
            if (-not (Test-Path -LiteralPath $source.FullName) -and (Test-Path -LiteralPath $target -PathType Leaf)) { [IO.File]::Move($target, $source.FullName) }
            throw
        }
    }
    foreach ($artifact in $artifacts) { if (Test-Path -LiteralPath $artifact.FullName -PathType Leaf) { Remove-Item -LiteralPath $artifact.FullName -Force -ErrorAction Stop } }
}

function Get-RevisionStageReportRepairContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RevisionDirectory
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $revisionsRoot = Resolve-FullPath -Path (Join-Path $root 'revisions') -MustExist -PathType Container
    $revisionRoot = Assert-PathWithin -Root $revisionsRoot -Path (Resolve-FullPath -Path $RevisionDirectory -MustExist -PathType Container)
    $revisionName = [IO.Path]::GetFileName($revisionRoot)
    if ($revisionName -cnotmatch '^[0-9a-f]{64}$') { throw "Revision stage-report repair directory has an invalid identity: $revisionName" }
    $manifestPath = Join-Path $revisionRoot 'manifest.json'
    Assert-NoReparsePoint -Root $revisionsRoot -Path $manifestPath
    if ((Get-FileSystemItemOrFallback -Path $manifestPath).Length -gt 2097152) { throw "Revision manifest is unexpectedly large during stage-report repair: $manifestPath" }
    $manifest = Read-JsonFile -Path $manifestPath -Context 'revision manifest for stage-report repair' -RequireObject
    $schema = Get-RevisionJsonField $manifest 'schema_version' Integer 'revision manifest for stage-report repair' -Minimum 1
    $database = Get-RevisionJsonField $manifest 'database' Object 'revision manifest for stage-report repair'
    $databaseHash = Get-RevisionJsonField $database 'sha256' String 'revision manifest database for stage-report repair'
    $corpusRevision = Get-RevisionJsonField $manifest 'corpus_sha256' String 'revision manifest for stage-report repair'
    if ($databaseHash -cnotmatch '^[0-9a-f]{64}$' -or $corpusRevision -cnotmatch '^[0-9a-f]{64}$') { throw 'Revision manifest identities are invalid during stage-report repair.' }
    if ($schema -eq $script:ManifestSchemaVersion) {
        $indexRevision = Get-RevisionJsonField $manifest 'index_revision' String 'revision manifest for stage-report repair'
        if ($indexRevision -cne $databaseHash -or $revisionName -cne $indexRevision) { throw 'Current revision identity is inconsistent during stage-report repair.' }
        return [pscustomobject]@{Kind='current';ExpectedRevision=$indexRevision;RevisionRoot=$revisionRoot}
    }
    if ($schema -eq $script:LegacyManifestSchemaVersion) {
        if ($revisionName -cne $corpusRevision -and $revisionName -cne $databaseHash) { throw 'Legacy revision identity is inconsistent during stage-report repair.' }
        return [pscustomobject]@{Kind='legacy';ExpectedRevision=$corpusRevision;RevisionRoot=$revisionRoot}
    }
    throw "Unsupported revision manifest schema '$schema' during stage-report repair."
}

function Assert-RevisionStageReportForRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Context
    )
    if ([string]$Context.Kind -ceq 'current') {
        Assert-StagedRevisionReport -Path $Path -ExpectedRevision ([string]$Context.ExpectedRevision) | Out-Null
        return
    }
    if ([string]$Context.Kind -ceq 'legacy') {
        Assert-LegacyStagedRevisionReport -Path $Path -ExpectedCorpusRevision ([string]$Context.ExpectedRevision) | Out-Null
        return
    }
    throw 'Stage-report repair context is invalid.'
}

function Repair-InterruptedMaintenanceArtifacts {
    <# This function mutates only disposable, strictly named atomic-write debris.
       Callers must hold the project maintenance lock before invoking it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $root

    $dataRoot = Join-Path $root 'data'
    $maintenanceRoot = Join-Path $root 'maintenance'
    $revisionsRoot = Join-Path $root 'revisions'
    foreach ($directory in @($dataRoot,$maintenanceRoot,$revisionsRoot)) {
        if (Test-Path -LiteralPath $directory) { Assert-NoReparsePoint -Root $root -Path $directory }
    }

    Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath (Join-Path $dataRoot 'active.json') -ValidateCanonical {
        param($canonicalPath)
        Get-ActiveRevisionPointer -ProjectRoot $root | Out-Null
    }
    Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath (Join-Path $maintenanceRoot 'update-status.json') -ValidateCanonical {
        param($canonicalPath)
        Get-UpdateStatus -ProjectRoot $root | Out-Null
    }
    Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath (Join-Path $maintenanceRoot 'revision-transition.json') -ValidateCanonical {
        param($canonicalPath)
        Get-RevisionTransition -ProjectRoot $root | Out-Null
    }
    Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath (Join-Path $maintenanceRoot 'revision-stage.json') -MaximumArtifactBytes 2097152 -ValidateCanonical {
        param($canonicalPath)
        $journal = Read-JsonFile -Path $canonicalPath -Context 'revision stage journal' -RequireObject
        Assert-ExactJsonProperties -Object $journal -Names @('schema_version','operation','index_revision','corpus_revision','base_index_revision','base_corpus_revision','candidate_tree_sha256','json_digest_contract','stage_report_canonical_sha256','stage_report_file_sha256','destination_existed','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256','allow_legacy_active','started_at','stage_report') -Context 'revision stage journal'
        Assert-RevisionStageJournalTypes -Journal $journal
        if ([int]$journal.schema_version -ne 1 -or @('rebuild','documentation-update') -cnotcontains [string]$journal.operation) { throw 'Revision stage journal schema or operation is invalid.' }
        if ([string]$journal.json_digest_contract -cne 'powershell-json-compress-depth20-v1') { throw 'Revision stage journal digest contract is invalid.' }
        foreach ($name in @('index_revision','corpus_revision','candidate_tree_sha256','stage_report_canonical_sha256','stage_report_file_sha256')) {
            if ([string]$journal.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Revision stage journal $name is invalid." }
        }
        if (($null -eq $journal.base_index_revision) -ne ($null -eq $journal.base_corpus_revision)) { throw 'Revision stage journal base revisions must both be set or both be null.' }
        foreach ($name in @('base_index_revision','base_corpus_revision','prior_stage_report_canonical_sha256','prior_stage_report_file_sha256')) {
            if ($null -ne $journal.PSObject.Properties[$name].Value -and [string]$journal.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Revision stage journal $name is invalid." }
        }
        if ($journal.destination_existed -isnot [bool] -or $journal.allow_legacy_active -isnot [bool]) { throw 'Revision stage journal Boolean fields are invalid.' }
        if (($null -eq $journal.prior_stage_report_canonical_sha256) -ne ($null -eq $journal.prior_stage_report_file_sha256)) { throw 'Revision stage journal prior report digests must both be set or both be null.' }
        if (-not [bool]$journal.destination_existed -and $null -ne $journal.prior_stage_report_canonical_sha256) { throw 'A new stage destination cannot declare a prior stage report.' }
        Assert-UtcIsoTimestamp -Value ([string]$journal.started_at) -Context 'revision stage journal started_at'
        Assert-ExactJsonProperties -Object $journal.stage_report -Names @('schema_version','index_revision','corpus_revision','base_index_revision','base_corpus_revision','staged_at','validation_passed','source_topic_counts','changes','asset_changes','required_rankings') -Context 'revision stage journal report'
        if ([int]$journal.stage_report.schema_version -ne 3 -or $journal.stage_report.validation_passed -isnot [bool] -or -not [bool]$journal.stage_report.validation_passed -or
            [string]$journal.stage_report.index_revision -cne [string]$journal.index_revision -or [string]$journal.stage_report.corpus_revision -cne [string]$journal.corpus_revision -or
            [string]$journal.stage_report.base_index_revision -cne [string]$journal.base_index_revision -or [string]$journal.stage_report.base_corpus_revision -cne [string]$journal.base_corpus_revision) { throw 'Revision stage journal report identity is invalid.' }
        Assert-UtcIsoTimestamp -Value ([string]$journal.stage_report.staged_at) -Context 'revision stage journal report staged_at'
        $canonical = $journal.stage_report | ConvertTo-Json -Compress -Depth 20
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($digest -cne [string]$journal.stage_report_canonical_sha256) { throw 'Revision stage journal report digest is invalid.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $fileDigest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical + "`r`n")))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($fileDigest -cne [string]$journal.stage_report_file_sha256) { throw 'Revision stage journal report file digest is invalid.' }
    }
    Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath (Join-Path $root 'checksums.sha256') -MaximumArtifactBytes 67108864 -ValidateCanonical {
        param($canonicalPath)
        Assert-ChecksumManifestSyntax -Path $canonicalPath | Out-Null
    }

    $jsonGroups = @(
        [pscustomobject]@{ Root=$dataRoot; Kind='active pointer' },
        [pscustomobject]@{ Root=$maintenanceRoot; Kind='maintenance JSON' }
    )
    foreach ($group in $jsonGroups) {
        if (-not (Test-Path -LiteralPath $group.Root -PathType Container)) { continue }
        $prefixed = @(Get-ChildItem -LiteralPath $group.Root -Force | Where-Object { $_.Name -like '.json.tmp-*' -or $_.Name -like '.json.backup-*' })
        foreach ($item in $prefixed) {
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Name -cnotmatch '^\.json\.(?:tmp|backup)-[0-9a-f]{32}$') {
                throw "Ambiguous interrupted-write artifact in '$($group.Root)': $($item.Name)"
            }
            if ($item.Length -gt 1048576) { throw "Interrupted JSON artifact is unexpectedly large: $($item.FullName)" }
        }
        if ($prefixed.Count -eq 0) { continue }
        if ($group.Kind -eq 'active pointer') {
            $pointerPath = Join-Path $dataRoot 'active.json'
            $hasBackup = @($prefixed | Where-Object Name -like '.json.backup-*').Count -gt 0
            if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
                Get-ActiveRevisionPointer -ProjectRoot $root | Out-Null
            } elseif ($hasBackup) {
                throw 'Cannot reconcile an active-pointer backup without a valid canonical active.json.'
            }
        } else {
            $statusPath = Join-Path $maintenanceRoot 'update-status.json'
            $transitionPath = Join-Path $maintenanceRoot 'revision-transition.json'
            $hasBackup = @($prefixed | Where-Object Name -like '.json.backup-*').Count -gt 0
            $hasStatus = Test-Path -LiteralPath $statusPath -PathType Leaf
            $hasTransition = Test-Path -LiteralPath $transitionPath -PathType Leaf
            if ($hasBackup -and (-not $hasStatus -or -not $hasTransition)) {
                throw 'A legacy maintenance JSON backup is ambiguous because its target name was not recorded; retaining it for manual recovery.'
            }
            if ($hasStatus) { Get-UpdateStatus -ProjectRoot $root | Out-Null }
            if ($hasTransition) { Get-RevisionTransition -ProjectRoot $root | Out-Null }
        }
        foreach ($item in $prefixed) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
    }

    $checksumDebris = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -like '.checksums.tmp-*' -or $_.Name -like '.checksums.backup-*' })
    foreach ($item in $checksumDebris) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Name -cnotmatch '^\.checksums\.(?:tmp|backup)-[0-9a-f]{32}$') {
            throw "Ambiguous interrupted checksum artifact: $($item.Name)"
        }
    }
    if ($checksumDebris.Count -gt 0) {
        $checksumPath = Join-Path $root 'checksums.sha256'
        if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'Cannot reconcile checksum debris because checksums.sha256 is missing.' }
        $seenChecksums = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { throw 'Cannot reconcile checksum debris because checksums.sha256 is malformed.' }
            $relative = $Matches[2].Trim().Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or -not $seenChecksums.Add($relative)) {
                throw 'Cannot reconcile checksum debris because checksums.sha256 contains an unsafe or duplicate path.'
            }
        }
        if ($seenChecksums.Count -eq 0) { throw 'Cannot reconcile checksum debris because checksums.sha256 is empty.' }
        foreach ($item in $checksumDebris) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
    }

    if (Test-Path -LiteralPath $revisionsRoot -PathType Container) {
        $revisionRootItems = @(Get-ChildItem -LiteralPath $revisionsRoot -Force)
        foreach ($rootItem in $revisionRootItems) {
            if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to reconcile maintenance artifacts through a reparse point: $($rootItem.FullName)"
            }
        }
        foreach ($revisionDirectory in $revisionRootItems | Where-Object { $_.PSIsContainer }) {
            if ($revisionDirectory.Name -cnotmatch '^[0-9a-f]{64}$') { continue }
            $reportPath = Join-Path $revisionDirectory.FullName 'stage-report.json'
            $targetSpecificReportDebris = @(Get-ChildItem -LiteralPath $revisionDirectory.FullName -Force | Where-Object { $_.Name -like '.stage-report.json.replace.*' })
            foreach ($item in $targetSpecificReportDebris) {
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Name -cnotmatch '^\.stage-report\.json\.replace\.(?:writing|tmp|backup)-[0-9a-f]{32}$') {
                    throw "Ambiguous staged-report replacement artifact in '$($revisionDirectory.FullName)': $($item.Name)"
                }
                if ($item.Length -gt 1048576) { throw "Interrupted staged-report replacement artifact is unexpectedly large: $($item.FullName)" }
            }
            $reportDebris = @(Get-ChildItem -LiteralPath $revisionDirectory.FullName -Force | Where-Object { $_.Name -like '.json.tmp-*' -or $_.Name -like '.json.backup-*' })
            foreach ($item in $reportDebris) {
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Name -cnotmatch '^\.json\.(?:tmp|backup)-[0-9a-f]{32}$') {
                    throw "Ambiguous staged-report artifact in '$($revisionDirectory.FullName)': $($item.Name)"
                }
                if ($item.Length -gt 1048576) { throw "Interrupted staged-report artifact is unexpectedly large: $($item.FullName)" }
            }
            if ($targetSpecificReportDebris.Count -eq 0 -and $reportDebris.Count -eq 0) { continue }

            $reportRepairContext = $null
            if ($targetSpecificReportDebris.Count -gt 0) {
                $reportRepairContext = Get-RevisionStageReportRepairContext -ProjectRoot $root -RevisionDirectory $revisionDirectory.FullName
                Repair-TargetSpecificAtomicFile -ConfinementRoot $root -TargetPath $reportPath -ValidateCanonical {
                    param($canonicalPath)
                    Assert-RevisionStageReportForRepair -Path $canonicalPath -Context $reportRepairContext
                }
            }
            if ($reportDebris.Count -gt 0) {
                if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
                    if ($null -eq $reportRepairContext) { $reportRepairContext = Get-RevisionStageReportRepairContext -ProjectRoot $root -RevisionDirectory $revisionDirectory.FullName }
                    Assert-RevisionStageReportForRepair -Path $reportPath -Context $reportRepairContext
                } elseif (Test-Path -LiteralPath $reportPath) {
                    throw "Staged-report repair target is not a file for revision '$($revisionDirectory.Name)'."
                } else {
                    $backups = @($reportDebris | Where-Object Name -like '.json.backup-*')
                    $temporaries = @($reportDebris | Where-Object Name -like '.json.tmp-*')
                    if ($backups.Count -gt 1) { throw "Interrupted staged-report artifacts are ambiguous for revision '$($revisionDirectory.Name)'." }
                    if ($backups.Count -eq 1) {
                        if ($null -eq $reportRepairContext) { $reportRepairContext = Get-RevisionStageReportRepairContext -ProjectRoot $root -RevisionDirectory $revisionDirectory.FullName }
                        $source = $backups[0]
                        [IO.File]::Move($source.FullName, $reportPath)
                        try {
                            Assert-RevisionStageReportForRepair -Path $reportPath -Context $reportRepairContext
                        } catch {
                            if (-not (Test-Path -LiteralPath $source.FullName) -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) { [IO.File]::Move($reportPath, $source.FullName) }
                            throw
                        }
                    }
                }
                foreach ($item in $reportDebris) {
                    if (Test-Path -LiteralPath $item.FullName -PathType Leaf) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
                }
            }
        }
        $legacyDebris = @(Get-ChildItem -LiteralPath $revisionsRoot -Force | Where-Object { $_.Name -like '.legacy-index-*' })
        foreach ($item in $legacyDebris) {
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Name -cnotmatch '^\.legacy-index-[0-9a-f]{32}$') {
                throw "Ambiguous legacy-migration artifact: $($item.Name)"
            }
            Remove-SafeDirectory -ConfinementRoot $revisionsRoot -Path $item.FullName
        }
        $installDebris = @(Get-ChildItem -LiteralPath $revisionsRoot -Force | Where-Object { $_.Name -like '.revision-install-*' })
        foreach ($item in $installDebris) {
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Name -cnotmatch '^\.revision-install-[0-9a-f]{32}$') {
                throw "Ambiguous revision-installation artifact: $($item.Name)"
            }
            Remove-SafeDirectory -ConfinementRoot $revisionsRoot -Path $item.FullName
        }
    }
}

function Get-CorpusRevision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SourceHashes)
    $builder = New-Object System.Text.StringBuilder
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $property = $SourceHashes.PSObject.Properties[$definition.Id]
        if ($null -eq $property) { throw "Source hashes are missing '$($definition.Id)'." }
        $hash = [string]$property.Value
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw "Source hash for '$($definition.Id)' is invalid." }
        [void]$builder.Append($definition.Id).Append([char]0).Append($hash.ToLowerInvariant()).Append([char]0)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString())))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-ActiveRevisionPointer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$AllowMissing)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $path = Join-Path $root 'data\active.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "Active revision pointer is missing: $path"
    }
    $pointer = Read-JsonFile -Path $path -Context 'active revision pointer' -RequireObject
    Get-RevisionJsonField $pointer 'schema_version' Integer 'active revision pointer' -Minimum 1 | Out-Null
    foreach ($name in @('active_revision','activated_at')) { Get-RevisionJsonField $pointer $name String 'active revision pointer' | Out-Null }
    Get-RevisionJsonField $pointer 'previous_revision' NullableString 'active revision pointer' | Out-Null
    Assert-ExactJsonProperties -Object $pointer -Names @('schema_version','active_revision','previous_revision','activated_at') -Context 'active revision pointer'
    $schemaVersion = [int](Get-RequiredJsonProperty $pointer 'schema_version')
    if (@(1,$script:ActivePointerSchemaVersion) -notcontains $schemaVersion) { throw 'Active revision pointer schema_version must be 1 or 2.' }
    $active = [string](Get-RequiredJsonProperty $pointer 'active_revision')
    if ($active -cnotmatch '^[0-9a-f]{64}$') { throw 'active_revision must be a lowercase SHA-256 digest.' }
    $previous = Get-RequiredJsonProperty $pointer 'previous_revision'
    if ($null -ne $previous -and [string]$previous -cnotmatch '^[0-9a-f]{64}$') { throw 'previous_revision must be null or a lowercase SHA-256 digest.' }
    if ($null -ne $previous -and [string]$previous -ceq $active) { throw 'previous_revision must differ from active_revision.' }
    Assert-UtcIsoTimestamp -Value ([string](Get-RequiredJsonProperty $pointer 'activated_at')) -Context 'active pointer activated_at'
    return $pointer
}

function Set-ActiveRevisionPointer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ActiveRevision,
        [AllowNull()][AllowEmptyString()][ValidateScript({ [string]::IsNullOrEmpty([string]$_) -or $_ -match '^[0-9a-f]{64}$' })][string]$PreviousRevision,
        [ValidateSet(1,2)][int]$SchemaVersion = $script:ActivePointerSchemaVersion,
        [AllowNull()][AllowEmptyString()][string]$ActivatedAt
    )
    $previousValue = if ([string]::IsNullOrEmpty($PreviousRevision) -or $PreviousRevision -eq $ActiveRevision) { $null } else { $PreviousRevision }
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $activationTimestamp = if ([string]::IsNullOrWhiteSpace($ActivatedAt)) { [DateTime]::UtcNow.ToString('O') } else { Assert-UtcIsoTimestamp -Value $ActivatedAt -Context 'active pointer activated_at'; $ActivatedAt }
    $value = [ordered]@{ schema_version = $SchemaVersion; active_revision = $ActiveRevision; previous_revision = $previousValue; activated_at = $activationTimestamp }
    Write-JsonAtomic -Path (Join-Path $root 'data\active.json') -Value $value -ConfinementRoot $root
    return Get-ActiveRevisionPointer -ProjectRoot $root
}

function Get-RevisionDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    return Assert-PathWithin -Root $root -Path (Join-Path $root "revisions\$Revision")
}

function Get-RevisionAssetClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RevisionRoot,
        [Parameter(Mandatory)][object]$Manifest,
        [string]$ConfinementRoot
    )
    $root = if ([string]::IsNullOrWhiteSpace($ConfinementRoot)) {
        Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    } else {
        Resolve-FullPath -Path $ConfinementRoot -MustExist -PathType Container
    }
    Assert-NoReparsePoint -Root $root -Path $root
    $revisionRoot = Assert-PathWithin -Root $root -Path $RevisionRoot
    $assets = Get-RequiredJsonProperty $Manifest 'assets' 'manifest'
    Assert-ExactJsonProperties -Object $assets -Names @('directory','cataloged_count','exposed_count','excluded_count','occurrence_count','exposed_occurrence_count','total_bytes','catalog_sha256','tree_sha256','policy_sha256','by_source') -Context 'manifest.assets'
    if ([string]$assets.directory -cne 'assets') { throw "Manifest assets.directory must be 'assets'." }
    $assetsRoot = Assert-PathWithin -Root $revisionRoot -Path (Join-Path $revisionRoot ([string]$assets.directory))
    $expectedCount = [int](Get-RequiredJsonProperty $assets 'cataloged_count' 'manifest.assets')
    $expectedBytes = [int64](Get-RequiredJsonProperty $assets 'total_bytes' 'manifest.assets')
    $expectedTree = [string](Get-RequiredJsonProperty $assets 'tree_sha256' 'manifest.assets')
    if ($expectedCount -lt 0 -or $expectedBytes -lt 0 -or $expectedTree -cnotmatch '^[0-9a-f]{64}$') { throw 'Manifest asset closure metadata is invalid.' }
    if (-not (Test-Path -LiteralPath $assetsRoot -PathType Container)) { throw "Revision assets directory is missing: $assetsRoot" }
    Assert-NoReparsePoint -Root $root -Path $assetsRoot
    $reparseItems = @(Get-ChildItem -LiteralPath $assetsRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Revision assets contain a reparse point: $($reparseItems[0].FullName)" }
    foreach ($directory in Get-ChildItem -LiteralPath $assetsRoot -Recurse -Directory -Force) {
        $directoryKey = $directory.FullName.Substring($assetsRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($directoryKey -cnotmatch '^(mql5|mql5book|neuronetworksbook)$') { throw "Unexpected directory in the exact asset closure: assets/$directoryKey" }
    }

    $entries = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    $sourceCounts = @{}; $sourceBytes = @{}
    foreach ($definition in Get-Mql5CorpusDefinition) { $sourceCounts[$definition.Id] = 0; $sourceBytes[$definition.Id] = [int64]0 }
    [int64]$totalBytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $assetsRoot -Recurse -File -Force) {
        $storageKey = $file.FullName.Substring($revisionRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($storageKey -cnotmatch '^assets/(mql5|mql5book|neuronetworksbook)/([0-9a-f]{64})\.bin$') { throw "Unsafe or unexpected asset storage path: $storageKey" }
        if ($entries.ContainsKey($storageKey)) { throw "Duplicate asset storage path: $storageKey" }
        $source = $Matches[1]
        $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $entry = [pscustomobject]@{ StorageKey=$storageKey; Sha256=$fileHash; Bytes=[int64]$file.Length; Source=$source }
        $entries.Add($storageKey, $entry)
        $sourceCounts[$source]++; $sourceBytes[$source] += [int64]$file.Length; $totalBytes += [int64]$file.Length
    }
    if ($entries.Count -ne $expectedCount) { throw "Asset closure file count mismatch. Expected $expectedCount, got $($entries.Count)." }
    if ($totalBytes -ne $expectedBytes) { throw "Asset closure byte count mismatch. Expected $expectedBytes, got $totalBytes." }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in $entries.Values) {
            $record = "$($entry.StorageKey)$([char]0)$($entry.Sha256)$([char]0)$($entry.Bytes)$([char]0)"
            $bytes = [Text.Encoding]::UTF8.GetBytes($record)
            [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $actualTree = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ($actualTree -cne $expectedTree) { throw "Asset tree SHA-256 mismatch. Expected $expectedTree, got $actualTree." }

    foreach ($definition in Get-Mql5CorpusDefinition) {
        $source = Get-RequiredJsonProperty $assets.by_source $definition.Id 'manifest.assets.by_source'
        if ([int](Get-RequiredJsonProperty $source 'cataloged_count' "manifest.assets.by_source.$($definition.Id)") -ne [int]$sourceCounts[$definition.Id]) { throw "Manifest asset count does not match '$($definition.Id)'." }
        if ([int64](Get-RequiredJsonProperty $source 'total_bytes' "manifest.assets.by_source.$($definition.Id)") -ne [int64]$sourceBytes[$definition.Id]) { throw "Manifest asset bytes do not match '$($definition.Id)'." }
    }
    return [pscustomobject]@{ Count=$entries.Count; Bytes=$totalBytes; TreeSha256=$actualTree; Entries=@($entries.Values) }
}

function Assert-Revision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
        [string]$RevisionRoot,
        [string]$RevisionConfinementRoot,
        [ValidateSet('Auto','Corpus','Index')][string]$IdentityMode = 'Auto',
        [switch]$RequireCurrent,
        [switch]$RequireCurrentSources,
        [switch]$RequireCurrentPolicy
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $revisionConfinement = if ([string]::IsNullOrWhiteSpace($RevisionConfinementRoot)) {
        $root
    } else {
        Resolve-FullPath -Path $RevisionConfinementRoot -MustExist -PathType Container
    }
    Assert-NoReparsePoint -Root $revisionConfinement -Path $revisionConfinement
    if ([string]::IsNullOrWhiteSpace($RevisionRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($RevisionConfinementRoot)) { throw 'RevisionConfinementRoot requires an explicit RevisionRoot.' }
        $revisionRoot = Get-RevisionDirectory -ProjectRoot $root -Revision $Revision
    } else {
        $revisionRoot = Assert-PathWithin -Root $revisionConfinement -Path $RevisionRoot
    }
    Resolve-FullPath -Path $revisionRoot -MustExist -PathType Container | Out-Null
    Assert-NoReparsePoint -Root $revisionConfinement -Path $revisionRoot
    $manifestPath = Join-Path $revisionRoot 'manifest.json'
    $databasePath = Join-Path $revisionRoot 'mql5-docs.sqlite'
    $corpusLockPath = Join-Path $revisionRoot 'corpus.lock.json'
    foreach ($immutablePath in @($manifestPath,$databasePath,$corpusLockPath)) { Assert-NoReparsePoint -Root $revisionConfinement -Path $immutablePath }
    $corpusLock = Read-JsonFile -Path $corpusLockPath -Context 'revision corpus lock' -RequireObject
    Get-RevisionJsonField $corpusLock 'sources' Array 'revision corpus lock' | Out-Null
    foreach ($lockSource in $corpusLock.sources) {
        foreach ($name in @('id','filename','sha256')) { Get-RevisionJsonField $lockSource $name String 'revision corpus lock source' | Out-Null }
        Get-RevisionJsonField $lockSource 'expected_topics' Integer 'revision corpus lock source' -Minimum 1 | Out-Null
    }
    if ($null -ne $corpusLock.expected_total_topics) { Get-RevisionJsonField $corpusLock 'expected_total_topics' Integer 'revision corpus lock' -Minimum 1 | Out-Null }
    if ($null -eq $corpusLock.sources -or @($corpusLock.sources).Count -ne 3) { throw 'Revision corpus lock must describe exactly three sources.' }
    $manifest = Read-JsonFile -Path $manifestPath -Context 'revision manifest' -RequireObject
    Assert-RevisionManifestTypes -Manifest $manifest
    $manifestSchema = [int](Get-RequiredJsonProperty $manifest 'schema_version' 'manifest')
    if (@($script:LegacyManifestSchemaVersion,$script:ManifestSchemaVersion) -notcontains $manifestSchema) { throw "Manifest schema_version must be 2 or $script:ManifestSchemaVersion." }
    if ($RequireCurrent -and $manifestSchema -ne $script:ManifestSchemaVersion) { throw "The active revision uses legacy manifest schema $manifestSchema. Run Rebuild-Index.ps1 before continuing." }
    Assert-UtcIsoTimestamp -Value ([string](Get-RequiredJsonProperty $manifest 'indexed_at' 'manifest')) -Context 'manifest indexed_at'
    Assert-UtcIsoTimestamp -Value ([string](Get-RequiredJsonProperty $manifest 'build_timestamp' 'manifest')) -Context 'manifest build_timestamp'
    $database = Get-RequiredJsonProperty $manifest 'database' 'manifest'
    if ([string](Get-RequiredJsonProperty $database 'filename' 'manifest.database') -ne 'mql5-docs.sqlite') { throw 'Manifest database filename is invalid.' }
    $databaseHash = [string](Get-RequiredJsonProperty $database 'sha256' 'manifest.database')
    if ($databaseHash -cnotmatch '^[0-9a-f]{64}$') { throw 'Manifest database SHA-256 is invalid.' }
    Assert-FileSha256 -Path $databasePath -Expected $databaseHash | Out-Null
    if ((Get-FileSystemItemOrFallback -Path $databasePath).Length -ne [int64](Get-RequiredJsonProperty $database 'bytes' 'manifest.database')) { throw 'Manifest database byte count is invalid.' }
    $sources = Get-RequiredJsonProperty $manifest 'sources' 'manifest'
    $hashObject = [pscustomobject]@{}
    $totalTopics = 0
    $totalSections = 0
    foreach ($definition in Get-Mql5CorpusDefinition) {
        $source = Get-RequiredJsonProperty $sources $definition.Id 'manifest.sources'
        $lockEntries = @($corpusLock.sources | Where-Object { [string]$_.id -eq $definition.Id })
        if ($lockEntries.Count -ne 1) { throw "Revision corpus lock must contain exactly one '$($definition.Id)' source." }
        $lockEntry = $lockEntries[0]
        if ([string](Get-RequiredJsonProperty $source 'filename' "manifest.sources.$($definition.Id)") -ne $definition.FileName) { throw "Manifest filename mismatch for '$($definition.Id)'." }
        $hash = [string](Get-RequiredJsonProperty $source 'sha256' "manifest.sources.$($definition.Id)")
        if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid source hash for '$($definition.Id)'." }
        if ([string]$lockEntry.filename -ne $definition.FileName -or [string]$lockEntry.sha256 -cne $hash) { throw "Revision corpus lock does not match manifest source '$($definition.Id)'." }
        $hashObject | Add-Member -NotePropertyName $definition.Id -NotePropertyValue $hash
        $chm = Join-Path $revisionRoot $definition.FileName
        Assert-NoReparsePoint -Root $revisionConfinement -Path $chm
        Assert-FileSha256 -Path $chm -Expected $hash | Out-Null
        if ((Get-FileSystemItemOrFallback -Path $chm).Length -ne [int64](Get-RequiredJsonProperty $source 'bytes' "manifest.sources.$($definition.Id)")) { throw "Source byte count mismatch for '$($definition.Id)'." }
        $topicCount = [int](Get-RequiredJsonProperty $source 'topic_count' "manifest.sources.$($definition.Id)")
        $sectionCount = [int](Get-RequiredJsonProperty $source 'section_count' "manifest.sources.$($definition.Id)")
        if ($RequireCurrentSources) {
            Assert-CurrentCorpusSourceIdentity -Definition $definition -Sha256 $hash -TopicCount $topicCount
        }
        if ($topicCount -lt $definition.TopicCount) { throw "Source '$($definition.Id)' has $topicCount topics; trusted baseline is $($definition.TopicCount)." }
        if ([int]$lockEntry.expected_topics -ne $topicCount) { throw "Revision corpus lock topic count does not match '$($definition.Id)'." }
        if ($sectionCount -lt $topicCount) { throw "Source '$($definition.Id)' section count is invalid." }
        $retrievedAt = [string](Get-RequiredJsonProperty $source 'retrieved_at' "manifest.sources.$($definition.Id)")
        Assert-UtcIsoTimestamp -Value $retrievedAt -Context "manifest.sources.$($definition.Id).retrieved_at"
        foreach ($optionalHeader in @('http_last_modified','http_etag')) {
            $value = Get-RequiredJsonProperty $source $optionalHeader "manifest.sources.$($definition.Id)"
            if ($null -ne $value -and ([string]$value).Length -gt 512) { throw "Manifest $optionalHeader is too long for '$($definition.Id)'." }
        }
        $totalTopics += $topicCount; $totalSections += $sectionCount
    }
    $corpusRevision = Get-CorpusRevision -SourceHashes $hashObject
    $declaredCorpus = [string](Get-RequiredJsonProperty $manifest 'corpus_sha256' 'manifest')
    if ($declaredCorpus -cne $corpusRevision) { throw 'Manifest corpus_sha256 does not match the canonical source hash.' }
    $corpusAlias = $manifest.PSObject.Properties['corpus_revision']
    if ($null -ne $corpusAlias -and $null -ne $corpusAlias.Value -and $corpusAlias.Value -cne $corpusRevision) { throw 'Manifest corpus_revision does not match corpus_sha256.' }
    if ($manifestSchema -eq $script:ManifestSchemaVersion) {
        if ([string](Get-RequiredJsonProperty $manifest 'corpus_revision' 'manifest') -cne $corpusRevision) { throw 'Manifest corpus_revision does not match corpus_sha256.' }
        if ([string](Get-RequiredJsonProperty $manifest 'index_revision' 'manifest') -cne $databaseHash) { throw 'Manifest index_revision must equal database.sha256.' }
        $manifestIndexContract = [string](Get-RequiredJsonProperty $manifest 'index_contract' 'manifest')
        Assert-IndexContract -Contract $manifestIndexContract -RequireCurrent:$RequireCurrent
    }
    $identityAccepted = switch ($IdentityMode) {
        'Corpus' { $Revision -ceq $corpusRevision }
        'Index' { $Revision -ceq $databaseHash }
        default { if ($manifestSchema -eq $script:ManifestSchemaVersion) { $Revision -ceq $databaseHash } else { $Revision -ceq $corpusRevision -or $Revision -ceq $databaseHash } }
    }
    if (-not $identityAccepted) { throw "Revision directory '$Revision' does not match its required $IdentityMode identity." }
    if ([int](Get-RequiredJsonProperty $manifest 'total_topic_count' 'manifest') -ne $totalTopics) { throw 'Manifest total_topic_count does not match its sources.' }
    if ($null -ne $corpusLock.expected_total_topics -and [int]$corpusLock.expected_total_topics -ne $totalTopics) { throw 'Revision corpus lock total does not match its sources.' }
    if ([int](Get-RequiredJsonProperty $manifest 'total_section_count' 'manifest') -ne $totalSections) { throw 'Manifest total_section_count does not match its sources.' }
    foreach ($countName in @('topic_link_count','resolved_topic_link_count','unresolved_topic_link_count')) { if ([int](Get-RequiredJsonProperty $manifest $countName 'manifest') -lt 0) { throw "Manifest $countName is invalid." } }
    if ([int]$manifest.topic_link_count -ne ([int]$manifest.resolved_topic_link_count + [int]$manifest.unresolved_topic_link_count)) { throw 'Manifest topic link counts are inconsistent.' }
    $assetClosure = $null
    if ($manifestSchema -eq $script:ManifestSchemaVersion) {
        $assets = Get-RequiredJsonProperty $manifest 'assets' 'manifest'
        foreach ($countName in @('cataloged_count','exposed_count','excluded_count','occurrence_count','exposed_occurrence_count','total_bytes')) { if ([int64](Get-RequiredJsonProperty $assets $countName 'manifest.assets') -lt 0) { throw "Manifest assets.$countName is invalid." } }
        foreach ($hashName in @('catalog_sha256','tree_sha256','policy_sha256')) { if ([string](Get-RequiredJsonProperty $assets $hashName 'manifest.assets') -cnotmatch '^[0-9a-f]{64}$') { throw "Manifest assets.$hashName is invalid." } }
        if ($RequireCurrentPolicy) {
            Assert-CurrentImagePolicyIdentity -ProjectRoot $root -PolicySha256 ([string]$assets.policy_sha256)
        }
        if ([int]$assets.cataloged_count -ne ([int]$assets.exposed_count + [int]$assets.excluded_count)) { throw 'Manifest asset exposure counts are inconsistent.' }
        if ([int]$assets.exposed_occurrence_count -gt [int]$assets.occurrence_count) { throw 'Manifest topic asset exposure counts are inconsistent.' }
        [int]$sourceAssetCount = 0; [int]$sourceExposedCount = 0; [int]$sourceExcludedCount = 0; [int]$sourceTopicAssetCount = 0; [int]$sourceExposedTopicAssetCount = 0; [int64]$sourceAssetBytes = 0
        foreach ($definition in Get-Mql5CorpusDefinition) {
            $source = Get-RequiredJsonProperty $assets.by_source $definition.Id 'manifest.assets.by_source'
            Assert-ExactJsonProperties -Object $source -Names @('cataloged_count','exposed_count','excluded_count','occurrence_count','exposed_occurrence_count','total_bytes') -Context "manifest.assets.by_source.$($definition.Id)"
            foreach ($countName in @('cataloged_count','exposed_count','excluded_count','occurrence_count','exposed_occurrence_count','total_bytes')) { if ([int64](Get-RequiredJsonProperty $source $countName "manifest.assets.by_source.$($definition.Id)") -lt 0) { throw "Manifest source $countName is invalid for '$($definition.Id)'." } }
            if ([int]$source.cataloged_count -ne ([int]$source.exposed_count + [int]$source.excluded_count)) { throw "Manifest source asset exposure counts are inconsistent for '$($definition.Id)'." }
            $sourceAssetCount += [int]$source.cataloged_count; $sourceExposedCount += [int]$source.exposed_count; $sourceExcludedCount += [int]$source.excluded_count
            $sourceTopicAssetCount += [int]$source.occurrence_count; $sourceExposedTopicAssetCount += [int]$source.exposed_occurrence_count; $sourceAssetBytes += [int64]$source.total_bytes
        }
        if ($sourceAssetCount -ne [int]$assets.cataloged_count -or $sourceExposedCount -ne [int]$assets.exposed_count -or $sourceExcludedCount -ne [int]$assets.excluded_count -or $sourceTopicAssetCount -ne [int]$assets.occurrence_count -or $sourceExposedTopicAssetCount -ne [int]$assets.exposed_occurrence_count -or $sourceAssetBytes -ne [int64]$assets.total_bytes) { throw 'Manifest source asset totals do not match top-level totals.' }
        $assetClosure = Get-RevisionAssetClosure -ProjectRoot $root -RevisionRoot $revisionRoot -Manifest $manifest -ConfinementRoot $revisionConfinement
    }
    return [pscustomobject]@{ Revision = $Revision; CorpusRevision=$corpusRevision; IndexRevision=$databaseHash; ManifestSchemaVersion=$manifestSchema; Root = $revisionRoot; Manifest = $manifest; ManifestPath = $manifestPath; DatabasePath = $databasePath; AssetClosure=$assetClosure }
}

function Assert-ManifestAndCorpus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$RequireCurrent,
        [switch]$RequireCurrentSources,
        [switch]$RequireCurrentPolicy
    )
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $ProjectRoot
    $identityMode = if ([int]$pointer.schema_version -eq 1) { 'Corpus' } else { 'Index' }
    return Assert-Revision -ProjectRoot $ProjectRoot -Revision ([string]$pointer.active_revision) -IdentityMode $identityMode `
        -RequireCurrent:$RequireCurrent -RequireCurrentSources:$RequireCurrentSources -RequireCurrentPolicy:$RequireCurrentPolicy
}

function Copy-DirectoryTreeNoReparse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $sourceFull = Assert-PathWithin -Root $root -Path (Resolve-FullPath -Path $Source -MustExist -PathType Container)
    $destinationFull = Assert-PathWithin -Root $root -Path $Destination
    Assert-NoReparsePoint -Root $root -Path $sourceFull
    $reparseItems = @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Refusing to copy a revision containing reparse points: $($reparseItems[0].FullName)" }
    if (Test-Path -LiteralPath $destinationFull) { throw "Copy destination already exists: $destinationFull" }
    # Lexical confinement alone would follow a junction in the destination's
    # existing ancestors out of the project.
    Assert-NoReparsePoint -Root $root -Path (Split-Path -Parent $destinationFull)
    New-Item -ItemType Directory -Path $destinationFull -ErrorAction Stop | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $sourceFull -Force) { Copy-Item -LiteralPath $item.FullName -Destination $destinationFull -Recurse -Force -ErrorAction Stop }
    return $destinationFull
}

function Install-LegacyRevisionIndexIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$LegacyCorpusRevision
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $legacy = Assert-Revision -ProjectRoot $root -Revision $LegacyCorpusRevision -IdentityMode Corpus
    if ([int]$legacy.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { throw 'Only manifest-schema-2 revisions can be migrated from corpus identity.' }
    $indexRevision = [string]$legacy.IndexRevision
    $destination = Get-RevisionDirectory -ProjectRoot $root -Revision $indexRevision
    if ($indexRevision -ceq $LegacyCorpusRevision) { return $legacy }
    if (Test-Path -LiteralPath $destination) { return Assert-Revision -ProjectRoot $root -Revision $indexRevision -IdentityMode Index }
    $revisionsRoot = Resolve-FullPath -Path (Join-Path $root 'revisions') -MustExist -PathType Container
    Assert-NoReparsePoint -Root $root -Path $revisionsRoot
    $temporary = Assert-PathWithin -Root $revisionsRoot -Path (Join-Path $revisionsRoot ('.legacy-index-' + [Guid]::NewGuid().ToString('N')))
    try {
        Copy-DirectoryTreeNoReparse -ProjectRoot $root -Source $legacy.Root -Destination $temporary | Out-Null
        Assert-Revision -ProjectRoot $root -Revision $indexRevision -RevisionRoot $temporary -IdentityMode Index | Out-Null
        try {
            [IO.Directory]::Move($temporary, $destination)
        } catch {
            if (Test-Path -LiteralPath $destination -PathType Container) {
                try {
                    return Assert-Revision -ProjectRoot $root -Revision $indexRevision -IdentityMode Index
                } catch {
                    throw "A conflicting revision destination appeared during legacy migration: $destination"
                }
            }
            throw
        }
        return Assert-Revision -ProjectRoot $root -Revision $indexRevision -IdentityMode Index
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Container) { Remove-SafeDirectory -ConfinementRoot $revisionsRoot -Path $temporary }
    }
}

function Convert-ActiveRevisionPointerToSchema2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateScript({ $_ -match '^[0-9a-f]{64}$' })][string[]]$AdditionalValidatedRevisions = @()
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $additionalChangedPaths = @()
    foreach ($revision in $AdditionalValidatedRevisions) {
        $validatedAdditional = Assert-Revision -ProjectRoot $root -Revision $revision -IdentityMode Index -RequireCurrent
        $reportPath = Join-Path $validatedAdditional.Root 'stage-report.json'
        Assert-StagedRevisionReport -Path $reportPath -ExpectedRevision $revision | Out-Null
        $additionalChangedPaths += $reportPath.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$pointer.schema_version -eq $script:ActivePointerSchemaVersion) {
        Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index | Out-Null
        if ($null -ne $pointer.previous_revision) { Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.previous_revision) -IdentityMode Index | Out-Null }
        Update-ManagedChecksumsIfPresent -ProjectRoot $root -ChangedRelativePaths $additionalChangedPaths -AllowLegacyActive
        return $pointer
    }
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    $active = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision ([string]$pointer.active_revision)
    $previousIndex = $null
    if ($null -ne $pointer.previous_revision) {
        $previous = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision ([string]$pointer.previous_revision)
        $previousIndex = [string]$previous.IndexRevision
    }
    Set-ActiveRevisionPointer -ProjectRoot $root -ActiveRevision ([string]$active.IndexRevision) -PreviousRevision $previousIndex -SchemaVersion 2 -ActivatedAt ([string]$pointer.activated_at) | Out-Null
    $migrated = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$migrated.schema_version -ne 2 -or [string]$migrated.active_revision -cne [string]$active.IndexRevision) { throw 'Active pointer migration did not complete atomically.' }
    Update-ManagedChecksumsIfPresent -ProjectRoot $root -ChangedRelativePaths $additionalChangedPaths -AllowLegacyActive
    return $migrated
}

function Get-UpdateStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$AllowMissing)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $path = Join-Path $root 'maintenance\update-status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { if ($AllowMissing) { return $null }; throw "Update status is missing: $path" }
    $status = Read-JsonFile -Path $path -Context 'update status' -RequireObject
    $schemaVersion = Get-RevisionJsonField $status 'schema_version' Integer 'update status' -Minimum 1
    foreach ($name in @('checked_at','status','active_revision')) { Get-RevisionJsonField $status $name String 'update status' | Out-Null }
    foreach ($name in @('candidate_revision','message')) { Get-RevisionJsonField $status $name NullableString 'update status' | Out-Null }
    if ($schemaVersion -eq 1) {
        Assert-ExactJsonProperties -Object $status -Names @('schema_version','checked_at','status','active_revision','candidate_revision','message') -Context 'legacy update status'
    } elseif ($schemaVersion -eq 2) {
        Assert-ExactJsonProperties -Object $status -Names @('schema_version','checked_at','status','active_revision','active_corpus_revision','candidate_revision','candidate_corpus_revision','message') -Context 'update status'
        Get-RevisionJsonField $status 'active_corpus_revision' String 'update status' | Out-Null
        Get-RevisionJsonField $status 'candidate_corpus_revision' NullableString 'update status' | Out-Null
        if ([string]$status.active_corpus_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Update status active_corpus_revision is invalid.' }
        if ($null -ne $status.candidate_corpus_revision -and [string]$status.candidate_corpus_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Update status candidate_corpus_revision is invalid.' }
    } else { throw 'Update status schema_version must be 1 or 2.' }
    Assert-UtcIsoTimestamp -Value ([string]$status.checked_at) -Context 'update status checked_at'
    if (@('up-to-date','different-revision-available','check-unavailable') -notcontains [string]$status.status) { throw 'Update status value is invalid.' }
    if ([string]$status.active_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Update status active_revision is invalid.' }
    if ($null -ne $status.candidate_revision -and [string]$status.candidate_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Update status candidate_revision is invalid.' }
    if ($null -eq $status.message -or ([string]$status.message).Length -gt $script:MaximumStatusMessageChars -or [string]$status.message -match '[\x00-\x1f\x7f]') { throw 'Update status message is invalid.' }
    return $status
}

function Set-UpdateStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('up-to-date','different-revision-available','check-unavailable')][string]$Status,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ActiveRevision,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ActiveCorpusRevision,
        [AllowNull()][AllowEmptyString()][string]$CandidateRevision,
        [AllowNull()][AllowEmptyString()][string]$CandidateCorpusRevision,
        [Parameter(Mandatory)][ValidateLength(1,500)][string]$Message
    )
    if ($Message -match '[\x00-\x1f\x7f]') { throw 'Update status Message must not contain control characters.' }
    $candidateValue = if ([string]::IsNullOrEmpty($CandidateRevision)) { $null } else { $CandidateRevision }
    if ($null -ne $candidateValue -and $candidateValue -cnotmatch '^[0-9a-f]{64}$') { throw 'CandidateRevision must be null or a lowercase SHA-256 digest.' }
    $candidateCorpusValue = if ([string]::IsNullOrEmpty($CandidateCorpusRevision)) { $null } else { $CandidateCorpusRevision }
    if ($null -ne $candidateCorpusValue -and $candidateCorpusValue -cnotmatch '^[0-9a-f]{64}$') { throw 'CandidateCorpusRevision must be null or a lowercase SHA-256 digest.' }
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $value = [ordered]@{
        schema_version=2; checked_at=[DateTime]::UtcNow.ToString('O'); status=$Status
        active_revision=$ActiveRevision; active_corpus_revision=$ActiveCorpusRevision
        candidate_revision=$candidateValue; candidate_corpus_revision=$candidateCorpusValue; message=$Message
    }
    Write-JsonAtomic -Path (Join-Path $root 'maintenance\update-status.json') -Value $value -ConfinementRoot $root
    return Get-UpdateStatus -ProjectRoot $root
}

function Set-StagedRevisionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CorpusRevision,
        [AllowNull()][AllowEmptyString()][ValidateScript({ [string]::IsNullOrEmpty([string]$_) -or $_ -match '^[0-9a-f]{64}$' })][string]$BaseRevision,
        [AllowNull()][AllowEmptyString()][ValidateScript({ [string]::IsNullOrEmpty([string]$_) -or $_ -match '^[0-9a-f]{64}$' })][string]$BaseCorpusRevision,
        [Parameter(Mandatory)][object]$SourceTopicCounts,
        [Parameter(Mandatory)][object]$Changes,
        [Parameter(Mandatory)][object]$AssetChanges,
        [Parameter(Mandatory)][object]$RequiredRankings
    )
    if ([string]::IsNullOrEmpty($BaseRevision) -ne [string]::IsNullOrEmpty($BaseCorpusRevision)) { throw 'Stage report base index and corpus revisions must both be set or both be null.' }
    if (-not [string]::IsNullOrEmpty($BaseRevision) -and $Revision -ceq $BaseRevision) { throw 'A staged revision must differ from its validation base.' }
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $revisionRoot = Get-RevisionDirectory -ProjectRoot $root -Revision $Revision
    Resolve-FullPath -Path $revisionRoot -MustExist -PathType Container | Out-Null
    Assert-NoReparsePoint -Root $root -Path $revisionRoot
    $value = [ordered]@{
        schema_version=3; index_revision=$Revision; corpus_revision=$CorpusRevision
        base_index_revision=if ([string]::IsNullOrEmpty($BaseRevision)) { $null } else { $BaseRevision }
        base_corpus_revision=if ([string]::IsNullOrEmpty($BaseCorpusRevision)) { $null } else { $BaseCorpusRevision }
        staged_at=[DateTime]::UtcNow.ToString('O'); validation_passed=$true
        source_topic_counts=$SourceTopicCounts; changes=$Changes; asset_changes=$AssetChanges; required_rankings=$RequiredRankings
    }
    $path = Join-Path $revisionRoot 'stage-report.json'
    Write-JsonAtomic -Path $path -Value $value -ConfinementRoot $revisionRoot
    return Read-JsonFile -Path $path -Context 'stage report' -RequireObject
}

function Assert-StagedRevisionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRevision
    )
    $report = Read-JsonFile -Path $Path -Context 'stage report' -RequireObject
    Assert-ExactJsonProperties -Object $report -Names @('schema_version','index_revision','corpus_revision','base_index_revision','base_corpus_revision','staged_at','validation_passed','source_topic_counts','changes','asset_changes','required_rankings') -Context 'stage report'
    Assert-StagedRevisionReportTypes -Report $report
    if ([int]$report.schema_version -ne 3 -or [string]$report.index_revision -cne $ExpectedRevision -or $report.validation_passed -isnot [bool] -or -not [bool]$report.validation_passed) { throw 'Stage report is not approved for this index revision.' }
    if ([string]$report.corpus_revision -cnotmatch '^[0-9a-f]{64}$') { throw 'Stage report corpus_revision is invalid.' }
    if (($null -eq $report.base_index_revision) -ne ($null -eq $report.base_corpus_revision)) { throw 'Stage report base revisions must both be set or both be null.' }
    foreach ($name in @('base_index_revision','base_corpus_revision')) { if ($null -ne $report.PSObject.Properties[$name].Value -and [string]$report.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Stage report $name is invalid." } }
    Assert-ExactJsonProperties -Object $report.asset_changes -Names @('added_count','removed_count','changed_count','added_asset_ids','removed_asset_ids','changed_asset_ids','added_truncated','removed_truncated','changed_truncated','base_cataloged_count','candidate_cataloged_count','cataloged_delta','base_exposed_count','candidate_exposed_count','exposed_delta','candidate_excluded_count','base_occurrence_count','candidate_occurrence_count','occurrence_delta','base_exposed_occurrence_count','candidate_exposed_occurrence_count','exposed_occurrence_delta','candidate_total_bytes','unsupported_count','oversized_count','unresolved_count','unclassified_count','reduction_requires_review') -Context 'stage report asset_changes'
    foreach ($name in @('added_count','removed_count','changed_count','base_cataloged_count','candidate_cataloged_count','base_exposed_count','candidate_exposed_count','candidate_excluded_count','base_occurrence_count','candidate_occurrence_count','base_exposed_occurrence_count','candidate_exposed_occurrence_count','candidate_total_bytes','unsupported_count','oversized_count','unresolved_count','unclassified_count')) {
        $value = [int64]$report.asset_changes.PSObject.Properties[$name].Value
        if ($value -lt 0) { throw "Stage report asset_changes.$name must not be negative." }
    }
    foreach ($name in @('unsupported_count','oversized_count','unresolved_count','unclassified_count')) { if ([int]$report.asset_changes.PSObject.Properties[$name].Value -ne 0) { throw "Stage report contains unresolved asset validation failures: $name." } }
    Assert-UtcIsoTimestamp -Value ([string]$report.staged_at) -Context 'stage report staged_at'
    return $report
}

function Assert-LegacyStagedRevisionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedCorpusRevision
    )
    $full = Resolve-FullPath -Path $Path -MustExist -PathType Leaf
    if ((Get-FileSystemItemOrFallback -Path $full).Length -gt 2097152) { throw 'Legacy stage report exceeds the 2 MiB validation limit.' }
    $report = Read-JsonFile -Path $full -Context 'legacy stage report' -RequireObject
    Assert-ExactJsonProperties -Object $report -Names @('schema_version','revision','base_revision','staged_at','validation_passed','source_topic_counts','changes','required_rankings') -Context 'legacy stage report'
    Assert-StagedRevisionReportTypes -Report $report -Legacy
    if ([int]$report.schema_version -ne 1 -or [string]$report.revision -cne $ExpectedCorpusRevision -or $report.validation_passed -isnot [bool] -or -not [bool]$report.validation_passed) { throw 'Legacy stage report is not approved for this corpus revision.' }
    if ([string]$report.base_revision -cnotmatch '^[0-9a-f]{64}$' -or [string]$report.base_revision -ceq $ExpectedCorpusRevision) { throw 'Legacy stage report base_revision is invalid.' }
    Assert-UtcIsoTimestamp -Value ([string]$report.staged_at) -Context 'legacy stage report staged_at'

    Assert-ExactJsonProperties -Object $report.source_topic_counts -Names @('mql5','mql5book','neuronetworksbook') -Context 'legacy stage report source_topic_counts'
    foreach ($source in @('mql5','mql5book','neuronetworksbook')) {
        $counts = $report.source_topic_counts.PSObject.Properties[$source].Value
        Assert-ExactJsonProperties -Object $counts -Names @('base','candidate','delta') -Context "legacy stage report source_topic_counts.$source"
        $base = [int64]$counts.base; $candidate = [int64]$counts.candidate; $delta = [int64]$counts.delta
        if ($base -lt 0 -or $candidate -lt 0 -or $delta -ne ($candidate - $base)) { throw "Legacy stage report source_topic_counts.$source is inconsistent." }
    }
    Assert-ExactJsonProperties -Object $report.changes -Names @('added_count','removed_count','changed_count','added_topic_ids','removed_topic_ids','changed_topic_ids','added_truncated','removed_truncated','changed_truncated') -Context 'legacy stage report changes'
    foreach ($name in @('added_count','removed_count','changed_count')) { if ([int64]$report.changes.PSObject.Properties[$name].Value -lt 0) { throw "Legacy stage report changes.$name must not be negative." } }
    foreach ($name in @('added_truncated','removed_truncated','changed_truncated')) { if ($report.changes.PSObject.Properties[$name].Value -isnot [bool]) { throw "Legacy stage report changes.$name must be Boolean." } }
    foreach ($name in @('added_topic_ids','removed_topic_ids','changed_topic_ids')) {
        $ids = @($report.changes.PSObject.Properties[$name].Value)
        if ($ids.Count -gt 200) { throw "Legacy stage report changes.$name exceeds its bound." }
        foreach ($id in $ids) { if ([string]::IsNullOrWhiteSpace([string]$id) -or ([string]$id).Length -gt 500 -or [string]$id -match '[\x00-\x1f\x7f]') { throw "Legacy stage report changes.$name contains an invalid topic ID." } }
    }
    Assert-ExactJsonProperties -Object $report.required_rankings -Names @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer') -Context 'legacy stage report required_rankings'
    foreach ($query in @('OnTick','PositionSelectByTicket','OrderSend','CopyBuffer')) {
        $ranking = $report.required_rankings.PSObject.Properties[$query].Value
        Assert-ExactJsonProperties -Object $ranking -Names @('title','source') -Context "legacy stage report required_rankings.$query"
        if ([string]::IsNullOrWhiteSpace([string]$ranking.title) -or ([string]$ranking.title).Length -gt 500 -or @('mql5','mql5book','neuronetworksbook') -cnotcontains [string]$ranking.source) { throw "Legacy stage report required_rankings.$query is invalid." }
    }
    return $report
}

function Get-RevisionTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$AllowMissing)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $path = Join-Path $root 'maintenance\revision-transition.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "Revision transition journal is missing: $path"
    }
    $transition = Read-JsonFile -Path $path -Context 'revision transition journal' -RequireObject
    $schemaVersion = Get-RevisionJsonField $transition 'schema_version' Integer 'revision transition journal' -Minimum 1
    foreach ($name in @('operation','from_revision','to_revision','started_at')) { Get-RevisionJsonField $transition $name String 'revision transition journal' | Out-Null }
    if ($schemaVersion -eq 1) {
        Assert-ExactJsonProperties -Object $transition -Names @('schema_version','operation','from_revision','to_revision','started_at') -Context 'legacy revision transition journal'
    } elseif ($schemaVersion -eq 2) {
        Assert-ExactJsonProperties -Object $transition -Names @('schema_version','operation','from_revision','from_corpus_revision','to_revision','to_corpus_revision','started_at') -Context 'revision transition journal'
        foreach ($name in @('from_corpus_revision','to_corpus_revision')) { Get-RevisionJsonField $transition $name String 'revision transition journal' | Out-Null }
        foreach ($name in @('from_corpus_revision','to_corpus_revision')) { if ([string]$transition.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{64}$') { throw "Revision transition $name is invalid." } }
    } else { throw 'Revision transition schema_version must be 1 or 2.' }
    if (@('apply','rollback') -notcontains [string]$transition.operation) { throw 'Revision transition operation is invalid.' }
    $from = [string]$transition.from_revision; $to = [string]$transition.to_revision
    if ($from -cnotmatch '^[0-9a-f]{64}$' -or $to -cnotmatch '^[0-9a-f]{64}$') { throw 'Revision transition hashes must be lowercase SHA-256 digests.' }
    if ($from -ceq $to) { throw 'Revision transition revisions must differ.' }
    Assert-UtcIsoTimestamp -Value ([string]$transition.started_at) -Context 'revision transition started_at'
    return $transition
}

function Assert-NoPendingRevisionTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $transition = Get-RevisionTransition -ProjectRoot $ProjectRoot -AllowMissing
    if ($null -ne $transition) {
        $article = if ([string]$transition.operation -eq 'apply') { 'An' } else { 'A' }
        throw "$article $($transition.operation) transition from $($transition.from_revision) to $($transition.to_revision) is incomplete. Recover that transition before continuing."
    }
}

function Assert-NoPendingRevisionStageInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $path = Assert-PathWithin -Root $root -Path (Join-Path $root 'maintenance\revision-stage.json')
    Assert-NoReparsePoint -Root $root -Path $path
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Get-FileSystemItemOrFallback -Path $path).Length -gt 2097152) { throw 'Pending revision-stage journal exceeds the 2 MiB safety limit.' }
        throw 'A revision stage install is incomplete. Recover it with the matching Rebuild-Index.ps1 -Stage or Update-Documentation.ps1 -Stage operation before continuing.'
    }
    if (Test-Path -LiteralPath $path) { throw 'Revision-stage journal path is not a regular file.' }
}

function Start-RevisionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('apply','rollback')][string]$Operation,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$FromRevision,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ToRevision
    )
    if ($FromRevision -ceq $ToRevision) { throw 'Revision transition revisions must differ.' }
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    Assert-NoPendingRevisionStageInstall -ProjectRoot $root
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    $fromValidated = Assert-Revision -ProjectRoot $root -Revision $FromRevision -IdentityMode Index
    $toValidated = Assert-Revision -ProjectRoot $root -Revision $ToRevision -IdentityMode Index
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$pointer.schema_version -ne 2) { throw 'Revision transitions require an index-identity active pointer. Migrate the legacy pointer first.' }
    if ([string]$pointer.active_revision -cne $FromRevision) { throw 'The active revision changed before the transition could start.' }
    if ($Operation -eq 'rollback' -and [string]$pointer.previous_revision -cne $ToRevision) { throw 'The requested rollback target is not the recorded previous revision.' }
    $value = [ordered]@{
        schema_version = 2
        operation = $Operation
        from_revision = $FromRevision
        from_corpus_revision = [string]$fromValidated.CorpusRevision
        to_revision = $ToRevision
        to_corpus_revision = [string]$toValidated.CorpusRevision
        started_at = [DateTime]::UtcNow.ToString('O')
    }
    Write-JsonAtomic -Path (Join-Path $root 'maintenance\revision-transition.json') -Value $value -ConfinementRoot $root
    return Get-RevisionTransition -ProjectRoot $root
}

function Complete-RevisionTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $transition = Get-RevisionTransition -ProjectRoot $root
    $from = [string]$transition.from_revision; $to = [string]$transition.to_revision
    $legacyTransition = [int]$transition.schema_version -eq 1
    $identityMode = if ($legacyTransition) { 'Corpus' } else { 'Index' }
    $fromValidated = Assert-Revision -ProjectRoot $root -Revision $from -IdentityMode $identityMode
    $toValidated = Assert-Revision -ProjectRoot $root -Revision $to -IdentityMode $identityMode
    if (-not $legacyTransition) {
        if ([string]$transition.from_corpus_revision -cne [string]$fromValidated.CorpusRevision -or [string]$transition.to_corpus_revision -cne [string]$toValidated.CorpusRevision) { throw 'Revision transition corpus identities do not match the verified revisions.' }
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ($legacyTransition) {
        if ([int]$pointer.schema_version -eq 1) {
            if ([string]$pointer.active_revision -ceq $from) {
                Set-ActiveRevisionPointer -ProjectRoot $root -ActiveRevision $to -PreviousRevision $from -SchemaVersion 1 | Out-Null
            } elseif ([string]$pointer.active_revision -ceq $to -and [string]$pointer.previous_revision -ceq $from) {
                # Recovery after the legacy pointer switch.
            } else {
                throw "Legacy revision transition conflicts with active.json. Expected active '$from', or active '$to' with previous '$from'."
            }
            $legacyPostSwitch = Get-ActiveRevisionPointer -ProjectRoot $root
            $toIndex = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision $to
            $fromIndex = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision $from
            Set-ActiveRevisionPointer -ProjectRoot $root -ActiveRevision ([string]$toIndex.IndexRevision) -PreviousRevision ([string]$fromIndex.IndexRevision) -SchemaVersion 2 -ActivatedAt ([string]$legacyPostSwitch.activated_at) | Out-Null
            $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
        } elseif ([int]$pointer.schema_version -eq 2) {
            $toIndex = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision $to
            $fromIndex = Install-LegacyRevisionIndexIdentity -ProjectRoot $root -LegacyCorpusRevision $from
            if ([string]$pointer.active_revision -cne [string]$toIndex.IndexRevision -or [string]$pointer.previous_revision -cne [string]$fromIndex.IndexRevision) {
                throw 'Migrated legacy transition conflicts with the index-identity active pointer.'
            }
        } else { throw 'Legacy revision transition schema conflicts with the active pointer schema.' }

        if ([string]$transition.operation -eq 'apply') {
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision ([string]$toIndex.IndexRevision) -ActiveCorpusRevision $to -CandidateRevision ([string]$toIndex.IndexRevision) -CandidateCorpusRevision $to -Message 'The interrupted legacy apply transition was recovered and migrated to index identity.' | Out-Null
        } else {
            Set-UpdateStatus -ProjectRoot $root -Status 'different-revision-available' -ActiveRevision ([string]$toIndex.IndexRevision) -ActiveCorpusRevision $to -CandidateRevision ([string]$fromIndex.IndexRevision) -CandidateCorpusRevision $from -Message 'The interrupted legacy rollback was recovered and migrated to index identity.' | Out-Null
        }
        Update-ManagedChecksumsIfPresent -ProjectRoot $root -AllowLegacyActive
    } else {
        if ([int]$pointer.schema_version -ne 2) { throw 'Revision transition schema conflicts with the active pointer schema.' }
        if ([string]$pointer.active_revision -ceq $from) {
            Set-ActiveRevisionPointer -ProjectRoot $root -ActiveRevision $to -PreviousRevision $from -SchemaVersion 2 | Out-Null
        } elseif ([string]$pointer.active_revision -ceq $to -and [string]$pointer.previous_revision -ceq $from) {
            # Recovery after the atomic pointer switch: preserve the pointer and its activation timestamp.
        } else {
            throw "Revision transition conflicts with active.json. Expected active '$from', or active '$to' with previous '$from'."
        }
        if ([string]$transition.operation -eq 'apply') {
            Set-UpdateStatus -ProjectRoot $root -Status 'up-to-date' -ActiveRevision $to -ActiveCorpusRevision ([string]$toValidated.CorpusRevision) -CandidateRevision $to -CandidateCorpusRevision ([string]$toValidated.CorpusRevision) -Message 'The staged verified index revision was validated and activated locally.' | Out-Null
        } else {
            Set-UpdateStatus -ProjectRoot $root -Status 'different-revision-available' -ActiveRevision $to -ActiveCorpusRevision ([string]$toValidated.CorpusRevision) -CandidateRevision $from -CandidateCorpusRevision ([string]$fromValidated.CorpusRevision) -Message 'The previous verified local index revision was reactivated; the replaced revision remains available.' | Out-Null
        }
        $toRequiresCompatibilityValidation = [int]$toValidated.ManifestSchemaVersion -ne $script:ManifestSchemaVersion -or [string]$toValidated.Manifest.index_contract -cne $script:IndexContract
        Update-ManagedChecksumsIfPresent -ProjectRoot $root -AllowLegacyActive:$toRequiresCompatibilityValidation
    }
    return $transition
}

function Clear-RevisionTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][object]$ExpectedTransition)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $actual = Get-RevisionTransition -ProjectRoot $root
    foreach ($name in @($actual.PSObject.Properties.Name)) {
        if ($null -eq $ExpectedTransition.PSObject.Properties[$name]) { throw 'Expected transition content is incomplete.' }
        if ([string]$actual.PSObject.Properties[$name].Value -cne [string]$ExpectedTransition.PSObject.Properties[$name].Value) {
            throw 'Refusing to clear a revision transition journal that changed after completion.'
        }
    }
    $path = Assert-PathWithin -Root $root -Path (Join-Path $root 'maintenance\revision-transition.json')
    Assert-NoReparsePoint -Root $root -Path $path
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Invoke-OfficialChmDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateRange(1,104857600)][int64]$MinimumBytes,
        [Parameter(Mandatory)][ValidateRange(102400,536870912)][int64]$MaximumBytes,
        [ValidateRange(5,600)][int]$TimeoutSeconds = 120,
        [Parameter(DontShow)][hashtable]$InternalTestHooks
    )
    if ($null -ne $InternalTestHooks) {
        $unexpectedHooks = @($InternalTestHooks.Keys | Where-Object { [string]$_ -cne 'GetResponse' })
        if ($unexpectedHooks.Count -gt 0 -or -not ($InternalTestHooks['GetResponse'] -is [scriptblock])) {
            throw 'Official CHM download test hooks are invalid.'
        }
    }
    if ($Uri.Scheme -ne 'https' -or $Uri.IdnHost -cne 'www.mql5.com' -or (-not $Uri.IsDefaultPort -and $Uri.Port -ne 443) -or -not [string]::IsNullOrEmpty($Uri.UserInfo) -or -not $Uri.AbsolutePath.EndsWith('.chm', [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing non-official CHM URI: $Uri" }
    $target = Resolve-FullPath -Path $Destination
    $parent = Split-Path -Parent $target
    Resolve-FullPath -Path $parent -MustExist -PathType Container | Out-Null
    if (Test-Path -LiteralPath $target) { throw "Download destination already exists: $target" }

    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = $null
    $client = $null
    if ($null -eq $InternalTestHooks) {
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
        $handler.UseCookies = $false
        if ($handler.PSObject.Properties.Name -contains 'SslProtocols') {
            $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
        }
        $client = New-Object Net.Http.HttpClient($handler, $true)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    }

    $deadline = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSeconds))
    $current = $Uri
    [int]$redirects = 0
    try {
        while ($true) {
            $request = $null
            $httpResponse = $null
            $testResponse = $null
            $responseStream = $null
            try {
                if ($null -eq $InternalTestHooks) {
                    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $current)
                    [void]$request.Headers.UserAgent.ParseAdd('mql5-chm-mcp/1.3.13')
                    try {
                        $httpResponse = $client.SendAsync(
                            $request,
                            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                            $deadline.Token
                        ).GetAwaiter().GetResult()
                    } catch {
                        throw "Official CHM download failed for '$current': $($_.Exception.Message)"
                    }
                    $code = [int]$httpResponse.StatusCode
                    $location = $httpResponse.Headers.Location
                } else {
                    try { $testResponse = & $InternalTestHooks.GetResponse $current $deadline.Token }
                    catch { throw "Official CHM download failed for '$current': $($_.Exception.Message)" }
                    if ($null -eq $testResponse) {
                        throw "Official CHM download failed for '$current': the test response was null."
                    }
                    $code = [int]$testResponse.StatusCode
                    $location = $testResponse.Headers['Location']
                }

                if ($code -ge 300 -and $code -lt 400) {
                    if ($redirects -ge 5) { throw 'Official CHM download exceeded the redirect limit.' }
                    if ([string]::IsNullOrWhiteSpace([string]$location)) {
                        throw "Redirect from '$current' has no Location header."
                    }
                    $next = New-Object Uri($current, [string]$location)
                    if ($next.Scheme -ne 'https' -or $next.IdnHost -cne 'www.mql5.com' -or
                        (-not $next.IsDefaultPort -and $next.Port -ne 443) -or
                        -not [string]::IsNullOrEmpty($next.UserInfo) -or
                        -not $next.AbsolutePath.EndsWith('.chm', [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing redirect outside the official www.mql5.com CHM paths: $next"
                    }
                    $current = $next
                    $redirects++
                    continue
                }
                if ($code -ne 200) { throw "Official CHM download returned HTTP $code for '$current'." }

                if ($null -eq $InternalTestHooks) {
                    if ($null -eq $httpResponse.Content) { throw 'Official CHM download returned no response content.' }
                    if ($httpResponse.Content.Headers.ContentEncoding.Count -ne 0) {
                        throw 'Official CHM download unexpectedly used content encoding.'
                    }
                    $contentLength = $httpResponse.Content.Headers.ContentLength
                    $lastModified = if ($httpResponse.Content.Headers.Contains('Last-Modified')) {
                        [string](@($httpResponse.Content.Headers.GetValues('Last-Modified'))[0])
                    } else { $null }
                    $etag = if ($null -eq $httpResponse.Headers.ETag) { $null } else { [string]$httpResponse.Headers.ETag }
                    $responseUri = $current
                    $responseStream = $httpResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                } else {
                    $contentLength = [int64]$testResponse.ContentLength
                    $lastModified = if ([string]::IsNullOrWhiteSpace($testResponse.Headers['Last-Modified'])) { $null } else { [string]$testResponse.Headers['Last-Modified'] }
                    $etag = if ([string]::IsNullOrWhiteSpace($testResponse.Headers['ETag'])) { $null } else { [string]$testResponse.Headers['ETag'] }
                    $responseUri = [uri]$testResponse.ResponseUri
                    $responseStream = $testResponse.GetResponseStream()
                }

                if ($responseUri.Scheme -ne 'https' -or $responseUri.IdnHost -cne 'www.mql5.com' -or
                    (-not $responseUri.IsDefaultPort -and $responseUri.Port -ne 443)) {
                    throw "Final download endpoint is not HTTPS www.mql5.com: $responseUri"
                }
                if ($null -eq $responseStream) { throw 'Official CHM download returned no response stream.' }
                if ($null -ne $contentLength -and [int64]$contentLength -ge 0 -and
                    ([int64]$contentLength -lt $MinimumBytes -or [int64]$contentLength -gt $MaximumBytes)) {
                    throw "Official CHM Content-Length is outside the allowed range: $contentLength"
                }

                $downloadSha = [Security.Cryptography.SHA256]::Create()
                try {
                    $written = Copy-StreamToFileBounded `
                        -Stream $responseStream `
                        -Destination $target `
                        -MaximumBytes $MaximumBytes `
                        -CancellationToken $deadline.Token `
                        -HashAlgorithm $downloadSha
                    $sha256 = ([BitConverter]::ToString($downloadSha.Hash)).Replace('-','').ToLowerInvariant()
                } finally {
                    $downloadSha.Dispose()
                }
                if ($written -lt $MinimumBytes) { throw "Official CHM download is too small: $written bytes." }

                $deadline.Token.ThrowIfCancellationRequested()
                $signature = New-Object byte[] 4
                $verify = [IO.File]::OpenRead($target)
                try {
                    if ($verify.Read($signature,0,4) -ne 4 -or
                        [Text.Encoding]::ASCII.GetString($signature) -ne 'ITSF') {
                        throw 'Downloaded file is not a compiled HTML Help file.'
                    }
                } finally { $verify.Dispose() }
                $deadline.Token.ThrowIfCancellationRequested()
                return [pscustomobject]@{
                    Path=$target
                    Sha256=$sha256
                    Bytes=$written
                    HttpLastModified=$lastModified
                    HttpEtag=$etag
                    RetrievedAt=[DateTime]::UtcNow.ToString('O')
                    FinalUri=[string]$responseUri
                }
            } finally {
                if ($null -ne $responseStream) { $responseStream.Dispose() }
                if ($null -ne $httpResponse) { $httpResponse.Dispose() }
                if ($null -ne $testResponse) { $testResponse.Dispose() }
                if ($null -ne $request) { $request.Dispose() }
            }
        }
    } catch {
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
        if ($deadline.IsCancellationRequested) {
            throw "Official CHM download exceeded its $TimeoutSeconds-second deadline."
        }
        throw
    } finally {
        if ($null -ne $client) { $client.Dispose() }
        $deadline.Dispose()
    }
}

function Get-ValidatedRevisionChecksumFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Revision,
        [ValidateSet('Corpus','Index')][string]$IdentityMode = 'Index',
        [switch]$AllowLegacy
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $validated = Assert-Revision -ProjectRoot $root -Revision $Revision -IdentityMode $IdentityMode -RequireCurrent:(-not $AllowLegacy)
    $revisionRoot = Resolve-FullPath -Path $validated.Root -MustExist -PathType Container
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('manifest.json','mql5-docs.sqlite','mql5.chm','mql5book.chm','neuronetworksbook.chm','corpus.lock.json')) {
        [void]$allowed.Add($name)
    }
    if ([int]$validated.ManifestSchemaVersion -eq $script:ManifestSchemaVersion) {
        foreach ($entry in @($validated.AssetClosure.Entries)) { [void]$allowed.Add(([string]$entry.StorageKey).Replace('/','\')) }
        $stageReportPath = Join-Path $revisionRoot 'stage-report.json'
        if (Test-Path -LiteralPath $stageReportPath -PathType Leaf) {
            $report = Assert-StagedRevisionReport -Path $stageReportPath -ExpectedRevision $Revision
            if ([string]$report.corpus_revision -cne [string]$validated.CorpusRevision) { throw "Stage report corpus revision does not match revision '$Revision'." }
            [void]$allowed.Add('stage-report.json')
        }
    } elseif ([int]$validated.ManifestSchemaVersion -eq $script:LegacyManifestSchemaVersion) {
        if (-not $AllowLegacy) { throw "Legacy revision '$Revision' requires explicit legacy validation." }
        $stageReportPath = Join-Path $revisionRoot 'stage-report.json'
        if (Test-Path -LiteralPath $stageReportPath -PathType Leaf) {
            Assert-LegacyStagedRevisionReport -Path $stageReportPath -ExpectedCorpusRevision ([string]$validated.CorpusRevision) | Out-Null
            [void]$allowed.Add('stage-report.json')
        }
    }
    $reparseItems = @(Get-ChildItem -LiteralPath $revisionRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Revision '$Revision' contains a reparse point: $($reparseItems[0].FullName)" }
    $files = @(Get-ChildItem -LiteralPath $revisionRoot -Recurse -File -Force)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($revisionRoot.TrimEnd('\','/').Length).TrimStart('\','/')
        if (-not $allowed.Contains($relative)) { throw "Revision '$Revision' contains an unexpected immutable file: $relative" }
    }
    foreach ($relative in $allowed) {
        if (-not (Test-Path -LiteralPath (Join-Path $revisionRoot $relative) -PathType Leaf)) { throw "Revision '$Revision' is missing immutable file '$relative'." }
    }
    return @($files | Sort-Object FullName)
}

function Get-ValidatedLegacyIndexCopyChecksumExceptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string[]]$CorpusRevisions
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($corpusRevision in @($CorpusRevisions | Select-Object -Unique)) {
        if ($corpusRevision -cnotmatch '^[0-9a-f]{64}$') { throw 'Legacy copy recovery requires lowercase corpus revisions.' }
        $legacy = Assert-Revision -ProjectRoot $root -Revision $corpusRevision -IdentityMode Corpus
        if ([int]$legacy.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { throw 'Legacy copy recovery accepts manifest-schema-2 revisions only.' }
        $indexRevision = [string]$legacy.IndexRevision
        if ($indexRevision -ceq $corpusRevision) { continue }
        $indexRoot = Get-RevisionDirectory -ProjectRoot $root -Revision $indexRevision
        if (-not (Test-Path -LiteralPath $indexRoot -PathType Container)) { continue }
        $copy = Assert-Revision -ProjectRoot $root -Revision $indexRevision -IdentityMode Index
        if ([int]$copy.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion -or
            [string]$copy.CorpusRevision -cne $corpusRevision) { throw 'Legacy index-keyed copy does not match its corpus-keyed source.' }
        foreach ($file in Get-ValidatedRevisionChecksumFiles -ProjectRoot $root -Revision $indexRevision -IdentityMode Index -AllowLegacy) {
            $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
            [void]$allowed.Add($relative)
        }
    }
    return $allowed
}

function Test-InterruptedLegacyPointerChecksumMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedLegacyPointerSha256
    )
    try {
        $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
        if (Test-Path -LiteralPath (Join-Path $root 'maintenance\revision-transition.json')) { return $false }
        $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
        if ([int]$pointer.schema_version -ne 2) { return $false }

        $active = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index
        if ([int]$active.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { return $false }
        $legacyActive = Assert-Revision -ProjectRoot $root -Revision ([string]$active.CorpusRevision) -IdentityMode Corpus
        if ([int]$legacyActive.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion -or
            [string]$legacyActive.IndexRevision -cne [string]$pointer.active_revision) { return $false }

        $legacyPreviousRevision = $null
        if ($null -ne $pointer.previous_revision) {
            $previous = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.previous_revision) -IdentityMode Index
            if ([int]$previous.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { return $false }
            $legacyPrevious = Assert-Revision -ProjectRoot $root -Revision ([string]$previous.CorpusRevision) -IdentityMode Corpus
            if ([int]$legacyPrevious.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion -or
                [string]$legacyPrevious.IndexRevision -cne [string]$pointer.previous_revision) { return $false }
            $legacyPreviousRevision = [string]$previous.CorpusRevision
        }

        # Write-JsonAtomic historically used the host ConvertTo-Json formatter.
        # Windows PowerShell 5.1 and PowerShell 7 emit different indentation,
        # so construct both exact supported schema-1 byte forms without relying
        # on the recovery host's serializer.
        $newline = [Environment]::NewLine
        $previousCore = if ($null -eq $legacyPreviousRevision) { 'null' } else { '"' + $legacyPreviousRevision + '"' }
        $coreJson = '{' + $newline +
            '  "schema_version": 1,' + $newline +
            '  "active_revision": "' + [string]$active.CorpusRevision + '",' + $newline +
            '  "previous_revision": ' + $previousCore + ',' + $newline +
            '  "activated_at": "' + [string]$pointer.activated_at + '"' + $newline +
            '}' + $newline
        $desktopJson = '{' + $newline +
            '    "schema_version":  1,' + $newline +
            '    "active_revision":  "' + [string]$active.CorpusRevision + '",' + $newline +
            '    "previous_revision":  ' + $previousCore + ',' + $newline +
            '    "activated_at":  "' + [string]$pointer.activated_at + '"' + $newline +
            '}' + $newline
        $expected = $ExpectedLegacyPointerSha256.ToLowerInvariant()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            foreach ($candidateJson in @($coreJson,$desktopJson)) {
                $actual = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($candidateJson)))).Replace('-', '').ToLowerInvariant()
                if ($actual -ceq $expected) { return $true }
                $sha.Initialize()
            }
        } finally { $sha.Dispose() }
        return $false
    } catch {
        return $false
    }
}

function Get-PortablePackageFileSets {
    [CmdletBinding()]
    param()

    return [ordered]@{
        root = @(
            '.mql5-chm-package-root'
            'Install-Claude.ps1'
            'Install-Codex.ps1'
            'Rebuild-Index.ps1'
            'Uninstall-Claude.ps1'
            'Uninstall-Codex.ps1'
            'Package-Portable.ps1'
            'Check-DocumentationUpdates.ps1'
            'Update-Documentation.ps1'
            'Rollback-Documentation.ps1'
            'package.json'
            'README.md'
            'SPEC.md'
        )
        runtime = @(
            'LICENSE'
            'node.exe'
        )
        app = @(
            'server.mjs'
            'indexer.mjs'
        )
        config = @(
            'mql5-image-policy.json'
            'mql5-query-expansions.json'
        )
        data = @(
            'active.json'
        )
        maintenance = @(
            '.update.lock'
        )
        scripts = @(
            'Check-DocumentationUpdates.ps1'
            'Common.ps1'
            'Compare-OfficialDocumentationHashes.ps1'
            'IndexMaintenance.ps1'
            'Install-Claude.ps1'
            'Install-Codex.ps1'
            'Package-Portable.ps1'
            'Rebuild-Index.ps1'
            'Rollback-Documentation.ps1'
            'SevenZipRuntime.ps1'
            'Smoke-Test-McpServer.mjs'
            'StageInstallRecovery.ps1'
            'Uninstall-Claude.ps1'
            'Uninstall-Codex.ps1'
            'Update-Documentation.ps1'
            'inspect-database.mjs'
        )
        tools = @(
            '7z.exe'
            '7z.dll'
            '7zip.provenance.json'
        )
        licenses = @(
            '7ZIP-LICENSE.txt'
            'BUNDLED-NODE-NOTICES.txt'
            'CHEERIO-LICENSE.txt'
            'ESBUILD-LICENSE.txt'
            'ICONV-LITE-LICENSE.txt'
            'JPEG-JS-LICENSE.txt'
            'MCP-SDK-LICENSE.txt'
            'NODE-LICENSE.txt'
            'THIRD-PARTY-NOTICES.md'
            'ZOD-LICENSE.txt'
            'bundled-node-dependencies.json'
            'bundled-node-notice-overrides.json'
            'overrides\boolbase-1.0.0.txt'
        )
    }
}

function Get-PortablePackageRequiredStaticPaths {
    [CmdletBinding()]
    param()

    $fileSets = Get-PortablePackageFileSets
    $expectedSetNames = @('root', 'runtime', 'app', 'config', 'data', 'maintenance', 'scripts', 'tools', 'licenses')
    $actualSetNames = @($fileSets.Keys)
    if ($actualSetNames.Count -ne $expectedSetNames.Count -or
        @(Compare-Object -ReferenceObject $expectedSetNames -DifferenceObject $actualSetNames -CaseSensitive).Count -ne 0) {
        throw 'Portable package file sets do not contain the exact required directory contract.'
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($setName in $expectedSetNames) {
        foreach ($listedFile in @($fileSets[$setName])) {
            $relativeFile = [string]$listedFile
            if ([string]::IsNullOrWhiteSpace($relativeFile) -or [IO.Path]::IsPathRooted($relativeFile) -or
                $relativeFile -match '(^|[\\/])\.\.?([\\/]|$)') {
                throw "Portable $setName allowlist contains an invalid relative file path: '$relativeFile'"
            }
            $portableRelative = if ($setName -ceq 'root') {
                $relativeFile.Replace('\', '/')
            } else {
                "$setName/$($relativeFile.Replace('\', '/'))"
            }
            if (-not $seen.Add($portableRelative)) {
                throw "Portable package allowlist contains a duplicate path: '$portableRelative'"
            }
            $result.Add($portableRelative)
        }
    }
    return @($result)
}

function Assert-PackageChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AllowLegacyActive,
        [switch]$AllowLegacyPointer,
        [switch]$AllowPendingTransition,
        [switch]$AllowInterruptedLegacyPointerMigration,
        [switch]$AllowInterruptedLegacyIndexCopies
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $checksumPath = Join-Path $root 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw "Package checksum manifest is missing: $checksumPath" }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pointerChecksumMismatch = $false
    $expectedPointerChecksum = $null
    foreach ($rawLine in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { throw "Malformed checksum line: $rawLine" }
        $expectedHash = $Matches[1]
        $relative = $Matches[2].Trim().Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Checksum entry must be a safe relative path: $relative" }
        $portableRelative = $relative.Replace('\','/')
        if (@('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -contains $portableRelative) { throw "Mutable maintenance file must not be checksummed: $portableRelative" }
        $candidate = Assert-PathWithin -Root $root -Path (Join-Path $root $relative)
        Assert-NoReparsePoint -Root $root -Path $candidate
        if ([IO.Path]::GetFileName($candidate) -ieq 'checksums.sha256') { throw 'checksums.sha256 must not include itself.' }
        if (-not $seen.Add($portableRelative)) { throw "Duplicate checksum entry: $relative" }
        try {
            Assert-FileSha256 -Path $candidate -Expected $expectedHash | Out-Null
        } catch {
            if ((-not $AllowPendingTransition -and -not $AllowInterruptedLegacyPointerMigration) -or
                $portableRelative -cne 'data/active.json') { throw }
            $pointerChecksumMismatch = $true
            $expectedPointerChecksum = $expectedHash
        }
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    $pointerSchema = [int]$pointer.schema_version
    $checksumExceptions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($pointerSchema -eq 1) {
        if (-not $AllowLegacyPointer) { throw 'Portable packages require an index-identity active pointer (schema_version 2).' }
        $revisionIdentityMode = 'Corpus'
    } elseif ($pointerSchema -eq 2) {
        $revisionIdentityMode = 'Index'
    } else {
        throw 'Portable package active pointer schema is unsupported.'
    }
    if ($AllowInterruptedLegacyIndexCopies) {
        if ($pointerSchema -ne 1) { throw 'Pre-pointer legacy copy recovery requires a schema-1 active pointer.' }
        $selectedCorpora = @([string]$pointer.active_revision)
        if ($null -ne $pointer.previous_revision) { $selectedCorpora += [string]$pointer.previous_revision }
        foreach ($relative in Get-ValidatedLegacyIndexCopyChecksumExceptions -ProjectRoot $root -CorpusRevisions $selectedCorpora) { [void]$checksumExceptions.Add($relative) }
    }
    if ($AllowInterruptedLegacyPointerMigration) {
        if ($pointerSchema -ne 2) { throw 'Post-pointer legacy migration recovery requires a schema-2 active pointer.' }
        $selectedCorpora = @()
        $activeLegacyIndex = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode Index
        if ([int]$activeLegacyIndex.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { throw 'Post-pointer migration recovery requires a legacy active index.' }
        $selectedCorpora += [string]$activeLegacyIndex.CorpusRevision
        if ($null -ne $pointer.previous_revision) {
            $previousLegacyIndex = Assert-Revision -ProjectRoot $root -Revision ([string]$pointer.previous_revision) -IdentityMode Index
            if ([int]$previousLegacyIndex.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { throw 'Post-pointer migration recovery requires a legacy previous index.' }
            $selectedCorpora += [string]$previousLegacyIndex.CorpusRevision
        }
        foreach ($relative in Get-ValidatedLegacyIndexCopyChecksumExceptions -ProjectRoot $root -CorpusRevisions $selectedCorpora) { [void]$checksumExceptions.Add($relative) }
    }
    if ($AllowPendingTransition) {
        $transition = Get-RevisionTransition -ProjectRoot $root
        $transitionSchema = [int]$transition.schema_version
        $isPreSwitch = $false
        $isPostSwitch = $false
        if ($transitionSchema -eq 2) {
            if ($pointerSchema -ne 2) { throw 'A schema-2 transition requires an index-identity active pointer.' }
            $isPreSwitch = [string]$pointer.active_revision -ceq [string]$transition.from_revision
            $isPostSwitch = [string]$pointer.active_revision -ceq [string]$transition.to_revision -and [string]$pointer.previous_revision -ceq [string]$transition.from_revision
        } elseif ($transitionSchema -eq 1 -and $pointerSchema -eq 1) {
            $isPreSwitch = [string]$pointer.active_revision -ceq [string]$transition.from_revision
            $isPostSwitch = [string]$pointer.active_revision -ceq [string]$transition.to_revision -and [string]$pointer.previous_revision -ceq [string]$transition.from_revision
            $legacySelections = @([string]$pointer.active_revision)
            if ($null -ne $pointer.previous_revision) { $legacySelections += [string]$pointer.previous_revision }
            foreach ($relative in Get-ValidatedLegacyIndexCopyChecksumExceptions -ProjectRoot $root -CorpusRevisions $legacySelections) { [void]$checksumExceptions.Add($relative) }
        } elseif ($transitionSchema -eq 1 -and $pointerSchema -eq 2) {
            $fromLegacy = Assert-Revision -ProjectRoot $root -Revision ([string]$transition.from_revision) -IdentityMode Corpus
            $toLegacy = Assert-Revision -ProjectRoot $root -Revision ([string]$transition.to_revision) -IdentityMode Corpus
            if ([int]$fromLegacy.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion -or [int]$toLegacy.ManifestSchemaVersion -ne $script:LegacyManifestSchemaVersion) { throw 'Migrated legacy transition references a non-legacy revision.' }
            $fromIndex = [string]$fromLegacy.IndexRevision; $toIndex = [string]$toLegacy.IndexRevision
            Assert-Revision -ProjectRoot $root -Revision $fromIndex -IdentityMode Index | Out-Null
            Assert-Revision -ProjectRoot $root -Revision $toIndex -IdentityMode Index | Out-Null
            $isPostSwitch = [string]$pointer.active_revision -ceq $toIndex -and [string]$pointer.previous_revision -ceq $fromIndex
            foreach ($relative in Get-ValidatedLegacyIndexCopyChecksumExceptions -ProjectRoot $root -CorpusRevisions @([string]$transition.from_revision,[string]$transition.to_revision)) { [void]$checksumExceptions.Add($relative) }
        } else {
            throw 'Pending transition schema conflicts with the active pointer schema.'
        }
        if (-not $isPreSwitch -and -not $isPostSwitch) { throw 'The active pointer does not match either validated side of the pending transition.' }
        if ($pointerChecksumMismatch -and -not $isPostSwitch) { throw 'Only the validated post-switch active pointer may differ from checksums.sha256 during transition recovery.' }
    } elseif ($pointerChecksumMismatch) {
        if (-not $AllowInterruptedLegacyPointerMigration -or
            -not (Test-InterruptedLegacyPointerChecksumMigration -ProjectRoot $root -ExpectedLegacyPointerSha256 $expectedPointerChecksum)) {
            throw 'The active pointer differs from checksums.sha256 outside a validated pending transition.'
        }
    }
    $required = @(Get-PortablePackageRequiredStaticPaths | ForEach-Object { $_.Replace('/', '\') })
    foreach ($name in @('manifest.json','mql5-docs.sqlite','mql5.chm','mql5book.chm','neuronetworksbook.chm')) { $required += "revisions\$($pointer.active_revision)\$name" }
    foreach ($relative in $required) {
        $portableRelative = $relative.Replace('\','/')
        if (-not $seen.Contains($portableRelative) -and -not $checksumExceptions.Contains($portableRelative)) { throw "Checksum file is missing required entry '$relative'." }
    }
    $packageMarker = (Get-Content -LiteralPath (Join-Path $root '.mql5-chm-package-root') -Raw -Encoding UTF8).Trim()
    if ($packageMarker -cne 'mql5-chm-portable-package-v1') { throw 'Portable package ownership marker is invalid.' }
    foreach ($file in Get-ValidatedRevisionChecksumFiles -ProjectRoot $root -Revision ([string]$pointer.active_revision) -IdentityMode $revisionIdentityMode -AllowLegacy:($AllowLegacyActive -or $pointerSchema -eq 1)) {
        $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if (-not $seen.Contains($relative) -and -not $checksumExceptions.Contains($relative)) { throw "Checksum file is missing active revision entry '$relative'." }
    }
    $excluded = @('checksums.sha256','maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json')
    $reparseItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Portable package contains a reparse point: $($reparseItems[0].FullName)" }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if ($excluded -contains $relative) { continue }
        if (-not $seen.Contains($relative) -and -not $checksumExceptions.Contains($relative)) { throw "Checksum file does not describe immutable package file '$relative'." }
    }
    return $true
}

function Assert-MaintenancePackageIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$AllowPendingTransition)
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
    switch ($layoutMode) {
        'portable' {
            $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
            try {
                Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive -AllowLegacyPointer:([int]$pointer.schema_version -eq 1) -AllowPendingTransition:$AllowPendingTransition | Out-Null
            } catch {
                $originalFailure = $_.Exception
                if ([int]$pointer.schema_version -eq 1 -and -not $AllowPendingTransition) {
                    try {
                        Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive -AllowLegacyPointer -AllowInterruptedLegacyIndexCopies | Out-Null
                    } catch { throw $originalFailure }
                    Convert-ActiveRevisionPointerToSchema2 -ProjectRoot $root | Out-Null
                    Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive | Out-Null
                } elseif ([int]$pointer.schema_version -eq 2 -and -not $AllowPendingTransition) {
                    try {
                        Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive -AllowInterruptedLegacyPointerMigration | Out-Null
                    } catch { throw $originalFailure }
                    Update-ManagedChecksumsIfPresent -ProjectRoot $root -AllowLegacyActive
                    Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive | Out-Null
                } else {
                    throw $originalFailure
                }
            }
            return $true
        }
        'development' { return $true }
        'incomplete-development' { throw 'Development maintenance inputs are incomplete; refusing to execute bundled or native tools.' }
        default { throw 'Portable maintenance requires checksums.sha256; refusing to execute unverified bundled or native tools.' }
    }
}

function Update-ManagedChecksumsIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string[]]$ChangedRelativePaths = @(),
        [switch]$AllowLegacyActive
    )
    $root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
    $checksumPath = Join-Path $root 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { return }
    $hashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { throw "Malformed checksum line: $line" }
        $relative = $Matches[2].Trim().Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') { throw "Checksum entry must be a safe relative path: $relative" }
        if ($relative -ieq 'checksums.sha256') { throw 'checksums.sha256 must not include itself.' }
        if (@('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -contains $relative) { continue }
        if ($hashes.ContainsKey($relative)) { throw "Duplicate checksum entry: $relative" }
        $hashes.Add($relative, $Matches[1].ToLowerInvariant())
    }
    $changed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$changed.Add('data/active.json')
    $requestedRevisions = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::Ordinal)
    foreach ($relativeInput in $ChangedRelativePaths) {
        $relative = $relativeInput.Trim().Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') { throw "Changed checksum path is unsafe: $relativeInput" }
        if (@('maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -contains $relative) { throw "Mutable maintenance file must not be checksummed: $relative" }
        Assert-PathWithin -Root $root -Path (Join-Path $root $relative.Replace('/','\')) | Out-Null
        if ($relative -match '^revisions/([0-9a-f]{64})(?:/|$)' -and -not $requestedRevisions.ContainsKey($Matches[1])) { $requestedRevisions.Add($Matches[1], $false) }
        [void]$changed.Add($relative)
    }
    foreach ($entry in @($hashes.GetEnumerator())) {
        $path = Assert-PathWithin -Root $root -Path (Join-Path $root $entry.Key.Replace('/','\'))
        if ($changed.Contains($entry.Key)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Managed checksum target is missing: $($entry.Key)" }
            $hashes[$entry.Key] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        } else {
            Assert-FileSha256 -Path $path -Expected $entry.Value | Out-Null
        }
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    $pointerPath = Join-Path $root 'data\active.json'
    $hashes['data/active.json'] = (Get-FileHash -Algorithm SHA256 -LiteralPath $pointerPath).Hash.ToLowerInvariant()
    $activeRevision = [string]$pointer.active_revision
    if (-not $requestedRevisions.ContainsKey($activeRevision)) { $requestedRevisions.Add($activeRevision, [bool]$AllowLegacyActive) }
    if ($null -ne $pointer.previous_revision) {
        $previousRevision = [string]$pointer.previous_revision
        if (-not $requestedRevisions.ContainsKey($previousRevision)) { $requestedRevisions.Add($previousRevision, $true) }
    }
    $validatedRevisionPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($revision in $requestedRevisions.Keys) {
        foreach ($file in Get-ValidatedRevisionChecksumFiles -ProjectRoot $root -Revision $revision -AllowLegacy:$requestedRevisions[$revision]) {
            $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
            [void]$validatedRevisionPaths.Add($relative)
            $hashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        }
    }
    foreach ($relative in $changed) {
        if ($relative -eq 'data/active.json') { continue }
        if (-not $hashes.ContainsKey($relative) -or ($relative.StartsWith('revisions/', [StringComparison]::OrdinalIgnoreCase) -and -not $validatedRevisionPaths.Contains($relative))) {
            throw "Changed checksum path is not an existing entry or part of a validated revision tree: $relative"
        }
    }
    $reparseItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseItems.Count -gt 0) { throw "Refusing to update checksums for a tree containing a reparse point: $($reparseItems[0].FullName)" }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        if (@('checksums.sha256','maintenance/update-status.json','maintenance/revision-transition.json','maintenance/revision-stage.json') -contains $relative) { continue }
        if (-not $hashes.ContainsKey($relative)) { throw "Refusing to bless unvalidated immutable package file '$relative'." }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($relative in @($hashes.Keys) | Sort-Object) { $lines.Add("$($hashes[$relative]) *$relative") }
    $transactionId = [Guid]::NewGuid().ToString('N')
    $writing = Join-Path $root ('.checksums.sha256.replace.writing-' + $transactionId)
    $temporary = Join-Path $root ('.checksums.sha256.replace.tmp-' + $transactionId)
    $backup = Join-Path $root ('.checksums.sha256.replace.backup-' + $transactionId)
    $prepared = $false
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($lines -join [Environment]::NewLine) + [Environment]::NewLine)
        $stream = New-Object IO.FileStream($writing, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($writing,$temporary)
        $prepared = $true
        Publish-PreparedAtomicFile -TemporaryPath $temporary -TargetPath $checksumPath -BackupPath $backup
    } catch {
        if (-not $prepared) {
            foreach ($incomplete in @($writing,$temporary)) {
                if (Test-Path -LiteralPath $incomplete -PathType Leaf) { Remove-Item -LiteralPath $incomplete -Force -ErrorAction Stop }
            }
        }
        throw
    }
    Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive:$AllowLegacyActive | Out-Null
}
