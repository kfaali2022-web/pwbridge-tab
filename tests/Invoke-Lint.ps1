<#
.SYNOPSIS
    Runs PSScriptAnalyzer over the repository. Errors and warnings fail.
#>
[CmdletBinding()]
param([switch]$Fix)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Warning 'PSScriptAnalyzer is not installed; skipping lint. Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 0
}
Import-Module PSScriptAnalyzer -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

$paths = @('server', 'tools', 'installer', 'tests') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
$paths += (Join-Path $repoRoot 'install.ps1')
$paths += (Join-Path $repoRoot 'uninstall.ps1')
$paths = $paths | Where-Object { Test-Path -LiteralPath $_ }

$results = @()
foreach ($path in $paths) {
    $results += Invoke-ScriptAnalyzer -Path $path -Recurse -Settings $settings -Fix:$Fix
}

if (-not $results) {
    Write-Host 'PSScriptAnalyzer: clean.' -ForegroundColor Green
    exit 0
}

$results |
    Sort-Object Severity, ScriptName, Line |
    Format-Table Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap |
    Out-String |
    Write-Host

$errors = @($results | Where-Object { $_.Severity -eq 'Error' })
Write-Host ("PSScriptAnalyzer: {0} finding(s), {1} error(s)." -f $results.Count, $errors.Count) -ForegroundColor Yellow
exit 1
