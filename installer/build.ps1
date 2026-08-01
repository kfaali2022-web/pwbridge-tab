<#
.SYNOPSIS
    Builds the pwbridge-tab Windows installer EXE.

.DESCRIPTION
    Wraps the Inno Setup compiler so a local build and the GitHub Actions
    release build produce the same artifact from the same inputs.

    Output: dist\pwbridge-tab-<version>-setup.exe plus a SHA-256 sidecar.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 0.2.0
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$IsccPath,
    [switch]$SkipValidation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$issPath = Join-Path $PSScriptRoot 'pwbridge-tab.iss'
$distDir = Join-Path $repoRoot 'dist'

function Resolve-Version {
    param([string]$Requested)
    if ($Requested) { return $Requested }
    # The module is the single source of truth; the .iss default only exists so
    # the script can be opened in the Inno IDE without a /D switch.
    $commonModule = Join-Path $repoRoot 'server\modules\PwBridge.Common.psm1'
    Import-Module $commonModule -Force
    return (Get-PwBridgeVersion)
}

function Resolve-Iscc {
    param([string]$Requested)
    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested)) { throw "ISCC not found at $Requested" }
        return $Requested
    }
    $command = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw 'Inno Setup 6 was not found. Install it from https://jrsoftware.org/isdl.php or pass -IsccPath.'
}

$version = Resolve-Version -Requested $Version
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$version' is not in major.minor.patch form."
}

if (-not $SkipValidation) {
    Write-Host 'Running validation...' -ForegroundColor Cyan
    & (Join-Path $repoRoot 'tests\Invoke-Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Validation failed with exit code $LASTEXITCODE." }
}

$iscc = Resolve-Iscc -Requested $IsccPath
Write-Host "Inno Setup:  $iscc"
Write-Host "Version:     $version"

if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

& $iscc "/DAppVersion=$version" $issPath
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE." }

$setupPath = Join-Path $distDir "pwbridge-tab-$version-setup.exe"
if (-not (Test-Path -LiteralPath $setupPath)) {
    throw "ISCC reported success but $setupPath is missing."
}

$hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecar = "$setupPath.sha256"
"$hash  $(Split-Path -Leaf $setupPath)" | Set-Content -LiteralPath $sidecar -Encoding ASCII

$sizeMb = [math]::Round((Get-Item -LiteralPath $setupPath).Length / 1MB, 2)
Write-Host ''
Write-Host "Built $setupPath ($sizeMb MB)" -ForegroundColor Green
Write-Host "SHA-256 $hash"
