[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Root,
    [string]$AnalyzerVersion = '1.25.0'
)
# Runs a curated security and correctness rule set of PSScriptAnalyzer over
# every PowerShell file in the repository and writes SARIF 2.1.0 for GitHub
# code scanning. Findings never fail the job; a missing analyzer, an unknown
# rule name or a write failure does, so a broken scan stays visible.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')

$rules = @(
    # Credential and command-injection handling.
    'PSAvoidUsingPlainTextForPassword',
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    'PSAvoidUsingUsernameAndPasswordParams',
    'PSUsePSCredentialType',
    'PSAvoidUsingInvokeExpression',
    'PSAvoidUsingComputerNameHardcoded',
    'PSAvoidUsingBrokenHashAlgorithms',
    'PSAvoidUsingAllowUnencryptedAuthentication',
    # Correctness defects that the parser accepts.
    'PSPossibleIncorrectComparisonWithNull',
    'PSPossibleIncorrectUsageOfAssignmentOperator',
    'PSPossibleIncorrectUsageOfRedirectionOperator',
    'PSAvoidAssignmentToAutomaticVariable',
    'PSMisleadingBacktick',
    'PSAvoidDefaultValueSwitchParameter',
    'PSReservedCmdletChar',
    'PSReservedParams',
    'PSUseCmdletCorrectly',
    'PSUseUsingScopeModifierInNewRunspaces',
    'PSAvoidMultipleTypeAttributes'
)

$installed = Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq [version]$AnalyzerVersion }
if (-not $installed) {
    Install-PSResource -Name PSScriptAnalyzer -Version $AnalyzerVersion -Repository PSGallery -TrustRepository -Scope CurrentUser -Quiet
}
Import-Module -Name PSScriptAnalyzer -RequiredVersion $AnalyzerVersion

$known = @{}
foreach ($rule in Get-ScriptAnalyzerRule) { $known[$rule.RuleName] = $rule }
$missing = @($rules | Where-Object { -not $known.ContainsKey($_) })
if ($missing.Count -gt 0) { throw "PSScriptAnalyzer $AnalyzerVersion has no rule named: $($missing -join ', ')" }

$excluded = '[\\/](\.git|node_modules|build)[\\/]'
# -Force: on Linux runners dot-directories such as .github are hidden.
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object { $_.FullName -notmatch $excluded } |
    Sort-Object -Property FullName)

$records = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    foreach ($record in @(Invoke-ScriptAnalyzer -Path $file.FullName -IncludeRule $rules)) { $records.Add($record) }
}

function Get-RelativeUri([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { throw "Finding outside the repository: $full" }
    return $full.Substring($Root.Length + 1).Replace('\', '/')
}

$levels = @{ Error = 'error'; ParseError = 'error'; Warning = 'warning'; Information = 'note' }
$results = @(foreach ($record in $records) {
    $level = $levels[[string]$record.Severity]
    if (-not $level) { $level = 'warning' }
    $region = [ordered]@{ startLine = [Math]::Max(1, [int]$record.Line) }
    if ([int]$record.Column -ge 1) { $region.startColumn = [int]$record.Column }
    [ordered]@{
        ruleId = [string]$record.RuleName
        level = $level
        message = [ordered]@{ text = [string]$record.Message }
        locations = @([ordered]@{
            physicalLocation = [ordered]@{
                artifactLocation = [ordered]@{ uri = (Get-RelativeUri $record.ScriptPath) }
                region = $region
            }
        })
    }
})

$driverRules = @(foreach ($name in $rules) {
    [ordered]@{
        id = $name
        name = $name
        shortDescription = [ordered]@{ text = [string]$known[$name].CommonName }
        fullDescription = [ordered]@{ text = [string]$known[$name].Description }
        helpUri = 'https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/' + $name.Substring(2).ToLowerInvariant()
    }
})

$sarif = [ordered]@{
    '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
    version = '2.1.0'
    runs = @([ordered]@{
        tool = [ordered]@{
            driver = [ordered]@{
                name = 'PSScriptAnalyzer'
                version = $AnalyzerVersion
                informationUri = 'https://github.com/PowerShell/PSScriptAnalyzer'
                rules = $driverRules
            }
        }
        results = $results
    })
}
$json = $sarif | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, (New-Object System.Text.UTF8Encoding($false)))

$summary = "PSScriptAnalyzer $AnalyzerVersion checked $($files.Count) files with $($rules.Count) rules: $($records.Count) findings."
Write-Output $summary
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
