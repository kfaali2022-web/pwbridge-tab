# pwbridge-tab server
#
# Loopback HTTP + WebSocket bridge that serves the browser UI, streams a live
# PowerShell session and exposes a token-protected Android control API.
#
# Runs on Windows PowerShell 5.1 (built into Windows 11) or PowerShell 7.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File server\server.ps1 [-Port 8765]
#
# The token is read from %LOCALAPPDATA%\pwbridge-tab\config.json and generated
# on first run; -Token only overrides it for a single session.

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$Bind = '127.0.0.1',
    [string]$Token = '',
    [string]$WebRoot = '',
    [string]$RuntimeDir = '',
    [string]$StateDir = '',
    [int]$MaxConcurrency = 12
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# A shell reachable from the network is a remote code execution service. The
# bind address is validated before anything else happens.
if ($Bind -ne '127.0.0.1' -and $Bind -ne 'localhost') {
    Write-Error 'Refusing to bind to a non-loopback address: that would expose a shell to your network.'
    exit 1
}

$moduleDir = Join-Path $PSScriptRoot 'modules'
$modules = @(
    (Join-Path $moduleDir 'PwBridge.Common.psm1')
    (Join-Path $moduleDir 'PwBridge.Android.psm1')
    (Join-Path $moduleDir 'PwBridge.Http.psm1')
    (Join-Path $moduleDir 'PwBridge.Shell.psm1')
)
foreach ($module in $modules) {
    if (-not (Test-Path -LiteralPath $module)) { throw "Missing module: $module" }
    Import-Module $module -Force -DisableNameChecking
}

if (-not $WebRoot) { $WebRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'web' }
if (-not (Test-Path -LiteralPath $WebRoot)) { throw "Web root not found: $WebRoot" }
$WebRoot = (Resolve-Path -LiteralPath $WebRoot).ProviderPath

$config = Get-PwBridgeConfig -StateDir $StateDir -Port $Port
if ($Token) { $config.token = $Token }
if (-not $RuntimeDir) { $RuntimeDir = Join-Path $config.stateDir 'runtime' }
$logPath = Get-PwBridgeLogPath -StateDir $StateDir

$shell = Resolve-PwBridgeShell -Prefer $config.preferShell

$state = [hashtable]::Synchronized(@{
        Config         = $config
        WebRoot        = $WebRoot
        RuntimeDir     = $RuntimeDir
        LogPath        = $logPath
        Version        = Get-PwBridgeVersion
        AdbPath        = (Get-AndroidToolPath -Tool 'adb' -RuntimeDir $RuntimeDir)
        ScrcpyPath     = (Get-AndroidToolPath -Tool 'scrcpy' -RuntimeDir $RuntimeDir)
        ShellPath      = $shell.Path
        ShellName      = $shell.Name
        SelectedSerial = ''
        ScrcpyPid      = 0
        Shutdown       = $false
        Listener       = $null
    })

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${Bind}:$($config.port)/")
try {
    $listener.Start()
} catch {
    Write-PwBridgeLog -Level 'ERROR' -Path $logPath -Message "listener failed on port $($config.port): $($_.Exception.Message)"
    Write-Error "Could not listen on port $($config.port). Another program may already be using it. Details: $($_.Exception.Message)"
    exit 2
}
$state.Listener = $listener

Set-Content -LiteralPath (Get-PwBridgePidPath -StateDir $StateDir) -Value $PID -Encoding ASCII

$adbLabel = if ($state.AdbPath) { 'yes' } else { 'no' }
$scrcpyLabel = if ($state.ScrcpyPath) { 'yes' } else { 'no' }
Write-PwBridgeLog -Path $logPath -Message "pwbridge-tab $($state.Version) listening on http://${Bind}:$($config.port)/ (shell: $($shell.Name), adb: $adbLabel, scrcpy: $scrcpyLabel)"
Write-Host "pwbridge-tab $($state.Version) listening on http://${Bind}:$($config.port)/" -ForegroundColor Green
Write-Host "Shell: $($shell.Name)  |  adb: $adbLabel  |  scrcpy: $scrcpyLabel"
Write-Host 'Token auth is enabled. Close this window or press Ctrl+C to stop.' -ForegroundColor Yellow

# Each request is handled in its own runspace, otherwise a long-lived WebSocket
# shell session would block every other request (including the phone tab).
$initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$initialState.ImportPSModule($modules)
$pool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrency, $initialState, $Host)
$pool.Open()

$handler = {
    param($Context, $State)

    Set-StrictMode -Version 2.0
    $path = $Context.Request.Url.AbsolutePath
    $port = $State.Config.port

    try {
        if ($Context.Request.IsWebSocketRequest) {
            if (-not (Test-PwBridgeAuthorized -Request $Context.Request -Token $State.Config.token -Port $port)) {
                Write-PwBridgeLog -Level 'WARN' -Path $State.LogPath -Message 'rejected unauthenticated WebSocket handshake'
                $Context.Response.StatusCode = 401
                $Context.Response.Close()
                return
            }
            $wsContext = $Context.AcceptWebSocketAsync($null).GetAwaiter().GetResult()
            $cts = New-Object System.Threading.CancellationTokenSource
            try {
                Start-PwBridgeShellSession -Socket $wsContext.WebSocket -CancelToken $cts.Token -State $State
            } finally {
                $cts.Dispose()
            }
            return
        }

        Set-PwBridgeSecurityHeader -Response $Context.Response -Port $port

        if ($path -like '/api/*') {
            if (-not (Test-PwBridgeAuthorized -Request $Context.Request -Token $State.Config.token -Port $port)) {
                Write-PwBridgeError -Context $Context -StatusCode 401 `
                    -Message 'Unauthorized.' -Hint 'Open pwbridge-tab from its shortcut so the local token is supplied.'
                return
            }
            $null = Invoke-PwBridgeApi -Context $Context -Path $path -State $State
            return
        }

        Send-PwBridgeStaticFile -Context $Context -RequestPath $path -WebRoot $State.WebRoot
    } catch {
        Write-PwBridgeLog -Level 'ERROR' -Path $State.LogPath -Message "handler error on ${path}: $($_.Exception.Message)"
        try {
            $Context.Response.StatusCode = 500
            $Context.Response.Close()
        } catch {
            Write-Verbose 'response already closed'
        }
    }
}

$inFlight = New-Object System.Collections.ArrayList

function Remove-CompletedHandler {
    param($Tracked)
    foreach ($item in @($Tracked.ToArray())) {
        if ($item.Handle.IsCompleted) {
            try { $item.Runner.EndInvoke($item.Handle) } catch { Write-Verbose 'handler ended with error' }
            $item.Runner.Dispose()
            $Tracked.Remove($item)
        }
    }
}

try {
    while ($listener.IsListening -and -not $state.Shutdown) {
        $contextTask = $listener.GetContextAsync()
        while (-not $contextTask.Wait(500)) {
            if ($state.Shutdown -or -not $listener.IsListening) { break }
            Remove-CompletedHandler -Tracked $inFlight
        }
        if (-not $contextTask.IsCompleted -or $state.Shutdown) { break }

        $context = $contextTask.Result
        $runner = [powershell]::Create()
        $runner.RunspacePool = $pool
        $null = $runner.AddScript($handler).AddArgument($context).AddArgument($state)
        $null = $inFlight.Add(@{ Runner = $runner; Handle = $runner.BeginInvoke() })
        Remove-CompletedHandler -Tracked $inFlight
    }
} catch [System.Net.HttpListenerException] {
    Write-PwBridgeLog -Path $logPath -Message 'listener closed'
} finally {
    Write-PwBridgeLog -Path $logPath -Message 'shutting down'
    $null = Stop-PwBridgeScrcpy -State $state
    foreach ($item in @($inFlight.ToArray())) {
        try { $item.Runner.Stop() } catch { Write-Verbose 'handler already stopped' }
        try { $item.Runner.Dispose() } catch { Write-Verbose 'handler already disposed' }
    }
    try { $pool.Close(); $pool.Dispose() } catch { Write-Verbose 'pool already closed' }
    try { $listener.Stop(); $listener.Close() } catch { Write-Verbose 'listener already closed' }
    Remove-Item -LiteralPath (Get-PwBridgePidPath -StateDir $StateDir) -Force -ErrorAction SilentlyContinue
    Write-Host 'pwbridge-tab stopped.' -ForegroundColor Cyan
}
