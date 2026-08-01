# PwBridge.Http - request authentication, static file serving and the JSON API.
# Must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

$script:MaxBodyBytes = 65536

function Set-PwBridgeSecurityHeader {
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][int]$Port)

    # Only our own origin may frame or feed this UI. ws-scrcpy is allowed as a
    # frame source because the phone tab can embed one the tester already runs.
    $csp = "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; " +
    "script-src 'self'; connect-src 'self' ws://127.0.0.1:$Port ws://localhost:$Port; " +
    "frame-src http://127.0.0.1:8000 http://localhost:8000; frame-ancestors 'self'; base-uri 'none'"
    $Response.Headers['Content-Security-Policy'] = $csp
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Cache-Control'] = 'no-store'
}

function Write-PwBridgeJson {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Body,
        [int]$StatusCode = 200
    )

    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Write-PwBridgeBytes {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$ContentType = 'application/octet-stream',
        [string]$FileName
    )

    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    if ($FileName) {
        $Context.Response.Headers['Content-Disposition'] = "attachment; filename=`"$FileName`""
    }
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

function Write-PwBridgeError {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Message,
        [int]$StatusCode = 400,
        [string]$Hint = ''
    )
    Write-PwBridgeJson -Context $Context -StatusCode $StatusCode -Body ([ordered]@{
            ok    = $false
            error = $Message
            hint  = $Hint
        })
}

function Get-PwBridgeRequestToken {
    <#
    .SYNOPSIS
        Reads the token from the X-PwBridge-Token header or the ?token= query.
        WebSocket clients must use the query form: browsers cannot set headers
        on a WebSocket handshake.
    #>
    param([Parameter(Mandatory)]$Request)

    $header = $Request.Headers['X-PwBridge-Token']
    if ($header) { return $header }
    $query = $Request.QueryString['token']
    if ($query) { return $query }
    return ''
}

function Test-PwBridgeAuthorized {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$Port
    )

    if (-not (Test-PwBridgeOrigin -Origin $Request.Headers['Origin'] -Port $Port)) { return $false }
    return (Test-PwBridgeTokenMatch -Expected $Token -Actual (Get-PwBridgeRequestToken -Request $Request))
}

function Get-PwBridgeRequestBody {
    <#
    .SYNOPSIS
        Reads a bounded JSON request body and returns it as a PSCustomObject.
    #>
    param([Parameter(Mandatory)]$Request)

    if (-not $Request.HasEntityBody) { return $null }
    $buffer = New-Object byte[] $script:MaxBodyBytes
    $read = $Request.InputStream.Read($buffer, 0, $script:MaxBodyBytes)
    if ($read -le 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'Request body is not valid JSON.' }
}

function Get-PwBridgeBodyValue {
    <#
    .SYNOPSIS
        Safe property read from a parsed JSON body under StrictMode.
    #>
    param($Body, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($null -eq $Body) { return $Default }
    if ($Body.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Body.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Send-PwBridgeStaticFile {
    <#
    .SYNOPSIS
        Serves a file from the web root, refusing anything that escapes it.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$WebRoot
    )

    $relative = $RequestPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }

    $rootFull = [System.IO.Path]::GetFullPath($WebRoot)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relative))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootFull.TrimEnd($separator) + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-PwBridgeError -Context $Context -Message 'Forbidden path.' -StatusCode 403
        return
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Write-PwBridgeError -Context $Context -Message 'Not found.' -StatusCode 404
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($candidate)
    $Context.Response.ContentType = Get-PwBridgeContentType -Path $candidate
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-PwBridgeContentType {
    param([Parameter(Mandatory)][string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.png' { return 'image/png' }
        '.svg' { return 'image/svg+xml' }
        '.ico' { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

function Get-PwBridgeHealth {
    <#
    .SYNOPSIS
        Snapshot of everything the UI needs to render its status strip.
    #>
    param([Parameter(Mandatory)]$State)

    $adb = $State.AdbPath
    $scrcpy = $State.ScrcpyPath
    return [ordered]@{
        ok        = $true
        app       = 'pwbridge-tab'
        version   = $State.Version
        port      = $State.Config.port
        shell     = $State.ShellPath
        shellName = $State.ShellName
        adb       = [bool]$adb
        adbPath   = if ($adb) { $adb } else { '' }
        scrcpy    = [bool]$scrcpy
        scrcpyPath = if ($scrcpy) { $scrcpy } else { '' }
        mirroring = ($null -ne $State.ScrcpyPid -and 0 -ne $State.ScrcpyPid)
        logPath   = $State.LogPath
        stateDir  = $State.Config.stateDir
    }
}

function Invoke-PwBridgeApi {
    <#
    .SYNOPSIS
        Routes an authenticated /api/* request. Returns $true if handled.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $method = $Context.Request.HttpMethod
    $route = "$method $Path"

    switch -Regex ($route) {

        '^GET /api/health$' {
            Write-PwBridgeJson -Context $Context -Body (Get-PwBridgeHealth -State $State)
            return $true
        }

        '^GET /api/android/devices$' {
            $devices = @()
            if ($State.AdbPath) { $devices = @(Get-AndroidDevices -AdbPath $State.AdbPath) }
            $resolved = Resolve-AndroidDevice -Devices $devices -PreferredSerial $State.SelectedSerial
            if (-not $State.AdbPath) {
                $resolved.Status = 'no-adb'
                $resolved.Message = 'Android tools are not installed yet.'
                $resolved.Hint = 'Run "Repair pwbridge-tab" from the Start Menu to download the Android platform tools.'
            }
            if ($resolved.Status -eq 'ready') { $State.SelectedSerial = $resolved.Serial }

            $info = $null
            if ($resolved.Status -eq 'ready') {
                try { $info = Get-AndroidDeviceInfo -Serial $resolved.Serial -AdbPath $State.AdbPath } catch {
                    Write-PwBridgeLog -Level 'WARN' -Path $State.LogPath -Message "device info failed: $($_.Exception.Message)"
                }
            }

            Write-PwBridgeJson -Context $Context -Body ([ordered]@{
                    ok      = $true
                    status  = $resolved.Status
                    serial  = $resolved.Serial
                    message = $resolved.Message
                    hint    = $resolved.Hint
                    devices = @($devices | ForEach-Object {
                            [ordered]@{ serial = $_.Serial; state = $_.State; model = $_.Model; authorized = $_.Authorized }
                        })
                    info    = $info
                })
            return $true
        }

        '^POST /api/android/select$' {
            $body = Get-PwBridgeRequestBody -Request $Context.Request
            $serial = [string](Get-PwBridgeBodyValue -Body $body -Name 'serial' -Default '')
            if (-not (Test-AndroidSerial -Serial $serial)) {
                Write-PwBridgeError -Context $Context -Message 'Invalid device serial.'
                return $true
            }
            $State.SelectedSerial = $serial
            Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true; serial = $serial })
            return $true
        }

        '^GET /api/android/screen$' {
            if (-not $State.AdbPath) {
                Write-PwBridgeError -Context $Context -Message 'Android tools are not installed.' -StatusCode 503
                return $true
            }
            $serial = $State.SelectedSerial
            if (-not $serial) {
                $resolved = Resolve-AndroidDevice -Devices @(Get-AndroidDevices -AdbPath $State.AdbPath)
                $serial = $resolved.Serial
                if ($serial) { $State.SelectedSerial = $serial }
            }
            if (-not $serial) {
                Write-PwBridgeError -Context $Context -Message 'No authorized device.' -StatusCode 409
                return $true
            }
            try {
                $png = Get-AndroidScreenshot -Serial $serial -AdbPath $State.AdbPath
                Write-PwBridgeBytes -Context $Context -Bytes $png -ContentType 'image/png'
            } catch {
                Write-PwBridgeError -Context $Context -Message $_.Exception.Message -StatusCode 502
            }
            return $true
        }

        '^POST /api/android/input$' {
            if (-not $State.AdbPath) {
                Write-PwBridgeError -Context $Context -Message 'Android tools are not installed.' -StatusCode 503
                return $true
            }
            $serial = $State.SelectedSerial
            if (-not $serial) {
                Write-PwBridgeError -Context $Context -Message 'No device selected.' -StatusCode 409
                return $true
            }
            $body = Get-PwBridgeRequestBody -Request $Context.Request
            try {
                $null = Invoke-AndroidInput -Serial $serial -AdbPath $State.AdbPath `
                    -Action ([string](Get-PwBridgeBodyValue -Body $body -Name 'action' -Default '')) `
                    -X ([int](Get-PwBridgeBodyValue -Body $body -Name 'x' -Default 0)) `
                    -Y ([int](Get-PwBridgeBodyValue -Body $body -Name 'y' -Default 0)) `
                    -X2 ([int](Get-PwBridgeBodyValue -Body $body -Name 'x2' -Default 0)) `
                    -Y2 ([int](Get-PwBridgeBodyValue -Body $body -Name 'y2' -Default 0)) `
                    -DurationMs ([int](Get-PwBridgeBodyValue -Body $body -Name 'durationMs' -Default 200)) `
                    -Keycode ([string](Get-PwBridgeBodyValue -Body $body -Name 'keycode' -Default '')) `
                    -Text ([string](Get-PwBridgeBodyValue -Body $body -Name 'text' -Default ''))
                Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true })
            } catch {
                Write-PwBridgeError -Context $Context -Message $_.Exception.Message
            }
            return $true
        }

        '^POST /api/android/mirror$' {
            $body = Get-PwBridgeRequestBody -Request $Context.Request
            $serial = $State.SelectedSerial
            if (-not $serial) {
                Write-PwBridgeError -Context $Context -Message 'No device selected.' -StatusCode 409
                return $true
            }
            if (-not $State.ScrcpyPath) {
                Write-PwBridgeError -Context $Context -StatusCode 503 `
                    -Message 'scrcpy is not installed.' `
                    -Hint 'Run "Repair pwbridge-tab" from the Start Menu to download it.'
                return $true
            }
            try {
                $maxSize = [int](Get-PwBridgeBodyValue -Body $body -Name 'maxSize' -Default 1024)
                $processId = Start-AndroidScrcpy -Serial $serial -ScrcpyPath $State.ScrcpyPath `
                    -AdbPath $State.AdbPath -MaxSize $maxSize
                $State.ScrcpyPid = $processId
                Write-PwBridgeLog -Path $State.LogPath -Message "scrcpy started (pid $processId) for $serial"
                Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true; pid = $processId; mode = 'scrcpy' })
            } catch {
                Write-PwBridgeLog -Level 'ERROR' -Path $State.LogPath -Message "scrcpy launch failed: $($_.Exception.Message)"
                Write-PwBridgeError -Context $Context -Message "Could not start scrcpy: $($_.Exception.Message)" -StatusCode 502
            }
            return $true
        }

        '^POST /api/android/mirror/stop$' {
            $stopped = Stop-PwBridgeScrcpy -State $State
            Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true; stopped = $stopped })
            return $true
        }

        '^GET /api/android/wsscrcpy$' {
            Write-PwBridgeJson -Context $Context -Body (Test-WsScrcpyEndpoint)
            return $true
        }

        '^GET /api/logs$' {
            $tail = 200
            $requested = $Context.Request.QueryString['tail']
            if ($requested -and ($requested -match '^\d{1,5}$')) { $tail = [Math]::Min([int]$requested, 5000) }
            $text = ''
            if (Test-Path -LiteralPath $State.LogPath) {
                $text = (Get-Content -LiteralPath $State.LogPath -Tail $tail -ErrorAction SilentlyContinue) -join "`n"
            }
            Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true; path = $State.LogPath; lines = $text })
            return $true
        }

        '^GET /api/diagnostics$' {
            try {
                $zip = New-PwBridgeDiagnosticsBundle -State $State
                $bytes = [System.IO.File]::ReadAllBytes($zip)
                Write-PwBridgeBytes -Context $Context -Bytes $bytes -ContentType 'application/zip' `
                    -FileName ([System.IO.Path]::GetFileName($zip))
            } catch {
                Write-PwBridgeError -Context $Context -Message $_.Exception.Message -StatusCode 500
            }
            return $true
        }

        '^POST /api/control/shutdown$' {
            Write-PwBridgeJson -Context $Context -Body ([ordered]@{ ok = $true; stopping = $true })
            $State.Shutdown = $true
            Write-PwBridgeLog -Path $State.LogPath -Message 'shutdown requested from UI'
            try { $State.Listener.Stop() } catch { Write-Verbose 'listener already stopped' }
            return $true
        }
    }

    Write-PwBridgeError -Context $Context -Message "Unknown endpoint: $Path" -StatusCode 404
    return $true
}

function Stop-PwBridgeScrcpy {
    <#
    .SYNOPSIS
        Terminates the scrcpy process this server started, if it is still alive.
    #>
    param([Parameter(Mandatory)]$State)

    $processId = $State.ScrcpyPid
    if (-not $processId) { return $false }
    $State.ScrcpyPid = 0
    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
        $proc.Kill()
        Write-PwBridgeLog -Path $State.LogPath -Message "scrcpy stopped (pid $processId)"
        return $true
    } catch {
        return $false
    }
}

function New-PwBridgeDiagnosticsBundle {
    <#
    .SYNOPSIS
        Collects logs and a redacted environment summary into a zip the tester
        can send back. The auth token is never included.
    #>
    param([Parameter(Mandatory)]$State)

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "pwbridge-diag-$stamp"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $summary = [ordered]@{
        generated      = (Get-Date).ToString('o')
        version        = $State.Version
        os             = [System.Environment]::OSVersion.VersionString
        psVersion      = $PSVersionTable.PSVersion.ToString()
        is64BitProcess = [System.Environment]::Is64BitProcess
        shell          = $State.ShellName
        adbPath        = $State.AdbPath
        scrcpyPath     = $State.ScrcpyPath
        port           = $State.Config.port
        mirroring      = ($null -ne $State.ScrcpyPid -and 0 -ne $State.ScrcpyPid)
    }
    if ($State.AdbPath) {
        try {
            $ver = Invoke-Adb -AdbPath $State.AdbPath -ArgumentList @('version') -TimeoutMs 8000
            $summary['adbVersion'] = $ver.StdOut.Trim()
            $devices = @(Get-AndroidDevices -AdbPath $State.AdbPath)
            # Serials are hashed: a diagnostics bundle should not identify the device.
            $summary['devices'] = @($devices | ForEach-Object {
                    [ordered]@{ serialHash = (Get-PwBridgeShortHash -Value $_.Serial); state = $_.State; model = $_.Model }
                })
        } catch {
            $summary['adbError'] = $_.Exception.Message
        }
    }
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $stage 'summary.json') -Encoding UTF8

    foreach ($log in @($State.LogPath, "$($State.LogPath).1")) {
        if (Test-Path -LiteralPath $log) {
            Copy-Item -LiteralPath $log -Destination $stage -ErrorAction SilentlyContinue
        }
    }

    $outDir = Join-Path $State.Config.stateDir 'diagnostics'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $zip = Join-Path $outDir "pwbridge-diagnostics-$stamp.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    return $zip
}

function Get-PwBridgeShortHash {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Set-PwBridgeSecurityHeader'
    'Write-PwBridgeJson'
    'Write-PwBridgeBytes'
    'Write-PwBridgeError'
    'Get-PwBridgeRequestToken'
    'Test-PwBridgeAuthorized'
    'Get-PwBridgeRequestBody'
    'Get-PwBridgeBodyValue'
    'Send-PwBridgeStaticFile'
    'Get-PwBridgeContentType'
    'Get-PwBridgeHealth'
    'Invoke-PwBridgeApi'
    'Stop-PwBridgeScrcpy'
    'New-PwBridgeDiagnosticsBundle'
    'Get-PwBridgeShortHash'
)
