<#
.SYNOPSIS
    Locates a usable Inno Setup 6 compiler, optionally installing one first.

.DESCRIPTION
    Writes the path to ISCC.exe to the pipeline.

    Any Inno Setup at or above -MinimumVersion is accepted. Hosted CI images
    already ship a recent one, and pinning an exact version there fails outright:
    Chocolatey refuses to "install" an older version over a newer one.

    -Install falls back to Chocolatey when nothing suitable is present.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File installer\Ensure-InnoSetup.ps1 -Install
#>
[CmdletBinding()]
param(
    [version]$MinimumVersion = '6.3',
    [switch]$Install
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-IsccCandidatePath {
    $paths = New-Object System.Collections.Generic.List[string]

    $command = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($command) { $paths.Add($command.Source) }

    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($root) { $paths.Add((Join-Path $root 'Inno Setup 6\ISCC.exe')) }
    }

    # Catches an install in a non-default directory.
    foreach ($key in @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1')) {
        $entry = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($entry -and $entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) {
            $paths.Add((Join-Path $entry.InstallLocation 'ISCC.exe'))
        }
    }

    $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

function Get-IsccVersion {
    param([string]$Path)
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($raw in @($info.ProductVersion, $info.FileVersion)) {
        if ($raw -and ($raw -match '^\s*(\d+(\.\d+){1,3})')) { return [version]$Matches[1] }
    }
    return $null
}

function Find-Iscc {
    param([version]$Minimum)
    foreach ($path in @(Get-IsccCandidatePath)) {
        $found = Get-IsccVersion -Path $path
        if ($null -eq $found) {
            Write-Host "Using $path (version resource unreadable)."
            return $path
        }
        if ($found -ge $Minimum) {
            Write-Host "Using Inno Setup $found at $path"
            return $path
        }
        Write-Host "Skipping Inno Setup $found at $path ($Minimum or newer required)."
    }
    return $null
}

$iscc = Find-Iscc -Minimum $MinimumVersion

if (-not $iscc) {
    if (-not $Install) {
        throw "Inno Setup $MinimumVersion or newer was not found. Install it from https://jrsoftware.org/isdl.php, or re-run with -Install."
    }
    if (-not (Get-Command 'choco.exe' -ErrorAction SilentlyContinue)) {
        throw "Inno Setup $MinimumVersion or newer was not found and Chocolatey is not available to install it."
    }

    Write-Host 'Installing Inno Setup with Chocolatey...'
    & choco.exe install innosetup --no-progress -y
    if ($LASTEXITCODE -ne 0) { throw "choco install innosetup failed with exit code $LASTEXITCODE." }

    $iscc = Find-Iscc -Minimum $MinimumVersion
    if (-not $iscc) { throw 'Chocolatey reported success but no suitable ISCC.exe was found.' }
}

$iscc
