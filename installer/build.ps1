<#
.SYNOPSIS
    Builds the pwbridge-tab Windows installer EXE.

.DESCRIPTION
    Wraps the Inno Setup compiler so a local build and the GitHub Actions
    release build produce the same artifact from the same inputs.

    Output: dist\pwbridge-tab-<version>-setup.exe plus a SHA-256 sidecar.

    -Version takes a SemVer string. A prerelease suffix names the artifact but
    is stripped for the Windows version resource, which only accepts digits.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 0.2.0

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 0.2.0-alpha.2
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
    return (Get-PwBridgeVersion)
}

function Resolve-Iscc {
    param([string]$Requested)
    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested)) { throw "ISCC not found at $Requested" }
        return $Requested
    }
    # Never installs anything: a local build should not silently pull in
    # Chocolatey packages. CI passes -Install to the same script itself.
    return & (Join-Path $PSScriptRoot 'Ensure-InnoSetup.ps1')
}

Import-Module (Join-Path $repoRoot 'server\modules\PwBridge.Common.psm1') -Force
$version = Resolve-Version -Requested $Version
$parts = Split-PwBridgeVersion -Version $version

if (-not $SkipValidation) {
    Write-Host 'Running validation...' -ForegroundColor Cyan
    & (Join-Path $repoRoot 'tests\Invoke-Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Validation failed with exit code $LASTEXITCODE." }
}

$iscc = Resolve-Iscc -Requested $IsccPath
Write-Host "Inno Setup:  $iscc"
Write-Host "Version:     $version"
if ($parts.IsPrerelease) { Write-Host "Base version: $($parts.Base) (prerelease build)" }

if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

& $iscc "/DAppVersion=$($parts.Base)" "/DAppVersionLabel=$version" $issPath
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
