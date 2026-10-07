[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageJsonPath,
    [Parameter(Mandatory)][string]$PackageLockPath,
    [Parameter(Mandatory)][string]$RefType,
    [AllowEmptyString()][string]$RefName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 7) {
    throw "Release identity validation requires PowerShell 7, found $($PSVersionTable.PSVersion)."
}
if (-not ($RefType -ceq 'branch' -or $RefType -ceq 'tag')) {
    throw "Release ref type must be exactly 'branch' or 'tag'; found '$RefType'."
}

function Read-ReleaseJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label was not found: $Path"
    }
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -NoEnumerate
    } catch {
        throw "$Label is not valid JSON: $($_.Exception.Message)"
    }
    if (-not ($parsed -is [Collections.IDictionary])) {
        throw "$Label must contain a JSON object root."
    }
    return $parsed
}

$package = Read-ReleaseJson -Path $PackageJsonPath -Label 'package.json'
$packageLock = Read-ReleaseJson -Path $PackageLockPath -Label 'package-lock.json'
$packageVersion = $package['version']
if (-not ($packageVersion -is [string]) -or [string]::IsNullOrWhiteSpace($packageVersion)) {
    throw 'package.json version must be a non-empty string.'
}
$version = [string]$packageVersion
$semVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($version -cnotmatch $semVerPattern) {
    throw "package.json version is not a release version: $version"
}
$lockVersion = $packageLock['version']
if (-not ($lockVersion -is [string]) -or [string]$lockVersion -cne $version) {
    throw "package-lock.json version does not match package.json version $version."
}
$lockPackages = $packageLock['packages']
$rootPackage = if ($lockPackages -is [Collections.IDictionary]) { $lockPackages[''] } else { $null }
if (
    -not ($rootPackage -is [Collections.IDictionary]) -or
    -not ($rootPackage['version'] -is [string]) -or
    [string]$rootPackage['version'] -cne $version
) {
    throw "package-lock.json root package version does not match package.json version $version."
}
if ($RefType -ceq 'tag') {
    $expectedTag = "v$version"
    if ($RefName -cne $expectedTag) {
        throw "Release tag '$RefName' does not match package version tag '$expectedTag'."
    }
}

Write-Host "Verified release version $version against package-lock.json$(if ($RefType -ceq 'tag') { " and tag $RefName" })."
