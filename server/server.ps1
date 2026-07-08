# pwbridge-tab server.ps1
# Local WebSocket + static-file bridge that streams commands to PowerShell (pwsh).
# Windows-first alpha. Requires PowerShell 7 (pwsh). MIT License.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File server\server.ps1 [-Port 8765] [-Token ""]
# Then open http://127.0.0.1:8765/ in Chrome or Comet.

param(
  [int]$Port = 8765,
  [string]$Bind = "127.0.0.1",
  [string]$Token = "",
  [string]$WebRoot = "$PSScriptRoot\..\web"
)

$ErrorActionPreference = "Stop"

# Security: never bind to anything but loopback by default.
if ($Bind -ne "127.0.0.1" -and $Bind -ne "localhost") {
  Write-Warning "Binding to a non-loopback address exposes a shell to your network. Aborting."
  exit 1
}

Add-Type -AssemblyName System.Net.HttpListener -ErrorAction SilentlyContinue

$prefix = "http://$Bind`:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "pwbridge-tab listening on $prefix" -ForegroundColor Green
if ($Token) { Write-Host "Token auth enabled." -ForegroundColor Yellow }

function Send-Static {
  param($Context, $Path)
  $file = Join-Path $WebRoot ($Path.TrimStart('/'))
  if ($Path -eq '/' -or [string]::IsNullOrWhiteSpace($Path)) { $file = Join-Path $WebRoot 'index.html' }
  if (-not (Test-Path $file)) { $Context.Response.StatusCode = 404; $Context.Response.Close(); return }
  $bytes = [System.IO.File]::ReadAllBytes($file)
  $ext = [System.IO.Path]::GetExtension($file)
  $type = switch ($ext) { '.html' { 'text/html' } '.js' { 'text/javascript' } '.css' { 'text/css' } default { 'application/octet-stream' } }
  $Context.Response.ContentType = $type
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

function Start-PwshBridge {
  param($WebSocket, $CancelToken)

  # Spawn a persistent pwsh process in stream mode.
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "pwsh"
  $psi.Arguments = "-NoLogo -NoProfile -Command -"
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)

  $enc = [System.Text.Encoding]::UTF8

  # Pump stdout/stderr back to the browser as JSON frames.
  $pump = {
    param($reader, $stream, $channel)
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      $payload = @{ type = $channel; data = $line } | ConvertTo-Json -Compress
      $buf = $enc.GetBytes($payload)
      $seg = [System.ArraySegment[byte]]::new($buf)
      $stream.SendAsync($seg, 'Text', $true, $CancelToken).Wait()
    }
  }
  $outJob = Start-ThreadJob -ScriptBlock $pump -ArgumentList $proc.StandardOutput, $WebSocket, 'stdout'
  $errJob = Start-ThreadJob -ScriptBlock $pump -ArgumentList $proc.StandardError, $WebSocket, 'stderr'

  # Read commands from the browser.
  $recvBuf = [byte[]]::new(65536)
  while ($WebSocket.State -eq 'Open') {
    $seg = [System.ArraySegment[byte]]::new($recvBuf)
    $result = $WebSocket.ReceiveAsync($seg, $CancelToken).GetAwaiter().GetResult()
    if ($result.MessageType -eq 'Close') { break }
    $text = $enc.GetString($recvBuf, 0, $result.Count)
    try { $msg = $text | ConvertFrom-Json } catch { continue }
    switch ($msg.type) {
      'exec' { $proc.StandardInput.WriteLine($msg.data) }
      'interrupt' { Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue }
      default { }
    }
  }

  Stop-Job $outJob, $errJob -ErrorAction SilentlyContinue
  if (-not $proc.HasExited) { $proc.Kill() }
}

# Main accept loop.
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    if ($ctx.Request.IsWebSocketRequest) {
      # Optional token check via query string ?token=...
      if ($Token -and $ctx.Request.QueryString['token'] -ne $Token) {
        $ctx.Response.StatusCode = 401; $ctx.Response.Close(); continue
      }
      $wsCtx = $ctx.AcceptWebSocketAsync($null).GetAwaiter().GetResult()
      $cts = [System.Threading.CancellationTokenSource]::new()
      Start-PwshBridge -WebSocket $wsCtx.WebSocket -CancelToken $cts.Token
    } else {
      Send-Static -Context $ctx -Path $ctx.Request.Url.AbsolutePath
    }
  }
} finally {
  $listener.Stop()
}
