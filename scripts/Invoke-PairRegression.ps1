#Requires -Version 7
<#
Development regression set for this MCP checkout paired with an MQL5 coding
skill checkout. Runs the fast suites of both repositories, the cross-repo
compatibility and environment-health tests, the search-output parity check
against the pinned baseline release, and the installed health check for
Claude Code and Codex. Release gates (both PowerShell hosts, corpus tests,
packaging) still run before every release.

  pwsh -NoProfile -File scripts\Invoke-PairRegression.ps1 [-SkillRepository <checkout>] [-Skip mcp-fast,skill-pwsh,...]

-SkillRepository defaults to a sibling folder named MQL5-Coding-Skill.
Step logs are written under %TEMP%\mql5-regression\<timestamp>.
#>
param(
    [string]$SkillRepository,
    [string[]]$Skip = @()
)
$ErrorActionPreference = 'Stop'
# `pwsh -File ... -Skip a,b` passes one comma-joined string.
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })
$mcp = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $SkillRepository) { $SkillRepository = Join-Path (Split-Path -Parent $mcp) 'MQL5-Coding-Skill' }
$skill = (Resolve-Path -LiteralPath $SkillRepository).Path
$skillRoot = Join-Path $skill 'skills\mql5-coding'
if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') -PathType Leaf)) { throw "Not an MQL5 coding skill checkout: $skill" }
$logs = Join-Path ([IO.Path]::GetTempPath()) ("mql5-regression\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $logs | Out-Null
# Client directories honour the same overrides as the skill's own scripts.
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE '.codex' } else { $env:CODEX_HOME }
$claudeHome = if ([string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) { Join-Path $env:USERPROFILE '.claude' } else { $env:CLAUDE_CONFIG_DIR }
# Same interpreter the health check prefers: the shared toolkit environment (has PyYAML).
$python = Join-Path $codexHome 'tools\mql5-python\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { $python = (Get-Command python.exe -CommandType Application | Select-Object -First 1).Source }
$results = [Collections.Generic.List[object]]::new()

function Skipped([string]$Name, [string]$Reason) { $results.Add([pscustomobject]@{ Step = $Name; Result = "SKIPPED ($Reason)"; Seconds = 0 }) }
function Step([string]$Name, [string]$Directory, [scriptblock]$Body) {
    if ($Skip -contains $Name) { Skipped $Name 'requested'; return }
    $log = Join-Path $logs "$Name.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $Directory
    try {
        $global:LASTEXITCODE = 0
        & $Body *> $log
        $ok = $? -and $LASTEXITCODE -eq 0
    } catch { $_ | Out-File -Append $log; $ok = $false }
    finally { Pop-Location }
    $results.Add([pscustomobject]@{ Step = $Name; Result = $(if ($ok) { 'PASS' } else { "FAIL ($log)" }); Seconds = [int]$watch.Elapsed.TotalSeconds })
}
function Native([string]$File, [string[]]$Arguments) { & $File @Arguments; if ($LASTEXITCODE -ne 0) { throw "$File exited $LASTEXITCODE" } }

# Skill (mirrors its .github/workflows/ci.yml, PowerShell 7 leg).
Step 'skill-python' $skill {
    Native $python @('-B', 'tests/validate_skill.py')
    Native $python @('-B', 'tests/test_mcp_contract.py')
    Native $python @('-B', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py')
}
Step 'skill-pwsh' $skill {
    foreach ($test in 'Test-Skill', 'Test-SkillReleases', 'Test-ProjectProfiles', 'Test-EditorSelection', 'Test-TerminalSelection', 'Test-ExecutableMetadata', 'Test-HealthProbe') {
        Native 'pwsh' @('-NoProfile', '-File', "tests/$test.ps1")
    }
    Native 'pwsh' @('-NoProfile', '-File', 'tests/Test-Toolkit.ps1', '-PythonPath', $python)
    Native 'pwsh' @('-NoProfile', '-File', 'tests/Test-SourceSnapshots.ps1', '-PythonPath', $python)
}
# MCP fast suite (unit, service, protocol, packaging and PowerShell syntax under both hosts).
Step 'mcp-fast' $mcp { Native 'npm' @('run', 'test:fast') }
# Cross-repo: skill compatibility and environment health against this skill checkout.
Step 'cross-repo' $mcp {
    Native 'node' @('scripts/Test-SkillCompatibility.mjs', '--skill-root', $skillRoot, '--python', $python)
    $env:MQL5_HEALTH_SKILL_ROOT = $skillRoot
    $env:MQL5_HEALTH_PYTHON = $python
    try { Native 'npm' @('run', 'test:environment-health') }
    finally { Remove-Item Env:MQL5_HEALTH_SKILL_ROOT, Env:MQL5_HEALTH_PYTHON -ErrorAction SilentlyContinue }
}
# Complete search/lookup/read output must match the pinned baseline release on the checkout's corpus fixture.
if (-not (Test-Path -LiteralPath (Join-Path $mcp 'data\active.json') -PathType Leaf)) {
    Skipped 'search-parity' 'no corpus fixture (data\ and revisions\) in the MCP checkout'
} else {
    Step 'search-parity' $mcp { Native 'npm' @('run', 'test:search-parity') }
}
foreach ($clientHost in 'Claude', 'Codex') {
    $clientHome = if ($clientHost -eq 'Claude') { $claudeHome } else { $codexHome }
    $healthScript = Join-Path $clientHome 'skills\mql5-coding\scripts\Test-Mql5Environment.ps1'
    $name = "health-$($clientHost.ToLowerInvariant())"
    if (-not (Test-Path -LiteralPath $healthScript -PathType Leaf)) { Skipped $name "skill not installed under $clientHome"; continue }
    Step $name $mcp { Native 'pwsh' @('-NoProfile', '-File', $healthScript, '-ClientHost', $clientHost, '-WorkspaceRoot', $mcp, '-McpSourceRoot', $mcp, '-SkillSourceRoot', $skillRoot) }
}
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Logs: $logs"
if ($results.Result -match '^FAIL') { exit 1 }
