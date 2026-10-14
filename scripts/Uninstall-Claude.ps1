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
$claude = Resolve-ClaudeExecutable
$node = [IO.Path]::GetFullPath((Join-Path $root 'runtime\node.exe'))
$server = [IO.Path]::GetFullPath((Join-Path $root 'app\server.mjs'))
$registrationResult = Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claude -NodePath $node -ServerPath $server
if ([string]$registrationResult.State -ceq 'absent') {
    Write-Host 'No mql5-chm Claude Code user-scope registration exists; nothing was removed.'
    return
}

# Deliberately remove only the Claude Code registration. Package files and
# documentation are preserved in $root.
Write-Host "Removed only the mql5-chm Claude Code registration. Package files remain at '$root'."
