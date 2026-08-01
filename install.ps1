# pwbridge-tab source install (Windows). MIT License.
#
# This is the developer path: install straight from a clone, with no Inno Setup
# and no EXE. Testers should use the setup EXE from the releases page instead
# (see docs/TESTER-GUIDE.md); it does the same thing with a real uninstaller.
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Options:
#   -Port <int>    Port to listen on (default: keep whatever config.json says,
#                  or 8765 on a fresh machine)
#   -NoStart       Install the files and shortcuts but do not launch
#   -NoDesktop     Skip the desktop shortcut

[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoStart,
    [switch]$NoDesktop
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\pwbridge-tab'
$stateDir = Join-Path $env:LOCALAPPDATA 'pwbridge-tab'

function Write-Good { param([string]$Text) Write-Host "[ok] $Text" -ForegroundColor Green }

Write-Host '== pwbridge-tab source install ==' -ForegroundColor Cyan

foreach ($required in @(
        'server\server.ps1'
        'server\modules\PwBridge.Common.psm1'
        'tools\pwbridge.ps1'
        'tools\pwbridge.cmd'
        'tools\deps.json'
        'web\index.html'
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required))) {
        throw "Missing required file: $required. Run this from the repository root."
    }
}
Write-Good 'source tree looks complete'

# Stop a previous install before overwriting it, otherwise the old process keeps
# the port and the files stay locked.
$previousLauncher = Join-Path $installDir 'tools\pwbridge.cmd'
if (Test-Path -LiteralPath $previousLauncher) {
    & cmd.exe /c "`"$previousLauncher`" stop" 2>&1 | Out-Null
    Write-Good 'stopped the previous install'
}

if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

foreach ($dir in @('server', 'web', 'tools', 'docs')) {
    $source = Join-Path $repoRoot $dir
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $installDir -Recurse -Force }
}
foreach ($file in @('LICENSE', 'README.md', 'SECURITY.md', 'THIRD-PARTY-NOTICES.md')) {
    $source = Join-Path $repoRoot $file
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $installDir -Force }
}
$iconSource = Join-Path $repoRoot 'installer\assets\pwbridge.ico'
if (Test-Path -LiteralPath $iconSource) {
    $iconDir = Join-Path $installDir 'installer\assets'
    New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    Copy-Item -LiteralPath $iconSource -Destination $iconDir -Force
}
Write-Good "copied files to $installDir"

if ($Port -gt 0) {
    Import-Module (Join-Path $installDir 'server\modules\PwBridge.Common.psm1') -Force -DisableNameChecking
    $config = Get-PwBridgeConfig -Port $Port
    Save-PwBridgeConfig -Config $config
    Write-Good "port set to $Port"
}

$launcher = Join-Path $installDir 'tools\pwbridge.cmd'
$shell = New-Object -ComObject WScript.Shell

function New-PwBridgeShortcut {
    param([string]$Path, [string]$Arguments, [string]$Description)
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $launcher
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = $Description
    $icon = Join-Path $installDir 'installer\assets\pwbridge.ico'
    if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = $icon }
    $shortcut.Save()
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\pwbridge-tab'
if (-not (Test-Path -LiteralPath $startMenu)) { New-Item -ItemType Directory -Path $startMenu -Force | Out-Null }

New-PwBridgeShortcut -Path (Join-Path $startMenu 'pwbridge-tab.lnk') -Arguments 'start' -Description 'Start the bridge and open the browser tab'
New-PwBridgeShortcut -Path (Join-Path $startMenu 'Stop pwbridge-tab.lnk') -Arguments 'stop' -Description 'Stop the bridge and close anything it started'
New-PwBridgeShortcut -Path (Join-Path $startMenu 'pwbridge-tab Doctor.lnk') -Arguments 'doctor' -Description 'Check prerequisites and the phone connection'
New-PwBridgeShortcut -Path (Join-Path $startMenu 'pwbridge-tab Diagnostics.lnk') -Arguments 'diagnostics' -Description 'Save a diagnostics zip to send for support'
Write-Good 'Start Menu shortcuts created'

if (-not $NoDesktop) {
    $desktop = [System.Environment]::GetFolderPath('Desktop')
    New-PwBridgeShortcut -Path (Join-Path $desktop 'pwbridge-tab.lnk') -Arguments 'start' -Description 'Start the bridge and open the browser tab'
    Write-Good 'desktop shortcut created'
}

Write-Host ''
Write-Host 'WARNING: the PowerShell tab is a real, live shell on this PC.' -ForegroundColor Yellow
Write-Host 'Anything typed there runs immediately as your Windows user.' -ForegroundColor Yellow
Write-Host ''
Write-Host "Installed to $installDir"
Write-Host "State (token, logs, downloaded tools) lives in $stateDir"

if ($NoStart) {
    Write-Host 'Start it with the "pwbridge-tab" shortcut, or tools\pwbridge.cmd start.'
    return
}

& cmd.exe /c "`"$launcher`" start"
