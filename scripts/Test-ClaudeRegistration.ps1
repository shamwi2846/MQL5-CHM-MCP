[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

# Exercises the Claude Code registration lifecycle against a fake CLI that
# edits an isolated CLAUDE_CONFIG_DIR. The real Claude configuration is never
# read or changed.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mql5-chm-claude-registration-' + [Guid]::NewGuid().ToString('N'))
$binRoot = Join-Path $fixtureRoot 'bin'
$configRoot = Join-Path $fixtureRoot 'claude-config'
$configPath = Join-Path $configRoot '.claude.json'
$scenarioPath = Join-Path $fixtureRoot 'scenario.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0

function Assert-Test {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    Assert-Test $threw $Message
}

function New-ClaudeEntryJson {
    param([Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string]$Server, [string]$EnvironmentJson = '{}')
    return '{"type":"stdio","command":' + (ConvertTo-Json $Node -Compress) + ',"args":[' + (ConvertTo-Json $Server -Compress) + '],"env":' + $EnvironmentJson + '}'
}

function Write-FakeConfig {
    param([Parameter(Mandatory)][string]$Scenario, [AllowNull()][string]$UserEntryJson, [string]$LocalEntryJson)
    # Case-distinct project keys are legal for Claude Code and must not break
    # the case-sensitive reader.
    $local = if ($LocalEntryJson) { '"mcpServers":{"mql5-chm":' + $LocalEntryJson + '}' } else { '"mcpServers":{}' }
    $servers = if ($UserEntryJson) { '{"mql5-chm":' + $UserEntryJson + ',"other":{"type":"stdio","command":"x","args":[]}}' } else { '{"other":{"type":"stdio","command":"x","args":[]}}' }
    $json = '{"numStartups":3,"projects":{"C:/Work/Repo":{' + $local + '},"c:/work/repo":{"mcpServers":{}}},"mcpServers":' + $servers + '}'
    [IO.File]::WriteAllText($configPath, $json, $utf8)
    [IO.File]::WriteAllText($scenarioPath, (ConvertTo-Json @{scenario=$Scenario;add_count=0;remove_count=0} -Compress), $utf8)
}

function Read-FakeCounts { return Get-Content -LiteralPath $scenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-UserCommand {
    $entry = Get-CaseSensitiveJsonMember -Text ([IO.File]::ReadAllText($configPath)) -Path @('mcpServers','mql5-chm')
    if ($null -eq $entry) { return $null }
    return [string]($entry | ConvertFrom-Json).command
}

$oldConfig = $env:CLAUDE_CONFIG_DIR
$oldScenario = $env:MQL5_FAKE_CLAUDE_SCENARIO
try {
    New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
    $fakeClaude = @'
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'
$scenarioPath = $env:MQL5_FAKE_CLAUDE_SCENARIO
$state = Get-Content -LiteralPath $scenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json
$utf8 = New-Object Text.UTF8Encoding($false)
function Save-State { [IO.File]::WriteAllText($scenarioPath, ($state | ConvertTo-Json -Compress), $utf8) }
function Set-UserEntry([AllowNull()][string]$EntryJson) {
    $root = [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($configPath))
    $servers = $root['mcpServers']
    [void]$servers.Remove('mql5-chm')
    if ($EntryJson) { $servers.Add('mql5-chm', [Text.Json.Nodes.JsonNode]::Parse($EntryJson)) }
    [IO.File]::WriteAllText($configPath, $root.ToJsonString(), $utf8)
}
function Entry([string]$Node, [string]$Server) {
    return '{"type":"stdio","command":' + (ConvertTo-Json $Node -Compress) + ',"args":[' + (ConvertTo-Json $Server -Compress) + '],"env":{}}'
}
$arguments = @($args)
if ($arguments.Count -eq 1 -and $arguments[0] -eq '--version') { '9.9.9 (Claude Code)'; exit 0 }
if ($arguments.Count -lt 5 -or $arguments[0] -ne 'mcp' -or $arguments[2] -ne '--scope' -or $arguments[3] -ne 'user' -or $arguments[4] -ne 'mql5-chm') { exit 90 }
switch ($arguments[1]) {
    'add' {
        $state.add_count = [int]$state.add_count + 1
        if ($arguments.Count -ne 8 -or $arguments[5] -ne '--') { Save-State; exit 91 }
        $node = [string]$arguments[6]; $server = [string]$arguments[7]
        if ($state.scenario -eq 'repoint-after-add') { $node = 'C:\other-package\runtime\node.exe'; $server = 'C:\other-package\app\server.mjs' }
        if ($state.scenario -eq 'environment-after-add') { Set-UserEntry ((Entry $node $server).Replace('"env":{}','"env":{"EXTRA":"1"}')) }
        else { Set-UserEntry (Entry $node $server) }
        Save-State
        if ($state.scenario -eq 'nonzero-owned-add') { exit 44 }
        exit 0
    }
    'remove' {
        $state.remove_count = [int]$state.remove_count + 1
        if ($state.scenario -eq 'concurrent-replacement-on-remove') { Set-UserEntry (Entry 'C:\other-package\runtime\node.exe' 'C:\other-package\app\server.mjs') }
        else { Set-UserEntry $null }
        Save-State
        if ($state.scenario -eq 'remove-nonzero-absent') { exit 55 }
        exit 0
    }
    default { exit 92 }
}
'@
    [IO.File]::WriteAllText((Join-Path $binRoot 'fake-claude.ps1'), $fakeClaude, $utf8)
    $shim = "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-claude.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    $claudePath = Join-Path $binRoot 'claude.cmd'
    [IO.File]::WriteAllText($claudePath, $shim, [Text.Encoding]::ASCII)
    $env:CLAUDE_CONFIG_DIR = $configRoot
    $env:MQL5_FAKE_CLAUDE_SCENARIO = $scenarioPath

    Assert-Test ((Get-ClaudeUserConfigPath) -ceq [IO.Path]::GetFullPath($configPath)) 'Claude Code config path does not follow CLAUDE_CONFIG_DIR.'
    $lease = Enter-ClaudeRegistrationMutex -TimeoutSeconds 5
    try {
        Assert-Test ([string]$lease.Name -ceq 'Global\Mql5ChmMcp-ClaudeRegistration-v1') 'Claude Code registration mutex is not machine-global and fixed.'
    } finally { $lease.Dispose() }

    $package = Join-Path $fixtureRoot 'package (copy) & draft'
    $nodePath = Join-Path $package 'runtime\node.exe'
    $serverPath = Join-Path $package 'app\server.mjs'
    $otherNode = 'C:\other-package\runtime\node.exe'
    $otherServer = 'C:\other-package\app\server.mjs'

    Write-FakeConfig 'normal' $null
    $result = Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath
    Assert-Test ($result.State -ceq 'installed' -and (Get-UserCommand) -ceq $nodePath) 'Fresh Claude Code registration was not installed with the package paths.'
    Assert-Test ((Get-CaseSensitiveJsonMember -Text ([IO.File]::ReadAllText($configPath)) -Path @('mcpServers','other')) -ne $null) 'Unrelated Claude Code MCP entries were not preserved.'
    $again = Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath
    Assert-Test ($again.State -ceq 'already-installed' -and [int](Read-FakeCounts).add_count -eq 1) 'Equivalent Claude Code registration was not idempotent.'

    Write-FakeConfig 'normal' (New-ClaudeEntryJson $otherNode $otherServer)
    Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'A conflicting Claude Code registration was replaced.'
    Assert-Test ((Get-UserCommand) -ceq $otherNode) 'A conflicting Claude Code registration was not preserved.'

    Write-FakeConfig 'normal' (New-ClaudeEntryJson $nodePath $serverPath '{"EXTRA":"1"}')
    Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'A modified owned Claude Code registration was accepted as equivalent.'

    Write-FakeConfig 'normal' $null (New-ClaudeEntryJson $otherNode $otherServer)
    $withLocal = Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath
    Assert-Test (@($withLocal.LocalProjects).Count -eq 1 -and @($withLocal.LocalProjects)[0] -ceq 'C:/Work/Repo') 'An overriding local-scope Claude Code entry was not reported.'

    Write-FakeConfig 'repoint-after-add' $null
    Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'A concurrently repointed Claude Code registration was accepted.'
    Assert-Test ((Get-UserCommand) -ceq $otherNode -and [int](Read-FakeCounts).remove_count -eq 0) 'A concurrently repointed Claude Code registration was not preserved.'

    Write-FakeConfig 'environment-after-add' $null
    Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'A non-equivalent new Claude Code registration was accepted.'
    Assert-Test ($null -eq (Get-UserCommand) -and [int](Read-FakeCounts).remove_count -eq 1) 'A non-equivalent owned Claude Code registration was not rolled back.'

    Write-FakeConfig 'nonzero-owned-add' $null
    Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'A failed Claude Code add command was reported as success.'
    Assert-Test ($null -eq (Get-UserCommand)) 'A failed Claude Code add left its owned registration behind.'

    Write-FakeConfig 'normal' (New-ClaudeEntryJson $nodePath $serverPath)
    Assert-Test ((Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath).State -ceq 'removed' -and $null -eq (Get-UserCommand)) 'Owned Claude Code registration was not uninstalled.'
    Assert-Test ((Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath).State -ceq 'absent') 'Absent Claude Code registration was not a no-op.'

    Write-FakeConfig 'normal' (New-ClaudeEntryJson $otherNode $otherServer)
    Assert-Throws { Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Uninstaller accepted a differently owned Claude Code registration.'
    Assert-Test ([int](Read-FakeCounts).remove_count -eq 0) 'Uninstaller removed another package registration.'

    Write-FakeConfig 'concurrent-replacement-on-remove' (New-ClaudeEntryJson $nodePath $serverPath)
    Assert-Throws { Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Concurrent Claude Code replacement during uninstall was reported as success.'
    Assert-Test ((Get-UserCommand) -ceq $otherNode) 'Concurrent Claude Code replacement during uninstall was not preserved.'

    Write-FakeConfig 'remove-nonzero-absent' (New-ClaudeEntryJson $nodePath $serverPath)
    Assert-Throws { Uninstall-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Nonzero Claude Code remove was silently reported as success.'
    Assert-Test ($null -eq (Get-UserCommand)) 'Nonzero Claude Code remove did not verify absence.'

    # A CLI exception after a completed write must still roll back the owned entry.
    Write-FakeConfig 'normal' $null
    $originalNativeCapture = (Get-Command Invoke-NativeCapture -CommandType Function).ScriptBlock
    try {
        function Invoke-NativeCapture {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [ValidateRange(1,1800)][int]$TimeoutSeconds = 300)
            $captured = & $originalNativeCapture -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
            if ($Arguments.Count -gt 1 -and $Arguments[1] -ceq 'add') { throw [TimeoutException]::new('simulated add deadline') }
            return $captured
        }
        Assert-Throws { Install-ClaudeMql5ChmRegistration -ClaudePath $claudePath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'An add command exception was reported as success.'
        Assert-Test ($null -eq (Get-UserCommand) -and [int](Read-FakeCounts).remove_count -eq 1) 'An add command exception left its owned registration behind.'
    } finally {
        Set-Item -LiteralPath Function:\Invoke-NativeCapture -Value $originalNativeCapture
    }

    $singleton = '[' + (New-ClaudeEntryJson $nodePath $serverPath) + ']'
    [IO.File]::WriteAllText($configPath, '{"mcpServers":{"mql5-chm":' + $singleton + '}}', $utf8)
    Assert-Throws { Get-ClaudeMcpRegistrations | Out-Null } 'A singleton-array Claude Code registration was accepted.'

    [IO.File]::WriteAllText($configPath, '{"mcpServers":{"mql5-chm":{"type":"http","url":"https://example.invalid"}}}', $utf8)
    Assert-Throws { Get-ClaudeMcpRegistrations | Out-Null } 'A non-stdio Claude Code registration was accepted.'

    Write-Host "Claude Code registration tests passed: $passed"
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldConfig
    $env:MQL5_FAKE_CLAUDE_SCENARIO = $oldScenario
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove registration fixture outside the temporary directory.' }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
