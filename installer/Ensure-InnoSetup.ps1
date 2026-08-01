<#
.SYNOPSIS
    Locates a usable Inno Setup 6 compiler, optionally installing one first.

.DESCRIPTION
    Writes the path to ISCC.exe to the pipeline.

    Any Inno Setup at or above -MinimumVersion is accepted. Hosted CI images
    already ship a recent one, and pinning an exact version there fails outright:
    Chocolatey refuses to "install" an older version over a newer one.

    ISCC.exe carries no usable version resource (it reports 0.0.0.0), so the
    version comes from the compiler's own start-up banner. When that cannot be
    read the candidate is used anyway: ISCC rejects directives it does not
    understand with a clear message of its own, which beats guessing here.

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

function Get-IsccVersionText {
    param([string]$Path)

    # Start-Process rather than the call operator: ISCC exits non-zero when it
    # only prints its banner, and $LASTEXITCODE is what a CI step exits on.
    $captured = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    $banner = $null
    try {
        Start-Process -FilePath $Path -NoNewWindow -Wait -RedirectStandardOutput $captured
        $banner = Get-Content -LiteralPath $captured -Raw
    } catch {
        $banner = $null
    } finally {
        Remove-Item -LiteralPath $captured -Force -ErrorAction SilentlyContinue
    }
    if ($banner -and ($banner -match 'Inno Setup\s+(\d+(?:\.\d+)*)')) { return $Matches[1] }

    $info = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($raw in @($info.ProductVersion, $info.FileVersion)) {
        if ($raw -and ($raw -match '^\s*(\d+(?:\.\d+)+)') -and ($Matches[1] -notmatch '^0(\.0)*$')) {
            return $Matches[1]
        }
    }
    return $null
}

function Test-IsccVersion {
    param([string]$VersionText, [version]$Minimum)

    # Unknown: use it. A stale compiler fails the build with its own error.
    if (-not $VersionText) { return $true }

    if ($VersionText -match '\.') { return ([version]$VersionText -ge $Minimum) }

    # The banner sometimes carries only the major version ("Inno Setup 6").
    return ([int]$VersionText -ge $Minimum.Major)
}

function Find-Iscc {
    param([version]$Minimum)
    foreach ($path in @(Get-IsccCandidatePath)) {
        $versionText = Get-IsccVersionText -Path $path
        if (Test-IsccVersion -VersionText $versionText -Minimum $Minimum) {
            if ($versionText) {
                Write-Host "Using Inno Setup $versionText at $path"
            } else {
                Write-Host "Using $path (version could not be determined)"
            }
            return $path
        }
        Write-Host "Skipping Inno Setup $versionText at $path ($Minimum or newer required)."
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
    Start-Process -FilePath 'choco.exe' -ArgumentList 'install', 'innosetup', '--no-progress', '-y' -NoNewWindow -Wait

    $iscc = Find-Iscc -Minimum $MinimumVersion
    if (-not $iscc) { throw 'Chocolatey ran but no suitable ISCC.exe was found afterwards.' }
}

$iscc
