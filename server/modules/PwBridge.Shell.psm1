# PwBridge.Shell - the WebSocket <-> PowerShell bridge.
#
# Wire protocol (unchanged from v0.1, plus additive frame types):
#   browser -> server : {"type":"exec","data":"Get-Date"} | {"type":"interrupt"}
#   server  -> browser: {"type":"stdout"|"stderr"|"info","data":"..."}
#
# Must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

function Resolve-PwBridgeShell {
    <#
    .SYNOPSIS
        Prefers PowerShell 7 and falls back to Windows PowerShell so the tester
        never has to install anything to get a working shell tab.
    #>
    param([ValidateSet('auto', 'pwsh', 'powershell')][string]$Prefer = 'auto')

    $candidates = @()
    switch ($Prefer) {
        'pwsh' { $candidates = @('pwsh') }
        'powershell' { $candidates = @('powershell') }
        default { $candidates = @('pwsh', 'powershell') }
    }

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $friendly = if ($name -eq 'pwsh') { 'PowerShell 7' } else { 'Windows PowerShell 5.1' }
            return @{ Path = $cmd.Source; Name = $friendly; Id = $name }
        }
    }
    return @{ Path = ''; Name = 'none'; Id = '' }
}

function New-PwBridgeShellProcess {
    param([Parameter(Mandatory)][string]$ShellPath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ShellPath
    $psi.Arguments = '-NoLogo -NoProfile -Command -'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    return [System.Diagnostics.Process]::Start($psi)
}

# Runs in its own runspace: forwards one stream to the socket. Sends are
# serialised through $SendLock because a WebSocket allows only one in-flight
# send at a time.
$script:PumpScript = {
    param($Reader, $Socket, $Channel, $CancelToken, $SendLock)

    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { break }
        if ($Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }

        $payload = ([ordered]@{ type = $Channel; data = $line } | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [System.ArraySegment[byte]]::new($bytes)

        [System.Threading.Monitor]::Enter($SendLock)
        try {
            $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $CancelToken).Wait()
        } catch {
            break
        } finally {
            [System.Threading.Monitor]::Exit($SendLock)
        }
    }
}

function Send-PwBridgeFrame {
    param(
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Data,
        [Parameter(Mandatory)]$CancelToken,
        [Parameter(Mandatory)]$SendLock
    )

    if ($Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return }
    $json = ([ordered]@{ type = $Type; data = $Data } | ConvertTo-Json -Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    [System.Threading.Monitor]::Enter($SendLock)
    try {
        $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $CancelToken).Wait()
    } catch {
        Write-Verbose 'send failed; socket closing'
    } finally {
        [System.Threading.Monitor]::Exit($SendLock)
    }
}

function Start-PwBridgeStreamPump {
    <#
    .SYNOPSIS
        Starts one background runspace per stream (stdout, stderr) forwarding
        lines to the socket.
    #>
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)]$CancelToken,
        [Parameter(Mandatory)]$SendLock
    )

    $pumps = @()
    foreach ($pair in @(@($Process.StandardOutput, 'stdout'), @($Process.StandardError, 'stderr'))) {
        $runner = [powershell]::Create()
        $null = $runner.AddScript($script:PumpScript).
            AddArgument($pair[0]).AddArgument($Socket).AddArgument($pair[1]).
            AddArgument($CancelToken).AddArgument($SendLock)
        $pumps += @{ Runner = $runner; Handle = $runner.BeginInvoke() }
    }
    return $pumps
}

function Start-PwBridgeShellSession {
    <#
    .SYNOPSIS
        Owns one WebSocket connection: spawns a shell, streams its output and
        applies commands until the socket closes.
    #>
    param(
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)]$CancelToken,
        [Parameter(Mandatory)]$State
    )

    $shell = Resolve-PwBridgeShell -Prefer $State.Config.preferShell
    if (-not $shell.Path) {
        throw 'No PowerShell executable found.'
    }

    $sendLock = New-Object System.Object
    $pumps = @()
    $proc = New-PwBridgeShellProcess -ShellPath $shell.Path
    Write-PwBridgeLog -Path $State.LogPath -Message "shell session started: $($shell.Name) pid $($proc.Id)"

    $pumps += Start-PwBridgeStreamPump -Process $proc -Socket $Socket -CancelToken $CancelToken -SendLock $sendLock

    Send-PwBridgeFrame -Socket $Socket -Type 'info' -CancelToken $CancelToken -SendLock $sendLock `
        -Data "Connected to $($shell.Name). Commands run locally as $env:USERNAME."

    $buffer = New-Object byte[] 65536
    try {
        while ($Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $segment = [System.ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, $CancelToken).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }

            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $message = $null
            try { $message = $text | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($message.PSObject.Properties.Name -notcontains 'type') { continue }

            switch ($message.type) {
                'exec' {
                    if ($proc.HasExited) {
                        $proc = New-PwBridgeShellProcess -ShellPath $shell.Path
                        $pumps += Start-PwBridgeStreamPump -Process $proc -Socket $Socket -CancelToken $CancelToken -SendLock $sendLock
                        Send-PwBridgeFrame -Socket $Socket -Type 'info' -Data 'Shell restarted.' `
                            -CancelToken $CancelToken -SendLock $sendLock
                    }
                    $proc.StandardInput.WriteLine([string]$message.data)
                    $proc.StandardInput.Flush()
                }
                'interrupt' {
                    # There is no portable way to deliver Ctrl+C to a redirected
                    # child, so the session is recycled instead of silently dying.
                    Stop-PwBridgeProcessTree -ProcessId $proc.Id
                    Send-PwBridgeFrame -Socket $Socket -Type 'info' -Data 'Interrupted. Starting a fresh shell...' `
                        -CancelToken $CancelToken -SendLock $sendLock
                    $proc = New-PwBridgeShellProcess -ShellPath $shell.Path
                    $pumps += Start-PwBridgeStreamPump -Process $proc -Socket $Socket -CancelToken $CancelToken -SendLock $sendLock
                }
                default { }
            }
        }
    } finally {
        if ($proc -and -not $proc.HasExited) { Stop-PwBridgeProcessTree -ProcessId $proc.Id }
        foreach ($pump in $pumps) {
            try { $pump.Runner.Stop() } catch { Write-Verbose 'pump already stopped' }
            try { $pump.Runner.Dispose() } catch { Write-Verbose 'pump already disposed' }
        }
        if ($proc) { $proc.Dispose() }
        Write-PwBridgeLog -Path $State.LogPath -Message 'shell session ended'
    }
}

function Stop-PwBridgeProcessTree {
    <#
    .SYNOPSIS
        Kills a process and its children so a long-running command cannot
        outlive the tab that started it.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in @($children)) {
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Verbose 'child enumeration unavailable'
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function @(
    'Resolve-PwBridgeShell'
    'New-PwBridgeShellProcess'
    'Send-PwBridgeFrame'
    'Start-PwBridgeStreamPump'
    'Start-PwBridgeShellSession'
    'Stop-PwBridgeProcessTree'
)
