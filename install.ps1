# pwbridge-tab installer (Windows). MIT License.
# One command setup: verifies prerequisites, installs a Start Menu shortcut and
# a Scheduled Task to run the bridge, then opens the tab in your browser.
#
# Run from the repo root:
#   pwsh -ExecutionPolicy Bypass -File .\install.ps1
#
# Options:
#   -Port <int>       Port to listen on (default 8765)
#   -Token <string>   Optional shared token for WS auth
#   -AutoStart        Register a logon Scheduled Task so the bridge starts at login

param(
  [int]$Port = 8765,
  [string]$Token = "",
  [switch]$AutoStart
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$server = Join-Path $repoRoot "server\server.ps1"
$installDir = Join-Path $env:LOCALAPPDATA "pwbridge-tab"

function Assert-File($path) {
  if (-not (Test-Path $path)) { throw "Missing required file: $path" }
  Write-Host "[ok] found $path" -ForegroundColor Green
}

Write-Host "== pwbridge-tab install ==" -ForegroundColor Cyan

# 1. Verify prerequisites.
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
  Write-Warning "PowerShell 7 (pwsh) not found. Install it: winget install --id Microsoft.PowerShell"
  throw "pwsh is required."
}
Write-Host "[ok] pwsh at $($pwsh.Source)" -ForegroundColor Green

Assert-File $server
Assert-File (Join-Path $repoRoot "web\index.html")
Assert-File (Join-Path $repoRoot "web\app.js")

# 2. Copy files to a stable install dir (so updates to the clone don't break shortcuts).
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item (Join-Path $repoRoot "server") $installDir -Recurse
Copy-Item (Join-Path $repoRoot "web") $installDir -Recurse
Write-Host "[ok] copied files to $installDir" -ForegroundColor Green

# 3. Build the launch command.
$serverPath = Join-Path $installDir "server\server.ps1"
$argList = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$serverPath`" -Port $Port"
if ($Token) { $argList += " -Token `"$Token`"" }

# 4. Create a Start Menu shortcut.
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$lnk = Join-Path $startMenu "pwbridge-tab.lnk"
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($lnk)
$sc.TargetPath = $pwsh.Source
$sc.Arguments = $argList
$sc.WorkingDirectory = $installDir
$sc.Description = "Start the pwbridge-tab local PowerShell bridge"
$sc.Save()
if (Test-Path $lnk) { Write-Host "[ok] Start Menu shortcut created" -ForegroundColor Green } else { throw "Shortcut not created." }

# 5. Optional: register a logon Scheduled Task.
if ($AutoStart) {
  $action = New-ScheduledTaskAction -Execute $pwsh.Source -Argument $argList -WorkingDirectory $installDir
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
  Register-ScheduledTask -TaskName "pwbridge-tab" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
  if (Get-ScheduledTask -TaskName "pwbridge-tab" -ErrorAction SilentlyContinue) {
    Write-Host "[ok] AutoStart task registered" -ForegroundColor Green
  } else { throw "Failed to register Scheduled Task." }
}

# 6. Start the bridge now and open the tab.
Start-Process -FilePath $pwsh.Source -ArgumentList $argList -WorkingDirectory $installDir
Start-Sleep -Seconds 2
$url = "http://127.0.0.1:$Port/"
Start-Process $url

Write-Host ""
Write-Host "Done. Bridge running at $url" -ForegroundColor Cyan
Write-Host "If the tab did not open, browse to $url manually and click Connect."
if ($Token) { Write-Host "Enter your token ($Token) in the Token field before connecting." -ForegroundColor Yellow }
