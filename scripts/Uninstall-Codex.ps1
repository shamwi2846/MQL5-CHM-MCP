[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Resolve-FullPath -Path $ProjectRoot -MustExist -PathType Container
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
$codex = Resolve-FullPath -Path $command.Source -MustExist -PathType Leaf

$probe = Invoke-NativeCapture -FilePath $codex -Arguments @('mcp', 'list', '--json')
if ($probe.ExitCode -ne 0) {
    throw "Unable to inspect Codex MCP registrations. $($probe.Text)"
}
try {
    $null = $probe.Text | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Codex returned invalid MCP registration JSON: $($_.Exception.Message)"
}
if ($probe.Text -notmatch '"name"\s*:\s*"mql5-chm"') {
    Write-Host 'No mql5-chm Codex registration exists; nothing was removed.'
    return
}

# Deliberately remove only the Codex registration. Package files and documentation
# are preserved in $root.
Invoke-NativeChecked -FilePath $codex -Arguments @('mcp', 'remove', 'mql5-chm') -FailureMessage 'Failed to remove the mql5-chm Codex registration.'
Write-Host "Removed only the mql5-chm Codex registration. Package files remain at '$root'."
