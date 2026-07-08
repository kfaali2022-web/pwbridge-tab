# pwbridge-tab uninstaller (Windows). MIT License.
# Removes the Scheduled Task, Start Menu shortcut, and installed files.
#
#   pwsh -ExecutionPolicy Bypass -File .\uninstall.ps1

$ErrorActionPreference = "SilentlyContinue"
$installDir = Join-Path $env:LOCALAPPDATA "pwbridge-tab"
$lnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\pwbridge-tab.lnk"

Write-Host "== pwbridge-tab uninstall ==" -ForegroundColor Cyan

# Stop any running bridge processes on this repo's server.ps1.
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*pwbridge-tab*server.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "[ok] stopped pid $($_.ProcessId)" -ForegroundColor Green }

# Remove the Scheduled Task if present.
if (Get-ScheduledTask -TaskName "pwbridge-tab") {
  Unregister-ScheduledTask -TaskName "pwbridge-tab" -Confirm:$false
  Write-Host "[ok] removed Scheduled Task" -ForegroundColor Green
}

# Remove the Start Menu shortcut.
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "[ok] removed shortcut" -ForegroundColor Green }

# Remove installed files.
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force; Write-Host "[ok] removed $installDir" -ForegroundColor Green }

Write-Host "Done. pwbridge-tab has been removed. The cloned repo folder is untouched." -ForegroundColor Cyan
