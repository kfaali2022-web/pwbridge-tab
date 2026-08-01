# PwBridge.Deps - downloads and verifies the pinned runtime dependencies.
#
# Nothing here is bundled in the installer. Archives are fetched over HTTPS from
# an allowlisted official host and every one is checked against the SHA-256 in
# deps.json before extraction, so a hijacked mirror cannot plant an executable.
#
# Must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

function Get-PwBridgeDepsManifest {
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'deps.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Dependency manifest not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Test-PwBridgeDownloadUrl {
    <#
    .SYNOPSIS
        Requires HTTPS and an allowlisted host so a tampered manifest cannot
        redirect the download to an arbitrary server.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$AllowedHosts
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    return ($AllowedHosts -contains $uri.Host)
}

function Get-PwBridgeFileHash256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Invoke-PwBridgeDownload {
    <#
    .SYNOPSIS
        Downloads a file with retries. Windows PowerShell 5.1 defaults to TLS
        1.0, which every one of these hosts rejects, so TLS 1.2 is forced.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Retries = 3
    )

    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol
    } catch {
        Write-Verbose 'could not adjust TLS settings'
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $client = New-Object System.Net.WebClient
            $client.Headers.Add('User-Agent', 'pwbridge-tab-setup')
            $client.DownloadFile($Url, $Destination)
            $client.Dispose()
            return $true
        } catch {
            $lastError = $_.Exception.Message
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($attempt -lt $Retries) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    throw "Download failed after $Retries attempts: $Url`n$lastError"
}

function Install-PwBridgeComponent {
    <#
    .SYNOPSIS
        Downloads, hash-verifies and extracts one component into the runtime dir.
    .OUTPUTS
        Hashtable: Id, Installed, Path, Message.
    #>
    param(
        [Parameter(Mandatory)]$Component,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [switch]$Force
    )

    $result = @{ Id = $Component.id; Installed = $false; Path = ''; Message = '' }
    $target = Join-Path $RuntimeDir $Component.id

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        $result.Installed = $true
        $result.Path = $target
        $result.Message = "$($Component.name) $($Component.version) already installed."
        return $result
    }

    if (-not (Test-PwBridgeDownloadUrl -Url $Component.url -AllowedHosts $AllowedHosts)) {
        throw "Refusing to download $($Component.name): '$($Component.url)' is not an allowlisted HTTPS source."
    }

    if (-not (Test-Path -LiteralPath $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null }
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("pwbridge-{0}-{1}.zip" -f $Component.id, [System.Guid]::NewGuid().ToString('N'))

    try {
        $sizeMb = [Math]::Round($Component.sizeBytes / 1MB, 1)
        Write-Host "  Downloading $($Component.name) $($Component.version) ($sizeMb MB)..." -ForegroundColor Cyan
        Invoke-PwBridgeDownload -Url $Component.url -Destination $temp | Out-Null

        $actual = Get-PwBridgeFileHash256 -Path $temp
        $expected = $Component.sha256.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Checksum mismatch for $($Component.name). Expected $expected but got $actual. The download was not trusted and has been discarded."
        }
        Write-Host "  Verified SHA-256 for $($Component.name)." -ForegroundColor Green

        $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("pwbridge-x-" + [System.Guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $temp -DestinationPath $staging -Force

        # Most archives wrap everything in a single versioned folder; flatten it
        # so the runtime layout stays stable across upgrades.
        $source = $staging
        $inner = Join-Path $staging $Component.archiveRoot
        if ($Component.archiveRoot -and (Test-Path -LiteralPath $inner)) { $source = $inner }

        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

        $result.Installed = $true
        $result.Path = $target
        $result.Message = "$($Component.name) $($Component.version) installed."
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Get-PwBridgeRuntimeStatus {
    <#
    .SYNOPSIS
        Reports which Android tools are currently usable.
    #>
    param([Parameter(Mandatory)][string]$RuntimeDir)

    $status = @{ AdbPath = ''; ScrcpyPath = ''; AdbReady = $false; ScrcpyReady = $false }
    foreach ($pair in @(@('adb', 'AdbPath'), @('scrcpy', 'ScrcpyPath'))) {
        $found = $null
        if (Test-Path -LiteralPath $RuntimeDir) {
            $found = Get-ChildItem -LiteralPath $RuntimeDir -Filter "$($pair[0]).exe" -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        if ($found) { $status[$pair[1]] = $found.FullName }
    }
    $status.AdbReady = [bool]$status.AdbPath
    $status.ScrcpyReady = [bool]$status.ScrcpyPath
    return $status
}

function Install-PwBridgeRuntime {
    <#
    .SYNOPSIS
        Ensures adb and scrcpy are present, reporting each step in plain language.
    .DESCRIPTION
        scrcpy ships its own adb.exe, so the Android platform tools are only
        fetched when scrcpy could not supply one.
    .OUTPUTS
        Hashtable: Ok, AdbPath, ScrcpyPath, Steps, Errors.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$ManifestPath,
        [switch]$Force
    )

    $manifest = Get-PwBridgeDepsManifest -Path $ManifestPath
    $allowed = @($manifest.allowedHosts)
    $outcome = @{ Ok = $false; AdbPath = ''; ScrcpyPath = ''; Steps = @(); Errors = @() }

    $primary = $manifest.components | Where-Object { $_.id -eq 'scrcpy' } | Select-Object -First 1
    $fallback = $manifest.components | Where-Object { $_.id -eq 'platform-tools' } | Select-Object -First 1

    foreach ($component in @($primary)) {
        if (-not $component) { continue }
        try {
            $step = Install-PwBridgeComponent -Component $component -RuntimeDir $RuntimeDir -AllowedHosts $allowed -Force:$Force
            $outcome.Steps += $step.Message
        } catch {
            $outcome.Errors += $_.Exception.Message
            Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $status = Get-PwBridgeRuntimeStatus -RuntimeDir $RuntimeDir
    if (-not $status.AdbReady -and $fallback) {
        Write-Host '  scrcpy did not provide adb; fetching the Android platform tools instead.' -ForegroundColor Yellow
        try {
            $step = Install-PwBridgeComponent -Component $fallback -RuntimeDir $RuntimeDir -AllowedHosts $allowed -Force:$Force
            $outcome.Steps += $step.Message
        } catch {
            $outcome.Errors += $_.Exception.Message
            Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Red
        }
        $status = Get-PwBridgeRuntimeStatus -RuntimeDir $RuntimeDir
    }

    $outcome.AdbPath = $status.AdbPath
    $outcome.ScrcpyPath = $status.ScrcpyPath
    $outcome.Ok = $status.AdbReady
    return $outcome
}

Export-ModuleMember -Function @(
    'Get-PwBridgeDepsManifest'
    'Test-PwBridgeDownloadUrl'
    'Get-PwBridgeFileHash256'
    'Invoke-PwBridgeDownload'
    'Install-PwBridgeComponent'
    'Get-PwBridgeRuntimeStatus'
    'Install-PwBridgeRuntime'
)
