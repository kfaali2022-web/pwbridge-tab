# PwBridge.Common - configuration, state paths, token handling and logging.
# Must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

$script:LogLock = [System.Object]::new()

# $IsWindows does not exist on Windows PowerShell 5.1, so probe the runtime instead.
$IsWindowsPlatformCache = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

function Get-PwBridgeVersion {
    return '0.2.0'
}

function Get-PwBridgeStateDir {
    <#
    .SYNOPSIS
        Per-user directory holding config, logs, runtime tools and PID files.
    #>
    param([string]$Root)

    if (-not $Root) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = Join-Path $HOME '.local/share' }
        $Root = Join-Path $base 'pwbridge-tab'
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Root).ProviderPath
}

function New-PwBridgeToken {
    <#
    .SYNOPSIS
        Generates a 256-bit URL-safe token from a cryptographic RNG.
    #>
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.Convert]::ToBase64String($bytes)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function Protect-PwBridgeFile {
    <#
    .SYNOPSIS
        Restricts a file's ACL to the current user only. No-op off Windows.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindowsPlatformCache) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $me, 'FullControl', 'None', 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
        return $true
    } catch {
        Write-Verbose "Could not tighten ACL on ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Test-PwBridgeWindows {
    return $IsWindowsPlatformCache
}

function Get-PwBridgeConfig {
    <#
    .SYNOPSIS
        Loads config.json from the state dir, creating it with a fresh token on
        first use. Returns a hashtable.
    #>
    param(
        [string]$StateDir,
        [int]$Port = 0
    )

    $dir = Get-PwBridgeStateDir -Root $StateDir
    $path = Join-Path $dir 'config.json'
    $config = @{
        port           = 8765
        token          = ''
        autoOpenBrowser = $true
        preferShell    = 'auto'
    }

    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($key in @($config.Keys)) {
                if ($parsed.PSObject.Properties.Name -contains $key) {
                    $config[$key] = $parsed.$key
                }
            }
        } catch {
            Write-Warning "config.json unreadable, regenerating: $($_.Exception.Message)"
        }
    }

    if (-not $config.token) { $config.token = New-PwBridgeToken }
    if ($Port -gt 0) { $config.port = $Port }
    $config['stateDir'] = $dir
    $config['configPath'] = $path

    Save-PwBridgeConfig -Config $config
    return $config
}

function Save-PwBridgeConfig {
    param([Parameter(Mandatory)][hashtable]$Config)

    $persist = [ordered]@{
        port            = [int]$Config.port
        token           = [string]$Config.token
        autoOpenBrowser = [bool]$Config.autoOpenBrowser
        preferShell     = [string]$Config.preferShell
    }
    $path = $Config.configPath
    ($persist | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
    Protect-PwBridgeFile -Path $path | Out-Null
}

function Get-PwBridgeLogPath {
    param([string]$StateDir)
    $dir = Join-Path (Get-PwBridgeStateDir -Root $StateDir) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'pwbridge.log')
}

function Write-PwBridgeLog {
    <#
    .SYNOPSIS
        Appends a timestamped line to the rolling log. Safe to call from
        multiple runspaces.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$Path
    )

    if (-not $Path) { $Path = Get-PwBridgeLogPath }
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        # Roll at 5 MB so a long-running session cannot fill the disk.
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 5MB) {
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
}

function Test-PwBridgeTokenMatch {
    <#
    .SYNOPSIS
        Constant-time comparison so a local attacker cannot time-slice the token.
    #>
    param([string]$Expected, [string]$Actual)

    if ([string]::IsNullOrEmpty($Expected)) { return $true }
    if ([string]::IsNullOrEmpty($Actual)) { return $false }
    $a = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Actual)
    if ($a.Length -ne $b.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    return ($diff -eq 0)
}

function Test-PwBridgeOrigin {
    <#
    .SYNOPSIS
        Rejects cross-origin browser requests. A missing Origin (curl, the
        launcher probe) is allowed; a present Origin must be our own loopback URL.
    #>
    param([string]$Origin, [int]$Port)

    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    $allowed = @(
        "http://127.0.0.1:$Port"
        "http://localhost:$Port"
        "http://[::1]:$Port"
    )
    return ($allowed -contains $Origin.TrimEnd('/'))
}

function Get-PwBridgePidPath {
    param([string]$StateDir)
    return (Join-Path (Get-PwBridgeStateDir -Root $StateDir) 'pwbridge.pid')
}

Export-ModuleMember -Function @(
    'Get-PwBridgeVersion'
    'Get-PwBridgeStateDir'
    'New-PwBridgeToken'
    'Protect-PwBridgeFile'
    'Test-PwBridgeWindows'
    'Get-PwBridgeConfig'
    'Save-PwBridgeConfig'
    'Get-PwBridgeLogPath'
    'Write-PwBridgeLog'
    'Test-PwBridgeTokenMatch'
    'Test-PwBridgeOrigin'
    'Get-PwBridgePidPath'
)
