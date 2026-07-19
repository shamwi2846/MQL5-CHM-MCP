[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
Assert-NoReparsePoint -Root $root -Path $root
$codex = Resolve-CodexExecutable
$node = [IO.Path]::GetFullPath((Join-Path $root 'runtime\node.exe'))
$server = [IO.Path]::GetFullPath((Join-Path $root 'app\server.mjs'))
$registrationResult = Uninstall-CodexMql5ChmRegistration -CodexPath $codex -NodePath $node -ServerPath $server
if ([string]$registrationResult.State -ceq 'absent') {
    Write-Host 'No mql5-chm Codex registration exists; nothing was removed.'
    return
}

# Deliberately remove only the Codex registration. Package files and documentation
# are preserved in $root.
Write-Host "Removed only the mql5-chm Codex registration. Package files remain at '$root'."
