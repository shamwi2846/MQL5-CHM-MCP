[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Resolve-CodexExecutable {
    # Prefer the npm command shim. Windows App Execution Aliases can expose an
    # inaccessible codex.exe that resolves successfully but fails with Access denied.
    $command = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        throw 'Codex CLI was not found on PATH.'
    }
    return Resolve-FullPath -Path $command.Source -MustExist -PathType Leaf
}

function Get-McpRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CodexPath)

    # `mcp get` intentionally exits non-zero for a missing server. Windows
    # PowerShell promotes its stderr to a terminating NativeCommandError under
    # ErrorActionPreference=Stop, so use the successful list operation instead.
    $result = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'list', '--json')
    if ($result.ExitCode -ne 0) {
        throw "Unable to list Codex MCP registrations. $($result.Text)"
    }
    try {
        $registrations = @($result.Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Codex returned invalid JSON for its MCP registrations: $($_.Exception.Message)"
    }
    if ($result.Text -notmatch '"name"\s*:\s*"mql5-chm"') {
        return $null
    }

    # Once list proves the entry exists, `get` is guaranteed to be a successful
    # command and therefore does not trigger the Windows PowerShell stderr trap.
    $details = Invoke-NativeCapture -FilePath $CodexPath -Arguments @('mcp', 'get', 'mql5-chm', '--json')
    if ($details.ExitCode -ne 0) {
        throw "Codex listed mql5-chm but could not read it. $($details.Text)"
    }
    try {
        return $details.Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Codex returned invalid JSON for the mql5-chm registration: $($_.Exception.Message)"
    }
}

function Test-RegistrationMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Registration,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ServerPath
    )

    return Test-Mql5ChmRegistrationMatches -Registration $Registration -NodePath $NodePath -ServerPath $ServerPath
}

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$layoutMode = Get-Mql5ChmLayoutMode -ProjectRoot $root
$maintenanceRoot = Join-Path $root 'maintenance'
if (-not (Test-Path -LiteralPath $maintenanceRoot -PathType Container)) {
    if ($layoutMode -eq 'portable') { throw 'Verified portable package is missing its maintenance lock directory.' }
    New-Item -ItemType Directory -Path $maintenanceRoot | Out-Null
}
Assert-NoReparsePoint -Root $root -Path $maintenanceRoot
$lock = $null
try {
    $lock = Enter-ExclusiveFileLock -Path (Join-Path $maintenanceRoot '.update.lock') -TimeoutSeconds 120
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
    # The newly installed runtime is deliberately transitional: it must start
    # on a fully validated supported old contract so migration/rollback can be
    # completed before the current index is activated.
    Assert-ManifestAndCorpus -ProjectRoot $root | Out-Null
    $node = Resolve-NodeExecutable -ProjectRoot $root -RequireBundled
    $server = Resolve-FullPath -Path (Join-Path $root 'app\server.mjs') -MustExist -PathType Leaf
    $codex = Resolve-CodexExecutable

    $existing = Get-McpRegistration -CodexPath $codex
    if ($null -ne $existing) {
        if (Test-RegistrationMatches -Registration $existing -NodePath $node -ServerPath $server) {
            $enabled = Get-RequiredJsonProperty -Object $existing -Name 'enabled' -Context 'Codex registration'
            if (-not [bool]$enabled) {
                throw 'The existing mql5-chm registration points to this package but is disabled. Refusing to replace it automatically.'
            }
            Write-Host "mql5-chm is already registered to this package: $root"
            return
        }
        throw "A conflicting Codex MCP registration named 'mql5-chm' already exists. Remove it explicitly before installing this package."
    }

    Invoke-NativeChecked -FilePath $codex -Arguments @('mcp', 'add', 'mql5-chm', '--', $node, $server) -FailureMessage 'Failed to register mql5-chm with Codex.'
    $installed = Get-McpRegistration -CodexPath $codex
    if ($null -eq $installed -or -not (Test-RegistrationMatches -Registration $installed -NodePath $node -ServerPath $server)) {
        throw 'Codex reported success, but the installed mql5-chm registration did not match the verified package paths.'
    }
    Write-Host 'Installed the read-only mql5-chm MCP server. Restart Codex before using the new tools.'
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
