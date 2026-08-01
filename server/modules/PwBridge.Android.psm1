# PwBridge.Android - ADB device discovery, screen capture, input injection and
# scrcpy process management.
#
# Every value that reaches an `adb shell` command line is validated against a
# strict allowlist first: adb concatenates its arguments and runs them through
# the device's /system/bin/sh, so an unvalidated string would be a command
# injection primitive.
#
# Must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

$script:KeycodeAllowlist = @(
    'KEYCODE_HOME', 'KEYCODE_BACK', 'KEYCODE_APP_SWITCH', 'KEYCODE_MENU',
    'KEYCODE_POWER', 'KEYCODE_WAKEUP', 'KEYCODE_SLEEP',
    'KEYCODE_VOLUME_UP', 'KEYCODE_VOLUME_DOWN', 'KEYCODE_VOLUME_MUTE',
    'KEYCODE_ENTER', 'KEYCODE_DEL', 'KEYCODE_FORWARD_DEL', 'KEYCODE_TAB',
    'KEYCODE_ESCAPE', 'KEYCODE_SPACE', 'KEYCODE_SEARCH', 'KEYCODE_NOTIFICATION',
    'KEYCODE_DPAD_UP', 'KEYCODE_DPAD_DOWN', 'KEYCODE_DPAD_LEFT',
    'KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER',
    'KEYCODE_MEDIA_PLAY_PAUSE', 'KEYCODE_MEDIA_NEXT', 'KEYCODE_MEDIA_PREVIOUS'
)

# Deliberately narrow. Anything a device shell could interpret (quotes, $, `,
# ;, &, |, <, >, \, *) is excluded rather than escaped.
$script:SafeTextPattern = '^[A-Za-z0-9 _.,:@\-+/?!#=]{0,500}$'
$script:SerialPattern = '^[A-Za-z0-9._:\-]{1,64}$'
$script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

function Get-AndroidKeycodeAllowlist { return $script:KeycodeAllowlist }

function Test-AndroidSerial {
    param([string]$Serial)
    if ([string]::IsNullOrWhiteSpace($Serial)) { return $false }
    return ($Serial -match $script:SerialPattern)
}

function Test-AndroidKeycode {
    param([string]$Keycode)
    if ([string]::IsNullOrWhiteSpace($Keycode)) { return $false }
    return ($script:KeycodeAllowlist -contains $Keycode)
}

function Test-AndroidInputText {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return ($Text -match $script:SafeTextPattern)
}

function ConvertTo-AndroidInputText {
    <#
    .SYNOPSIS
        Converts validated text into the form `input text` expects (spaces as %s).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not (Test-AndroidInputText -Text $Text)) {
        throw "Text contains characters that are not allowed. Permitted: letters, digits, space and _.,:@-+/?!#="
    }
    return ($Text -replace ' ', '%s')
}

function ConvertTo-ProcessArgumentString {
    <#
    .SYNOPSIS
        Joins arguments into a Windows command line, quoting per
        CommandLineToArgvW rules. Windows PowerShell 5.1 has no ArgumentList.
    #>
    param([string[]]$ArgumentList)

    if (-not $ArgumentList) { return '' }
    $parts = @()
    foreach ($a in $ArgumentList) {
        $s = [string]$a
        if ($s -match '^[A-Za-z0-9._:@/\-=%,]+$' -and $s.Length -gt 0) {
            $parts += $s
            continue
        }
        $escaped = $s -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $parts += '"' + $escaped + '"'
    }
    return ($parts -join ' ')
}

function Invoke-ExternalProcess {
    <#
    .SYNOPSIS
        Runs an executable with a timeout and captures stdout/stderr as text, or
        stdout as bytes when -Binary is set.
    .OUTPUTS
        Hashtable with ExitCode, StdOut, StdErr, Bytes, TimedOut.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutMs = 15000,
        [switch]$Binary
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ProcessArgumentString -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $result = @{ ExitCode = -1; StdOut = ''; StdErr = ''; Bytes = $null; TimedOut = $false }
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $result.StdErr = $_.Exception.Message
        return $result
    }

    try {
        if ($Binary) {
            $ms = New-Object System.IO.MemoryStream
            $copy = $proc.StandardOutput.BaseStream.CopyToAsync($ms)
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                $result.TimedOut = $true
                try { $proc.Kill() } catch { Write-Verbose 'process already exited' }
            }
            [void]$copy.Wait(2000)
            $result.Bytes = $ms.ToArray()
            $ms.Dispose()
            $result.StdErr = if ($errTask.Wait(2000)) { $errTask.Result } else { '' }
        } else {
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                $result.TimedOut = $true
                try { $proc.Kill() } catch { Write-Verbose 'process already exited' }
            }
            $result.StdOut = if ($outTask.Wait(2000)) { $outTask.Result } else { '' }
            $result.StdErr = if ($errTask.Wait(2000)) { $errTask.Result } else { '' }
        }
        if (-not $result.TimedOut) { $result.ExitCode = $proc.ExitCode }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
    return $result
}

function Get-AndroidToolPath {
    <#
    .SYNOPSIS
        Resolves adb.exe / scrcpy.exe from the managed runtime dir, then PATH.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('adb', 'scrcpy')][string]$Tool,
        [string]$RuntimeDir
    )

    $exe = if ($script:IsWindowsHost) { "$Tool.exe" } else { $Tool }
    if ($RuntimeDir -and (Test-Path -LiteralPath $RuntimeDir)) {
        $found = Get-ChildItem -LiteralPath $RuntimeDir -Filter $exe -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Adb {
    <#
    .SYNOPSIS
        Single choke point for every adb invocation. Tests mock this.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$AdbPath,
        [string]$Serial,
        [int]$TimeoutMs = 15000,
        [switch]$Binary
    )

    if (-not $AdbPath) { throw 'adb is not available.' }
    $full = @()
    if ($Serial) {
        if (-not (Test-AndroidSerial -Serial $Serial)) { throw "Invalid device serial." }
        $full += @('-s', $Serial)
    }
    $full += $ArgumentList
    return Invoke-ExternalProcess -FilePath $AdbPath -ArgumentList $full -TimeoutMs $TimeoutMs -Binary:$Binary
}

function Get-AndroidDevices {
    <#
    .SYNOPSIS
        Parses `adb devices -l` into objects. Never returns $null.
    .OUTPUTS
        Array of PSCustomObject: Serial, State, Model, Product, Authorized.
    #>
    param([string]$AdbPath)

    if (-not $AdbPath) { return @() }
    $res = Invoke-Adb -AdbPath $AdbPath -ArgumentList @('devices', '-l') -TimeoutMs 20000
    return (ConvertFrom-AdbDeviceList -Output $res.StdOut)
}

function ConvertFrom-AdbDeviceList {
    <#
    .SYNOPSIS
        Pure parser for `adb devices -l` output, split out so it is unit testable.
    #>
    param([string]$Output)

    $devices = @()
    if ([string]::IsNullOrWhiteSpace($Output)) { return $devices }

    foreach ($line in ($Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -like 'List of devices*') { continue }
        if ($trimmed -like '*daemon*') { continue }
        if ($trimmed.StartsWith('*')) { continue }

        $fields = $trimmed -split '\s+'
        if ($fields.Count -lt 2) { continue }
        $serial = $fields[0]
        if (-not (Test-AndroidSerial -Serial $serial)) { continue }

        $state = $fields[1]
        $model = ''
        $product = ''
        foreach ($f in $fields) {
            if ($f -like 'model:*') { $model = $f.Substring(6) }
            if ($f -like 'product:*') { $product = $f.Substring(8) }
        }
        # "no permissions" splits across fields; normalise it to something stable.
        if ($trimmed -like '*no permissions*') { $state = 'no-permissions' }

        $devices += [PSCustomObject]@{
            Serial     = $serial
            State      = $state
            Model      = $model
            Product    = $product
            Authorized = ($state -eq 'device')
        }
    }
    return $devices
}

function Resolve-AndroidDevice {
    <#
    .SYNOPSIS
        Picks the device to drive and describes what the tester must do next.
        No serial is ever hard-coded: selection is purely by what is attached.
    .OUTPUTS
        Hashtable: Status, Serial, Devices, Message, Hint.
        Status is one of ready | none | unauthorized | offline | multiple |
        no-permissions | no-adb.
    #>
    param(
        [object[]]$Devices,
        [string]$PreferredSerial
    )

    if ($null -eq $Devices) { $Devices = @() }
    $result = @{ Status = 'none'; Serial = ''; Devices = $Devices; Message = ''; Hint = '' }

    $authorized = @($Devices | Where-Object { $_.Authorized })

    if ($PreferredSerial) {
        $match = $authorized | Where-Object { $_.Serial -eq $PreferredSerial } | Select-Object -First 1
        if ($match) {
            $result.Status = 'ready'
            $result.Serial = $match.Serial
            $label = if ($match.Model) { $match.Model } else { $match.Serial }
            $result.Message = "Using $label."
            return $result
        }
    }

    if ($authorized.Count -eq 1) {
        $result.Status = 'ready'
        $result.Serial = $authorized[0].Serial
        $result.Message = 'Phone connected and authorized.'
        return $result
    }

    if ($authorized.Count -gt 1) {
        $result.Status = 'multiple'
        $result.Message = "$($authorized.Count) authorized devices are connected."
        $result.Hint = 'Pick which phone to mirror, or unplug the ones you are not testing.'
        return $result
    }

    if ($Devices | Where-Object { $_.State -eq 'unauthorized' }) {
        $result.Status = 'unauthorized'
        $result.Message = 'Phone detected but USB debugging is not authorized yet.'
        $result.Hint = 'Unlock the phone and tap "Allow" on the "Allow USB debugging?" prompt. Tick "Always allow from this computer".'
        return $result
    }

    if ($Devices | Where-Object { $_.State -eq 'offline' }) {
        $result.Status = 'offline'
        $result.Message = 'Phone is connected but reporting offline.'
        $result.Hint = 'Unplug and replug the cable, then unlock the phone. If it persists, toggle USB debugging off and on.'
        return $result
    }

    if ($Devices | Where-Object { $_.State -eq 'no-permissions' }) {
        $result.Status = 'no-permissions'
        $result.Message = 'The USB device is visible but the driver denied access.'
        $result.Hint = 'Install the phone vendor USB driver, or try a different USB port or cable.'
        return $result
    }

    $result.Status = 'none'
    $result.Message = 'No Android phone detected.'
    $result.Hint = 'Connect the phone with a USB data cable, enable Developer options then USB debugging, and set the USB mode to File transfer.'
    return $result
}

function Get-AndroidDeviceInfo {
    <#
    .SYNOPSIS
        Model, Android release and screen geometry for a device.
    #>
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$AdbPath
    )

    $info = @{ Serial = $Serial; Model = ''; AndroidVersion = ''; Sdk = ''; Width = 0; Height = 0 }

    $props = @{
        Model          = 'ro.product.model'
        AndroidVersion = 'ro.build.version.release'
        Sdk            = 'ro.build.version.sdk'
    }
    foreach ($key in @($props.Keys)) {
        $res = Invoke-Adb -AdbPath $AdbPath -Serial $Serial -ArgumentList @('shell', 'getprop', $props[$key]) -TimeoutMs 10000
        if ($res.ExitCode -eq 0) { $info[$key] = $res.StdOut.Trim() }
    }

    $size = Invoke-Adb -AdbPath $AdbPath -Serial $Serial -ArgumentList @('shell', 'wm', 'size') -TimeoutMs 10000
    if ($size.ExitCode -eq 0) {
        $parsed = ConvertFrom-AdbWmSize -Output $size.StdOut
        $info.Width = $parsed.Width
        $info.Height = $parsed.Height
    }
    return $info
}

function ConvertFrom-AdbWmSize {
    <#
    .SYNOPSIS
        Parses `wm size`. Prefers "Override size" when the device reports one.
    #>
    param([string]$Output)

    $result = @{ Width = 0; Height = 0 }
    if ([string]::IsNullOrWhiteSpace($Output)) { return $result }

    $override = [regex]::Match($Output, 'Override size:\s*(\d+)x(\d+)')
    $physical = [regex]::Match($Output, 'Physical size:\s*(\d+)x(\d+)')
    $match = if ($override.Success) { $override } elseif ($physical.Success) { $physical } else { $null }
    if ($match) {
        $result.Width = [int]$match.Groups[1].Value
        $result.Height = [int]$match.Groups[2].Value
    }
    return $result
}

function Get-AndroidScreenshot {
    <#
    .SYNOPSIS
        Captures the device screen as PNG bytes via `adb exec-out screencap -p`.
    #>
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$AdbPath,
        [int]$TimeoutMs = 12000
    )

    $res = Invoke-Adb -AdbPath $AdbPath -Serial $Serial -ArgumentList @('exec-out', 'screencap', '-p') -TimeoutMs $TimeoutMs -Binary
    if ($res.TimedOut) { throw 'Screen capture timed out.' }
    if (-not $res.Bytes -or $res.Bytes.Length -lt 8) {
        $detail = if ($res.StdErr) { $res.StdErr.Trim() } else { 'empty response from device' }
        throw "Screen capture failed: $detail"
    }
    if (-not (Test-PngHeader -Bytes $res.Bytes)) {
        throw 'Screen capture did not return a PNG. The device may block screenshots for the current app.'
    }
    return $res.Bytes
}

function Test-PngHeader {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 8) { return $false }
    $sig = @(137, 80, 78, 71, 13, 10, 26, 10)
    for ($i = 0; $i -lt 8; $i++) {
        if ($Bytes[$i] -ne $sig[$i]) { return $false }
    }
    return $true
}

function Invoke-AndroidInput {
    <#
    .SYNOPSIS
        Injects a tap, swipe, key press or text entry.
    .DESCRIPTION
        Coordinates are validated as non-negative integers, keycodes must be in
        the allowlist and text must match the safe-character pattern.
    #>
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][ValidateSet('tap', 'swipe', 'key', 'text')][string]$Action,
        [int]$X = 0,
        [int]$Y = 0,
        [int]$X2 = 0,
        [int]$Y2 = 0,
        [int]$DurationMs = 200,
        [string]$Keycode = '',
        [string]$Text = ''
    )

    $maxCoord = 20000
    foreach ($pair in @(@('X', $X), @('Y', $Y), @('X2', $X2), @('Y2', $Y2))) {
        if ($pair[1] -lt 0 -or $pair[1] -gt $maxCoord) { throw "$($pair[0]) is out of range." }
    }
    if ($DurationMs -lt 1 -or $DurationMs -gt 10000) { throw 'Duration is out of range.' }

    switch ($Action) {
        'tap' { $argv = @('shell', 'input', 'tap', "$X", "$Y") }
        'swipe' { $argv = @('shell', 'input', 'swipe', "$X", "$Y", "$X2", "$Y2", "$DurationMs") }
        'key' {
            if (-not (Test-AndroidKeycode -Keycode $Keycode)) { throw "Keycode '$Keycode' is not allowed." }
            $argv = @('shell', 'input', 'keyevent', $Keycode)
        }
        'text' {
            $encoded = ConvertTo-AndroidInputText -Text $Text
            if (-not $encoded) { throw 'Text is empty.' }
            $argv = @('shell', 'input', 'text', $encoded)
        }
        default { throw "Unsupported action '$Action'." }
    }

    $res = Invoke-Adb -AdbPath $AdbPath -Serial $Serial -ArgumentList $argv -TimeoutMs 10000
    if ($res.ExitCode -ne 0) {
        $detail = if ($res.StdErr) { $res.StdErr.Trim() } else { "exit code $($res.ExitCode)" }
        throw "Input failed: $detail"
    }
    return $true
}

function Start-AndroidScrcpy {
    <#
    .SYNOPSIS
        Launches native scrcpy for a device and returns the process id.
    #>
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$ScrcpyPath,
        [string]$AdbPath,
        [string]$WindowTitle = 'pwbridge-tab phone',
        [int]$MaxSize = 1024,
        [int]$BitRateMbps = 8
    )

    if (-not (Test-AndroidSerial -Serial $Serial)) { throw 'Invalid device serial.' }
    if ($MaxSize -lt 320 -or $MaxSize -gt 4096) { throw 'MaxSize is out of range.' }
    if ($BitRateMbps -lt 1 -or $BitRateMbps -gt 50) { throw 'BitRate is out of range.' }

    $argv = @(
        '--serial', $Serial,
        '--window-title', $WindowTitle,
        '--max-size', "$MaxSize",
        '--video-bit-rate', "${BitRateMbps}M"
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ScrcpyPath
    $psi.Arguments = ConvertTo-ProcessArgumentString -ArgumentList $argv
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Split-Path -Parent $ScrcpyPath)
    if ($AdbPath) { $psi.EnvironmentVariables['ADB'] = $AdbPath }

    $proc = [System.Diagnostics.Process]::Start($psi)
    return $proc.Id
}

function Test-WsScrcpyEndpoint {
    <#
    .SYNOPSIS
        Detects a ws-scrcpy instance the tester may already be running.
        pwbridge-tab never installs or starts ws-scrcpy (it needs Node.js); it
        only offers to embed one that is already healthy.
    #>
    param(
        [int]$Port = 8000,
        [int]$TimeoutMs = 1200
    )

    $result = @{ Available = $false; Url = "http://127.0.0.1:$Port/"; Detail = 'not running' }
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
        $task = $client.GetAsync($result.Url)
        if ($task.Wait($TimeoutMs + 500) -and $task.Result.IsSuccessStatusCode) {
            $result.Available = $true
            $result.Detail = 'reachable'
        }
        $client.Dispose()
    } catch {
        $result.Detail = 'not running'
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-AndroidKeycodeAllowlist'
    'Test-AndroidSerial'
    'Test-AndroidKeycode'
    'Test-AndroidInputText'
    'ConvertTo-AndroidInputText'
    'ConvertTo-ProcessArgumentString'
    'Invoke-ExternalProcess'
    'Get-AndroidToolPath'
    'Invoke-Adb'
    'Get-AndroidDevices'
    'ConvertFrom-AdbDeviceList'
    'Resolve-AndroidDevice'
    'Get-AndroidDeviceInfo'
    'ConvertFrom-AdbWmSize'
    'Get-AndroidScreenshot'
    'Test-PngHeader'
    'Invoke-AndroidInput'
    'Start-AndroidScrcpy'
    'Test-WsScrcpyEndpoint'
)
