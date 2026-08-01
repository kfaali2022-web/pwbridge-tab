<#
.SYNOPSIS
    Runs the full validation suite: syntax parse, PSScriptAnalyzer, Pester and
    the web asset checks.

.EXAMPLE
    pwsh -File tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipLint,
    [switch]$SkipSyntax
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = @()

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "-- $Name passed" -ForegroundColor Green
    } catch {
        Write-Host "-- $Name FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:failures += $Name
    }
}

if (-not $SkipSyntax) {
    Invoke-Step 'Syntax' {
        & (Join-Path $PSScriptRoot 'Test-Syntax.ps1')
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
    }
}

if (-not $SkipLint) {
    Invoke-Step 'PSScriptAnalyzer' {
        & (Join-Path $PSScriptRoot 'Invoke-Lint.ps1')
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
    }
}

Invoke-Step 'Pester' {
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })) {
        throw 'Pester 5 or newer is required. Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck'
    }
    Import-Module Pester -MinimumVersion 5.0.0 -Force

    $config = New-PesterConfiguration
    $config.Run.Path = $PSScriptRoot
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.Should.ErrorAction = 'Continue'

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed" }
}

Invoke-Step 'Web assets' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Warning 'node is not available; skipping JavaScript syntax check.'
        return
    }
    foreach ($js in @('web/app.js', 'web/phone.js')) {
        & node --check (Join-Path $repoRoot $js)
        if ($LASTEXITCODE -ne 0) { throw "$js failed node --check" }
    }
    & node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" (Join-Path $repoRoot 'tools/deps.json')
    if ($LASTEXITCODE -ne 0) { throw 'tools/deps.json is not valid JSON' }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("Validation FAILED: {0}" -f ($failures -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host 'Validation passed.' -ForegroundColor Green
exit 0
