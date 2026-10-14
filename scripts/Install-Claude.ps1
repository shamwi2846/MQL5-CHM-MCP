[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

# Mirrors Install-Codex.ps1: verify the package and its real stdio server under
# the maintenance lock, then register it with Claude Code at user scope while
# the lock is still held.
$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
$maintenanceRoot = Join-Path $root 'maintenance'
if (-not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) {
    if ($layoutMode -eq 'portable') { throw 'Verified portable package is missing its maintenance lock directory.' }
}
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$lock = $null
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -IdentityRoot $root -TimeoutSeconds 120
    Repair-InterruptedMaintenanceArtifacts -ProjectRoot $root
    Assert-NoPendingRevisionStageInstall -ProjectRoot $root
    Assert-NoPendingRevisionTransition -ProjectRoot $root
    if ($layoutMode -eq 'portable') {
        Assert-PackageChecksums -ProjectRoot $root -AllowLegacyActive | Out-Null
        Write-Host 'Verified checksums.sha256.'
    } elseif ($layoutMode -eq 'development') {
        Write-Host 'Complete development layout detected; validating generated bundles and the active revision directly.'
    } elseif ($layoutMode -eq 'incomplete-development') {
        throw 'Development layout is incomplete. Restore all source/build dependencies or install from a verified portable package.'
    } else {
        throw 'Portable installation requires checksums.sha256; refusing to execute unverified bundled runtime or server files.'
    }

    foreach ($relativePath in @('app\server.mjs', 'app\indexer.mjs')) {
        Resolve-FullPath -Path (Join-Path $root $relativePath) -MustExist -PathType Leaf | Out-Null
    }
    $pointer = Get-ActiveRevisionPointer -ProjectRoot $root
    if ([int]$pointer.schema_version -ne 2) { throw 'Installation requires an index-identity active pointer. Stage and apply the v1.2 rebuild first.' }
    foreach ($relativePath in @('runtime','app')) { Assert-NoReparsePoint -Root $root -Path (Join-Path $root $relativePath) }
    $validated = Assert-ManifestAndCorpus -ProjectRoot $root
    $node = Ensure-PinnedNodeRuntime -ProjectRoot $root -NoDownload:($layoutMode -eq 'portable')
    Assert-NoReservedNodeRuntimeArtifacts -RuntimeRoot (Join-Path $root 'runtime')
    $server = Resolve-FullPath -Path (Join-Path $root 'app\server.mjs') -MustExist -PathType Leaf
    $smokeTest = Resolve-FullPath -Path (Join-Path $root 'scripts\Smoke-Test-McpServer.mjs') -MustExist -PathType Leaf
    $packageManifest = Read-JsonFile -Path (Join-Path $root 'package.json') -Context 'package manifest' -RequireObject
    $expectedServerVersion = [string](Get-RequiredJsonProperty $packageManifest 'version' 'package manifest')
    if ([string]::IsNullOrWhiteSpace($expectedServerVersion)) {
        throw 'Package manifest version must not be empty.'
    }
    $smokeResult = Invoke-NativeCapture -FilePath $node -Arguments @(
        $smokeTest,
        '--server',$server,
        '--timeout-ms','30000',
        '--expected-server-version',$expectedServerVersion,
        '--expected-active-revision',([string]$pointer.active_revision),
        '--expected-index-revision',([string]$validated.IndexRevision),
        '--expected-corpus-revision',([string]$validated.CorpusRevision),
        '--expected-schema-version',([string]$validated.ManifestSchemaVersion)
    )
    if ([int]$smokeResult.ExitCode -ne 0) {
        throw "Bundled MCP server smoke test failed before registration. $($smokeResult.Text)"
    }
    Write-Host 'Verified bundled MCP initialize, tools/list, and mql5_chm_status before registration.'
    $claude = Resolve-ClaudeExecutable

    $registrationResult = Install-ClaudeMql5ChmRegistration -ClaudePath $claude -NodePath $node -ServerPath $server
    if ([string]$registrationResult.State -ceq 'already-installed') {
        Write-Host "mql5-chm is already registered with Claude Code (user scope) to this package: $root"
    } else {
        Write-Host 'Installed the read-only mql5-chm MCP server for Claude Code (user scope). Restart Claude Code before using the new tools.'
    }
    foreach ($project in @($registrationResult.LocalProjects)) {
        Write-Warning "Claude Code project '$project' has its own local-scope mql5-chm entry, which overrides this user-scope registration there."
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
