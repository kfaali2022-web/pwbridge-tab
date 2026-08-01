# pwbridge-tab control script.
#
# This is what every shortcut runs. It is deliberately written for Windows
# PowerShell 5.1, which ships with Windows 11, so a tester never has to install
# PowerShell 7, Node.js or Git before testing.
#
#   pwbridge.ps1 start        first-run setup if needed, then start and open the tab
#   pwbridge.ps1 stop         stop the bridge and anything it launched
#   pwbridge.ps1 status       show whether the bridge is running and healthy
#   pwbridge.ps1 setup        re-download and re-verify the Android tools
#   pwbridge.ps1 doctor       check prerequisites and the phone connection
#   pwbridge.ps1 logs         show the recent log
#   pwbridge.ps1 diagnostics  write a diagnostics zip and open its folder
#   pwbridge.ps1 open         open the browser tab for an already running bridge

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status', 'setup', 'doctor', 'logs', 'diagnostics', 'open')]
    [string]$Command = 'start',

    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$Force,
    [switch]$KeepOpen
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$appRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $appRoot 'server\modules\PwBridge.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $appRoot 'server\modules\PwBridge.Android.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $appRoot 'server\modules\PwBridge.Shell.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PwBridge.Deps.psm1') -Force -DisableNameChecking

$config = Get-PwBridgeConfig -Port $Port
$stateDir = $config.stateDir
$runtimeDir = Join-Path $stateDir 'runtime'
$logPath = Get-PwBridgeLogPath
$serverScript = Join-Path $appRoot 'server\server.ps1'
$baseUrl = "http://127.0.0.1:$($config.port)"

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }
function Write-Good { param([string]$Text) Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Bad { param([string]$Text) Write-Host "  [!!] $Text" -ForegroundColor Red }
function Write-Warn { param([string]$Text) Write-Host "  [--] $Text" -ForegroundColor Yellow }

function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Get-BridgeHealth {
    <#
    .SYNOPSIS
        Returns the /api/health payload, or $null when the bridge is not up.
    #>
    param([int]$TimeoutSec = 3)
    try {
        return Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec $TimeoutSec `
            -Headers @{ 'X-PwBridge-Token' = $config.token } -UseBasicParsing
    } catch {
        return $null
    }
}

function Get-BridgeProcessId {
    $pidFile = Get-PwBridgePidPath
    if (-not (Test-Path -LiteralPath $pidFile)) { return 0 }
    $raw = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($raw -notmatch '^\d+$') { return 0 }
    $candidate = [int]$raw
    if (-not (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { return 0 }
    return $candidate
}

function Open-BridgeTab {
    # The token travels in the URL because that is the only way to hand it to a
    # freshly opened tab. It never leaves loopback.
    $url = "$baseUrl/?token=$([System.Uri]::EscapeDataString($config.token))"
    Start-Process $url | Out-Null
    Write-Good "Opened $baseUrl in your browser."
}

function Initialize-Runtime {
    param([switch]$ForceDownload)

    Write-Banner 'Checking the Android tools'
    $status = Get-PwBridgeRuntimeStatus -RuntimeDir $runtimeDir
    if ($status.AdbReady -and $status.ScrcpyReady -and -not $ForceDownload) {
        Write-Good 'adb and scrcpy are installed.'
        return $true
    }

    Write-Step 'Downloading from the official Google and scrcpy release servers.'
    Write-Step 'Each file is checked against a known SHA-256 before it is used.'
    $outcome = Install-PwBridgeRuntime -RuntimeDir $runtimeDir -Force:$ForceDownload
    foreach ($step in $outcome.Steps) { Write-Good $step }

    if (-not $outcome.Ok) {
        Write-Bad 'The Android tools could not be installed.'
        foreach ($problem in $outcome.Errors) { Write-Bad $problem }
        Write-Host ''
        Write-Warn 'The PowerShell tab will still work. Phone mirroring will not.'
        Write-Warn 'Check your internet connection, then run "Repair pwbridge-tab" from the Start Menu.'
        return $false
    }
    return $true
}

function Show-DeviceState {
    $adb = Get-AndroidToolPath -Tool 'adb' -RuntimeDir $runtimeDir
    if (-not $adb) {
        Write-Bad 'adb is not installed yet. Run "Repair pwbridge-tab" from the Start Menu.'
        return
    }
    $devices = @(Get-AndroidDevices -AdbPath $adb)
    $resolved = Resolve-AndroidDevice -Devices $devices

    switch ($resolved.Status) {
        'ready' {
            Write-Good $resolved.Message
            foreach ($device in $devices) {
                $label = if ($device.Model) { $device.Model } else { '(unknown model)' }
                Write-Step "$label - $($device.State)"
            }
        }
        default {
            Write-Warn $resolved.Message
            if ($resolved.Hint) { Write-Step $resolved.Hint }
            foreach ($device in $devices) { Write-Step "$($device.Serial) - $($device.State)" }
        }
    }
}

function Stop-Bridge {
    $stopped = $false

    try {
        Invoke-RestMethod -Uri "$baseUrl/api/control/shutdown" -Method Post -TimeoutSec 4 `
            -Headers @{ 'X-PwBridge-Token' = $config.token } -UseBasicParsing | Out-Null
        Start-Sleep -Milliseconds 900
        $stopped = $true
        Write-Good 'Asked the bridge to shut down cleanly.'
    } catch {
        Write-Verbose 'graceful shutdown unavailable'
    }

    $processId = Get-BridgeProcessId
    if ($processId) {
        Stop-PwBridgeProcessTree -ProcessId $processId
        Write-Good "Stopped the bridge process (pid $processId)."
        $stopped = $true
    }

    # Sweep up any scrcpy window we launched from our own runtime folder.
    foreach ($proc in @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.Path -and $proc.Path.StartsWith($runtimeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $proc.Kill()
                Write-Good "Closed scrcpy (pid $($proc.Id))."
                $stopped = $true
            }
        } catch {
            Write-Verbose 'scrcpy already exited'
        }
    }

    Remove-Item -LiteralPath (Get-PwBridgePidPath) -Force -ErrorAction SilentlyContinue
    if (-not $stopped) { Write-Warn 'The bridge was not running.' }
    return $stopped
}

function Start-Bridge {
    Write-Banner 'Starting pwbridge-tab'

    $existing = Get-BridgeHealth
    if ($existing) {
        Write-Good "Already running on port $($config.port)."
        if (-not $NoBrowser) { Open-BridgeTab }
        return $true
    }

    if (-not (Test-Path -LiteralPath $serverScript)) {
        Write-Bad "Installation is incomplete: $serverScript is missing."
        return $false
    }

    $shell = Resolve-PwBridgeShell -Prefer $config.preferShell
    if (-not $shell.Path) {
        Write-Bad 'No PowerShell executable was found. This is unexpected on Windows 11.'
        return $false
    }
    Write-Good "Using $($shell.Name) for the shell tab."

    $hostExe = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$serverScript`"",
        '-Port', $config.port
    ) -join ' '

    Start-Process -FilePath $hostExe -ArgumentList $arguments -WorkingDirectory $appRoot -WindowStyle Hidden | Out-Null

    Write-Step 'Waiting for the bridge to come up...'
    $health = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 400
        $health = Get-BridgeHealth -TimeoutSec 2
        if ($health) { break }
    }

    if (-not $health) {
        Write-Bad "The bridge did not start within 12 seconds."
        Write-Step "Check the log: $logPath"
        Write-Step "Port $($config.port) may be in use by another program."
        return $false
    }

    Write-Good "Bridge is healthy on $baseUrl"
    if (-not $NoBrowser) { Open-BridgeTab }
    return $true
}

function Show-Status {
    Write-Banner 'pwbridge-tab status'
    $health = Get-BridgeHealth
    if (-not $health) {
        Write-Warn "Not running. Start it from the desktop shortcut, or run: pwbridge.ps1 start"
        Write-Step "Log file: $logPath"
        return
    }
    Write-Good "Running on $baseUrl (version $($health.version))"
    Write-Step "Shell        : $($health.shellName)"
    Write-Step "adb          : $(if ($health.adb) { $health.adbPath } else { 'not installed' })"
    Write-Step "scrcpy       : $(if ($health.scrcpy) { $health.scrcpyPath } else { 'not installed' })"
    Write-Step "Mirroring now: $($health.mirroring)"
    Write-Step "Log file     : $($health.logPath)"
}

function Invoke-Doctor {
    Write-Banner 'pwbridge-tab doctor'

    Write-Host ' Windows and PowerShell' -ForegroundColor White
    Write-Step "OS            : $([System.Environment]::OSVersion.VersionString)"
    Write-Step "Host PowerShell: $($PSVersionTable.PSVersion)"
    $shell = Resolve-PwBridgeShell -Prefer $config.preferShell
    if ($shell.Path) { Write-Good "Shell tab will use $($shell.Name)" } else { Write-Bad 'No PowerShell executable found.' }

    Write-Host ''
    Write-Host ' Android tools' -ForegroundColor White
    $status = Get-PwBridgeRuntimeStatus -RuntimeDir $runtimeDir
    if ($status.AdbReady) { Write-Good "adb    : $($status.AdbPath)" } else { Write-Bad 'adb is not installed.' }
    if ($status.ScrcpyReady) { Write-Good "scrcpy : $($status.ScrcpyPath)" } else { Write-Warn 'scrcpy is not installed; browser preview only.' }

    Write-Host ''
    Write-Host ' Phone' -ForegroundColor White
    Show-DeviceState

    Write-Host ''
    Write-Host ' Bridge' -ForegroundColor White
    $health = Get-BridgeHealth
    if ($health) { Write-Good "Running on $baseUrl" } else { Write-Warn 'Not running.' }

    Write-Host ''
    Write-Host ' ws-scrcpy (optional, only if you already run one)' -ForegroundColor White
    $ws = Test-WsScrcpyEndpoint
    if ($ws.Available) { Write-Good "Detected at $($ws.Url)" } else { Write-Step 'Not running. pwbridge-tab does not need it.' }
}

function Show-Logs {
    Write-Banner 'Recent log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-Warn "No log yet at $logPath"
        return
    }
    Get-Content -LiteralPath $logPath -Tail 120
    Write-Host ''
    Write-Step "Full log: $logPath"
}

function Export-Diagnostics {
    Write-Banner 'Diagnostics'
    $health = Get-BridgeHealth
    if ($health) {
        $outDir = Join-Path $stateDir 'diagnostics'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $file = Join-Path $outDir ("pwbridge-diagnostics-{0}.zip" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        Invoke-WebRequest -Uri "$baseUrl/api/diagnostics" -OutFile $file -TimeoutSec 30 `
            -Headers @{ 'X-PwBridge-Token' = $config.token } -UseBasicParsing
        Write-Good "Wrote $file"
        Start-Process (Split-Path -Parent $file) | Out-Null
        return
    }

    # The bridge is down, so collect what we can without it.
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "pwbridge-diag-$stamp"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $summary = [ordered]@{
        generated = (Get-Date).ToString('o')
        note      = 'Collected while the bridge was not running.'
        os        = [System.Environment]::OSVersion.VersionString
        psVersion = $PSVersionTable.PSVersion.ToString()
        runtime   = (Get-PwBridgeRuntimeStatus -RuntimeDir $runtimeDir)
        port      = $config.port
    }
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $stage 'summary.json') -Encoding UTF8
    if (Test-Path -LiteralPath $logPath) { Copy-Item -LiteralPath $logPath -Destination $stage -ErrorAction SilentlyContinue }

    $outDir = Join-Path $stateDir 'diagnostics'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $zip = Join-Path $outDir "pwbridge-diagnostics-$stamp.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Good "Wrote $zip"
    Start-Process $outDir | Out-Null
}

$exitCode = 0
try {
    switch ($Command) {
        'start' {
            Write-Host ''
            Write-Host ' pwbridge-tab' -ForegroundColor Cyan
            Write-Host ' A PowerShell console and your Android phone, both in a browser tab.' -ForegroundColor Gray
            Write-Host ''
            Write-Host ' WARNING: the PowerShell tab is a real, live shell on this PC.' -ForegroundColor Yellow
            Write-Host ' Anything typed there runs immediately as your Windows user.' -ForegroundColor Yellow

            $null = Initialize-Runtime
            if (-not (Start-Bridge)) { $exitCode = 1 }
            else {
                Write-Banner 'Phone'
                Show-DeviceState
                Write-Host ''
                Write-Host ' You can close this window; the bridge keeps running.' -ForegroundColor Gray
                Write-Host ' Use the "Stop pwbridge-tab" shortcut when you are finished.' -ForegroundColor Gray
            }
        }
        'stop' { Write-Banner 'Stopping pwbridge-tab'; $null = Stop-Bridge }
        'status' { Show-Status }
        'setup' {
            Write-Banner 'Repairing pwbridge-tab'
            if (Initialize-Runtime -ForceDownload:$Force) { Write-Good 'Android tools are ready.' } else { $exitCode = 1 }
        }
        'doctor' { Invoke-Doctor }
        'logs' { Show-Logs }
        'diagnostics' { Export-Diagnostics }
        'open' {
            if (Get-BridgeHealth) { Open-BridgeTab } else { Write-Bad 'The bridge is not running. Start it first.' ; $exitCode = 1 }
        }
    }
} catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Step "Log file: $logPath"
    Write-PwBridgeLog -Level 'ERROR' -Message "cli '$Command' failed: $($_.Exception.Message)"
    $exitCode = 1
}

if ($KeepOpen -or ($exitCode -ne 0 -and $Command -eq 'start')) {
    Write-Host ''
    Write-Host 'Press Enter to close this window.' -ForegroundColor Gray
    [void](Read-Host)
}
exit $exitCode
