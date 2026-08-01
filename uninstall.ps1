# pwbridge-tab source uninstaller (Windows). MIT License.
#
# Undoes install.ps1. If you installed from the setup EXE, use
# Settings -> Apps -> Installed apps -> pwbridge-tab instead.
#
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#
# Options:
#   -KeepState   Leave the token, logs and downloaded Android tools in place

[CmdletBinding()]
param([switch]$KeepState)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\pwbridge-tab'
$legacyDir = Join-Path $env:LOCALAPPDATA 'pwbridge-tab'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\pwbridge-tab'
$legacyLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\pwbridge-tab.lnk'
$desktopLnk = Join-Path ([System.Environment]::GetFolderPath('Desktop')) 'pwbridge-tab.lnk'

function Write-Good { param([string]$Text) Write-Host "[ok] $Text" -ForegroundColor Green }

Write-Host '== pwbridge-tab uninstall ==' -ForegroundColor Cyan

# Graceful stop first: this also closes any scrcpy window the bridge started.
$launcher = Join-Path $installDir 'tools\pwbridge.cmd'
if (Test-Path -LiteralPath $launcher) {
    & cmd.exe /c "`"$launcher`" stop" 2>&1 | Out-Null
    Write-Good 'stopped the bridge'
}

Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like '*pwbridge-tab*server.ps1*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Write-Good "stopped pid $($_.ProcessId)"
    }

# v0.1 registered a logon Scheduled Task; v0.2 never does, but clean it up.
if (Get-ScheduledTask -TaskName 'pwbridge-tab') {
    Unregister-ScheduledTask -TaskName 'pwbridge-tab' -Confirm:$false
    Write-Good 'removed the legacy Scheduled Task'
}

foreach ($path in @($startMenuDir, $legacyLnk, $desktopLnk)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-Good "removed $path"
    }
}

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
    Write-Good "removed $installDir"
}

# v0.1 installed the program into the state directory; only delete files there
# that are ours, and only when the caller wants the state gone too.
if (-not $KeepState) {
    if (Test-Path -LiteralPath $legacyDir) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force
        Write-Good "removed $legacyDir (token, logs, downloaded tools)"
    }
} else {
    Write-Host "Kept $legacyDir"
}

Write-Host 'Done. The cloned repo folder is untouched.' -ForegroundColor Cyan
