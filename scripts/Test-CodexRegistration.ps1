[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mql5-chm-codex-registration-' + [Guid]::NewGuid().ToString('N'))
$binRoot = Join-Path $fixtureRoot 'bin'
$statePath = Join-Path $fixtureRoot 'state.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0

function Assert-Test {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Write-FakeState {
    param([Parameter(Mandatory)][string]$Scenario, [AllowNull()][object]$Registration)
    $state = [ordered]@{scenario=$Scenario;registration=$Registration;add_count=0;remove_count=0}
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 12), $utf8)
}

function Read-FakeState {
    return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-Registration {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Server,
        [bool]$Enabled = $true,
        [AllowNull()][object]$Environment = $null,
        [string]$Cwd = '',
        [string[]]$EnabledTools = @()
    )
    return [ordered]@{
        name='mql5-chm'
        enabled=$Enabled
        enabled_tools=@($EnabledTools)
        disabled_tools=@()
        transport=[ordered]@{type='stdio';command=$Node;args=@($Server);env=$Environment;env_vars=@();cwd=$Cwd}
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    Assert-Test $threw $Message
}

try {
    New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
    $fakeCodex = @'
$ErrorActionPreference = 'Stop'
$statePath = $env:MQL5_FAKE_CODEX_STATE
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
function Save-State { [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress -Depth 12), (New-Object Text.UTF8Encoding($false))) }
$arguments = @($args)
if ($arguments.Count -lt 2 -or $arguments[0] -ne 'mcp') { exit 90 }
switch ($arguments[1]) {
    'list' {
        if ($state.scenario -eq 'malformed-list') { '{not-json'; exit 0 }
        if ($state.scenario -eq 'duplicate-list') { '[{"name":"mql5-chm"},{"name":"mql5-chm"}]'; exit 0 }
        if ($null -eq $state.registration) { '[]' } else { '[{"name":"mql5-chm"}]' }
        exit 0
    }
    'get' {
        if ($null -eq $state.registration) { exit 4 }
        if ($state.scenario -eq 'missing-detail-name') { '{"enabled":true,"transport":{"type":"stdio","command":"x","args":["y"]}}'; exit 0 }
        if ($state.scenario -eq 'wrong-detail-name') { '{"name":"other","enabled":true,"transport":{"type":"stdio","command":"x","args":["y"]}}'; exit 0 }
        $state.registration | ConvertTo-Json -Compress -Depth 12
        exit 0
    }
    'add' {
        $state.add_count = [int]$state.add_count + 1
        if ($arguments.Count -lt 6 -or $arguments[2] -ne 'mql5-chm' -or $arguments[3] -ne '--') { Save-State; exit 91 }
        $node = [string]$arguments[4]
        $server = [string]$arguments[5]
        if ($state.scenario -eq 'repoint-after-add') {
            $node = 'C:\other-package\runtime\node.exe'
            $server = 'C:\other-package\app\server.mjs'
        }
        $enabled = $state.scenario -notlike 'partial-disabled*'
        $state.registration = [pscustomobject]@{
            name='mql5-chm';enabled=$enabled;enabled_tools=@();disabled_tools=@()
            transport=[pscustomobject]@{type='stdio';command=$node;args=@($server);env=$null;env_vars=@();cwd=''}
        }
        Save-State
        if ($state.scenario -eq 'nonzero-owned-add') { exit 44 }
        exit 0
    }
    'remove' {
        $state.remove_count = [int]$state.remove_count + 1
        if ($state.scenario -in @('concurrent-replacement-on-remove','remove-nonzero-replacement')) {
            $state.registration = [pscustomobject]@{
                name='mql5-chm';enabled=$true;enabled_tools=@();disabled_tools=@()
                transport=[pscustomobject]@{type='stdio';command='C:\other-package\runtime\node.exe';args=@('C:\other-package\app\server.mjs');env=$null;env_vars=@();cwd=''}
            }
        } else { $state.registration = $null }
        Save-State
        if ($state.scenario -in @('remove-nonzero-absent','remove-nonzero-replacement','partial-disabled-remove-nonzero-absent')) { exit 55 }
        exit 0
    }
    default { exit 92 }
}
'@
    [IO.File]::WriteAllText((Join-Path $binRoot 'fake-codex.ps1'), $fakeCodex, $utf8)
    $shim = "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-codex.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    $codexPath = Join-Path $binRoot 'codex.cmd'
    [IO.File]::WriteAllText($codexPath, $shim, [Text.Encoding]::ASCII)
    $resolverPriorityPathRoot = Join-Path $fixtureRoot 'resolver-path-priority'
    $resolverPathRoot = Join-Path $fixtureRoot 'resolver-path'
    $resolverDesktopRoot = Join-Path $fixtureRoot 'resolver-local-app-data'
    $resolverDesktopBin = Join-Path $resolverDesktopRoot 'OpenAI\Codex\bin'
    New-Item -ItemType Directory -Path $resolverPriorityPathRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $resolverPathRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resolverDesktopBin 'newer-unrunnable') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resolverDesktopBin 'older-runnable') -Force | Out-Null
    $resolverPriorityPathExe = Join-Path $resolverPriorityPathRoot 'codex.exe'
    $resolverPathShim = Join-Path $resolverPathRoot 'codex.cmd'
    $resolverPathExe = Join-Path $resolverPathRoot 'codex.exe'
    $resolverDesktopNewer = Join-Path $resolverDesktopBin 'newer-unrunnable\codex.exe'
    $resolverDesktopFallback = Join-Path $resolverDesktopBin 'older-runnable\codex.exe'
    foreach ($resolverFixture in @($resolverPriorityPathExe,$resolverPathShim,$resolverPathExe,$resolverDesktopNewer,$resolverDesktopFallback)) {
        [IO.File]::WriteAllText($resolverFixture, 'resolver fixture', [Text.Encoding]::ASCII)
    }
    [IO.File]::SetLastWriteTimeUtc($resolverDesktopNewer, [DateTime]::UtcNow)
    [IO.File]::SetLastWriteTimeUtc($resolverDesktopFallback, [DateTime]::UtcNow.AddMinutes(-1))
    $originalPath = $env:Path
    $originalLocalAppData = $env:LOCALAPPDATA
    $originalNativeCapture = (Get-Command Invoke-NativeCapture -CommandType Function).ScriptBlock
    $script:resolverProbePaths = New-Object System.Collections.Generic.List[string]
    $script:resolverProbeTimeouts = New-Object System.Collections.Generic.List[int]
    try {
        $env:Path = "$resolverPriorityPathRoot$([IO.Path]::PathSeparator)$resolverPathRoot"
        $env:LOCALAPPDATA = $resolverDesktopRoot
        function Invoke-NativeCapture {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$FilePath,
                [string[]]$Arguments = @(),
                [ValidateRange(1,1800)][int]$TimeoutSeconds = 300
            )
            $resolvedProbe = [IO.Path]::GetFullPath($FilePath)
            $script:resolverProbePaths.Add($resolvedProbe)
            $script:resolverProbeTimeouts.Add($TimeoutSeconds)
            if ($resolvedProbe.Equals($resolverPathShim, [StringComparison]::OrdinalIgnoreCase)) {
                throw [UnauthorizedAccessException]::new('simulated inaccessible PATH shim')
            }
            if (
                $resolvedProbe.Equals($resolverPriorityPathExe, [StringComparison]::OrdinalIgnoreCase) -or
                $resolvedProbe.Equals($resolverPathExe, [StringComparison]::OrdinalIgnoreCase)
            ) {
                return [pscustomobject]@{ExitCode=0;Text='not-codex 9.9.9';Lines=@('not-codex 9.9.9');DiagnosticTail='not-codex 9.9.9'}
            }
            if ($resolvedProbe.Equals($resolverDesktopNewer, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ExitCode=9;Text='codex-cli 9.9.9';Lines=@('codex-cli 9.9.9');DiagnosticTail='codex-cli 9.9.9'}
            }
            return [pscustomobject]@{ExitCode=0;Text='codex-cli 9.9.9';Lines=@('codex-cli 9.9.9');DiagnosticTail='codex-cli 9.9.9'}
        }
        $resolvedCodexFixture = Resolve-CodexExecutable
        Assert-Test (
            $resolvedCodexFixture.Equals($resolverDesktopFallback, [StringComparison]::OrdinalIgnoreCase)
        ) 'Codex resolver did not reject inaccessible, malformed, and nonzero candidates before using the runnable Desktop fallback.'
        Assert-Test (
            $script:resolverProbePaths.Count -eq 5 -and
            $script:resolverProbePaths[0].Equals($resolverPriorityPathExe, [StringComparison]::OrdinalIgnoreCase) -and
            $script:resolverProbePaths[1].Equals($resolverPathShim, [StringComparison]::OrdinalIgnoreCase) -and
            $script:resolverProbePaths[2].Equals($resolverPathExe, [StringComparison]::OrdinalIgnoreCase) -and
            $script:resolverProbePaths[3].Equals($resolverDesktopNewer, [StringComparison]::OrdinalIgnoreCase) -and
            $script:resolverProbePaths[4].Equals($resolverDesktopFallback, [StringComparison]::OrdinalIgnoreCase)
        ) 'Codex resolver did not preserve PATH directory precedence and deterministic within-directory ordering.'
        Assert-Test (
            @($script:resolverProbeTimeouts | Where-Object { $_ -ne 5 }).Count -eq 0
        ) 'Codex resolver capability probes were not bounded.'
    } finally {
        Set-Item -LiteralPath Function:\Invoke-NativeCapture -Value $originalNativeCapture
        $env:Path = $originalPath
        $env:LOCALAPPDATA = $originalLocalAppData
    }
    $nodePath = Join-Path $fixtureRoot 'package\runtime\node.exe'
    $serverPath = Join-Path $fixtureRoot 'package\app\server.mjs'
    $otherNode = 'C:\other-package\runtime\node.exe'
    $otherServer = 'C:\other-package\app\server.mjs'
    $oldStateVariable = $env:MQL5_FAKE_CODEX_STATE
    $env:MQL5_FAKE_CODEX_STATE = $statePath
    try {
        $registrationLease = Enter-CodexRegistrationMutex -TimeoutSeconds 5
        try {
            Assert-Test ([string]$registrationLease.Name -ceq 'Global\Mql5ChmMcp-CodexRegistration-v1') 'Codex registration mutex is not machine-global and fixed across package copies.'
            $escapedCommon = (Join-Path $PSScriptRoot 'Common.ps1').Replace("'", "''")
            $contentionScript = ". '$escapedCommon'; try { `$lease=Enter-CodexRegistrationMutex -TimeoutSeconds 1; `$lease.Dispose(); exit 0 } catch { exit 23 }"
            $encodedContention = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($contentionScript))
            $contention = Invoke-NativeCapture -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -Arguments @('-NoProfile','-EncodedCommand',$encodedContention)
            Assert-Test ($contention.ExitCode -eq 23) 'A concurrent process entered the Codex registration critical section.'
        } finally {
            $registrationLease.Dispose()
        }

        Write-FakeState 'normal' $null
        $result = Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath
        Assert-Test ($result.State -ceq 'absent') 'Absent uninstall was not a no-op.'
        Assert-Test ([int](Read-FakeState).remove_count -eq 0) 'Absent uninstall invoked remove.'

        Write-FakeState 'normal' $null
        $result = Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath
        Assert-Test ($result.State -ceq 'installed') 'Fresh installation did not validate.'
        $result = Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath
        Assert-Test ($result.State -ceq 'already-installed') 'Equivalent enabled installation was not idempotent.'
        Assert-Test ([int](Read-FakeState).add_count -eq 1) 'Idempotent installation invoked add twice.'

        Write-FakeState 'normal' (New-Registration $nodePath $serverPath -Enabled:$false)
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Disabled owned registration was replaced.'
        Assert-Test ([int](Read-FakeState).remove_count -eq 0) 'Disabled owned registration was removed.'

        Write-FakeState 'normal' (New-Registration $nodePath $serverPath -Environment ([ordered]@{TOKEN='value'}))
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Modified owned registration was replaced.'

        foreach ($badArgs in @(
            [pscustomobject]@{Name='scalar';Value=$serverPath},
            [pscustomobject]@{Name='null';Value=$null},
            [pscustomobject]@{Name='object';Value=[ordered]@{server=$serverPath}}
        )) {
            $malformedRegistration = New-Registration $nodePath $serverPath
            $malformedRegistration.transport.args = $badArgs.Value
            Write-FakeState 'normal' $malformedRegistration
            Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Installer accepted malformed $($badArgs.Name) args."
            Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Uninstaller accepted malformed $($badArgs.Name) args."
            Assert-Test ([int](Read-FakeState).remove_count -eq 0) "Malformed $($badArgs.Name) args registration was removed."
        }

        foreach ($malformedTransportCase in @('transport-array','type-array','command-array')) {
            $malformedRegistration = New-Registration $nodePath $serverPath
            if ($malformedTransportCase -ceq 'transport-array') { $malformedRegistration.transport = @($malformedRegistration.transport) }
            elseif ($malformedTransportCase -ceq 'type-array') { $malformedRegistration.transport.type = @('stdio') }
            else { $malformedRegistration.transport.command = @($nodePath) }
            Write-FakeState 'normal' $malformedRegistration
            Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Installer accepted malformed $malformedTransportCase registration transport."
            Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Uninstaller accepted malformed $malformedTransportCase registration transport."
            Assert-Test ([int](Read-FakeState).remove_count -eq 0) "Malformed $malformedTransportCase registration was removed."
        }

        foreach ($malformedDetailCase in @('missing-enabled','string-enabled','scalar-env','nonstring-env','scalar-env-vars','array-cwd','scalar-enabled-tools')) {
            $malformedRegistration = New-Registration $nodePath $serverPath
            switch ($malformedDetailCase) {
                'missing-enabled' { $malformedRegistration.Remove('enabled') }
                'string-enabled' { $malformedRegistration.enabled = 'true' }
                'scalar-env' { $malformedRegistration.transport.env = 'TOKEN=value' }
                'nonstring-env' { $malformedRegistration.transport.env = [ordered]@{TOKEN=7} }
                'scalar-env-vars' { $malformedRegistration.transport.env_vars = 'TOKEN' }
                'array-cwd' { $malformedRegistration.transport.cwd = @('C:\work') }
                'scalar-enabled-tools' { $malformedRegistration.enabled_tools = 'mql5_search' }
            }
            Write-FakeState 'normal' $malformedRegistration
            Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Installer accepted malformed $malformedDetailCase registration details."
            Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } "Uninstaller accepted malformed $malformedDetailCase registration details."
            Assert-Test ([int](Read-FakeState).remove_count -eq 0) "Malformed $malformedDetailCase registration was removed."
        }

        Write-FakeState 'partial-disabled' $null
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Partial disabled creation unexpectedly succeeded.'
        $state = Read-FakeState
        Assert-Test ($null -eq $state.registration -and [int]$state.remove_count -eq 1) 'Owned partial creation was not rolled back exactly once.'

        Write-FakeState 'partial-disabled-remove-nonzero-absent' $null
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Nonzero rollback command unexpectedly hid the original install failure.'
        $state = Read-FakeState
        Assert-Test ($null -eq $state.registration -and [int]$state.remove_count -eq 1) 'Nonzero rollback command did not confirm the owned partial registration absent.'

        Write-FakeState 'nonzero-owned-add' $null
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Nonzero partial creation unexpectedly succeeded.'
        Assert-Test ($null -eq (Read-FakeState).registration) 'Nonzero owned partial creation remained registered.'

        Write-FakeState 'repoint-after-add' $null
        Assert-Throws { Install-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Concurrent repointing unexpectedly succeeded.'
        $state = Read-FakeState
        Assert-Test ([string]$state.registration.transport.command -ceq $otherNode -and [int]$state.remove_count -eq 0) 'Concurrent replacement was not preserved.'

        foreach ($scenario in @('malformed-list','duplicate-list')) {
            Write-FakeState $scenario $null
            Assert-Throws { Get-CodexMcpRegistration -CodexPath $codexPath | Out-Null } "Registration lookup accepted $scenario output."
        }
        foreach ($scenario in @('missing-detail-name','wrong-detail-name')) {
            Write-FakeState $scenario (New-Registration $nodePath $serverPath)
            Assert-Throws { Get-CodexMcpRegistration -CodexPath $codexPath | Out-Null } "Registration lookup accepted $scenario output."
        }

        Write-FakeState 'normal' (New-Registration $nodePath $serverPath -Environment ([ordered]@{OPTIONAL='changed'}) -Cwd 'C:\optional' -EnabledTools @('mql5_search'))
        $result = Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath
        Assert-Test ($result.State -ceq 'removed' -and $null -eq (Read-FakeState).registration) 'Path-owned modified registration was not uninstalled.'

        Write-FakeState 'normal' (New-Registration $otherNode $otherServer)
        Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Uninstaller accepted a differently owned registration.'
        Assert-Test ([int](Read-FakeState).remove_count -eq 0) 'Uninstaller removed another package registration.'

        Write-FakeState 'concurrent-replacement-on-remove' (New-Registration $nodePath $serverPath)
        Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Concurrent uninstall replacement was reported as absent.'
        $state = Read-FakeState
        Assert-Test ([string]$state.registration.transport.command -ceq $otherNode -and [int]$state.remove_count -eq 1) 'Concurrent uninstall replacement was not preserved.'

        Write-FakeState 'remove-nonzero-absent' (New-Registration $nodePath $serverPath)
        Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Nonzero remove with confirmed absence was silently reported as success.'
        Assert-Test ($null -eq (Read-FakeState).registration) 'Nonzero remove with absence did not verify the post-state.'

        Write-FakeState 'remove-nonzero-replacement' (New-Registration $nodePath $serverPath)
        Assert-Throws { Uninstall-CodexMql5ChmRegistration -CodexPath $codexPath -NodePath $nodePath -ServerPath $serverPath | Out-Null } 'Nonzero remove with a concurrent replacement was silently accepted.'
        $state = Read-FakeState
        Assert-Test ([string]$state.registration.transport.command -ceq $otherNode -and [int]$state.remove_count -eq 1) 'Nonzero remove did not preserve and report the observed replacement.'
    } finally { $env:MQL5_FAKE_CODEX_STATE = $oldStateVariable }

    Write-Host "Codex registration tests passed: $passed"
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove registration fixture outside the temporary directory.' }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
