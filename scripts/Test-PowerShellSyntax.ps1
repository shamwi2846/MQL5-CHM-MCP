[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$paths = @(
    @(Get-ChildItem -LiteralPath $projectRoot -File -Filter '*.ps1')
    @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse -Filter '*.ps1')
) | ForEach-Object FullName | Sort-Object -Unique

$failures = New-Object 'Collections.Generic.List[string]'
foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) {
        $failures.Add("${path}:$($error.Extent.StartLineNumber): $($error.Message)")
    }
}
if ($failures.Count -ne 0) {
    throw "PowerShell $($PSVersionTable.PSVersion) syntax validation failed:`n$($failures -join "`n")"
}
Write-Host "PowerShell $($PSVersionTable.PSVersion) parsed $($paths.Count) project scripts successfully."
