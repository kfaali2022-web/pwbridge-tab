# Architecture

pwbridge-tab has three moving parts on a single machine.

```
 Browser tab (web/)            Local server (server/)          PowerShell
 +------------------+   WS      +----------------------+  stdio  +---------+
 | index.html+app.js| <-------> | HttpListener + WS     | <-----> |  pwsh   |
 | terminal UI      |  JSON     | + static file server  |  lines  | process |
 +------------------+           +----------------------+         +---------+
         ^  serves index.html/app.js over http 127.0.0.1:8765
```

## Components

### 1. Browser tab UI (`web/index.html`, `web/app.js`)
- Renders the console, input box, and connection controls.
- Opens a WebSocket to `ws://127.0.0.1:8765/` (optionally `?token=...`).
- Sends JSON frames `{ type: "exec", data: "<command>" }`.
- Receives JSON frames `{ type: "stdout"|"stderr", data: "<line>" }` and renders them.

### 2. Local server (`server/server.ps1`)
- `System.Net.HttpListener` bound to loopback.
- Serves the static UI for normal HTTP requests.
- Upgrades WebSocket requests, optionally checking a token.
- Spawns one `pwsh` per connection with redirected stdin/stdout/stderr.
- Uses `Start-ThreadJob` to pump process output back over the socket.

### 3. PowerShell process
- Launched as `pwsh -NoLogo -NoProfile -Command -` (reads commands from stdin).
- One process per WebSocket connection; killed on disconnect.

## Message protocol

| Direction | Frame |
| --- | --- |
| Browser -> Server | `{ "type": "exec", "data": "Get-Date" }` |
| Browser -> Server | `{ "type": "interrupt" }` |
| Server -> Browser | `{ "type": "stdout", "data": "..." }` |
| Server -> Browser | `{ "type": "stderr", "data": "..." }` |

## Why a local web server instead of a browser extension

- No extension review or per-browser packaging.
- Identical behavior in Chrome and Comet (both are Chromium).
- Easy to audit: a single PowerShell file.

The trade-off is that a local port is open while running; see [SECURITY.md](SECURITY.md).

## Install layout

```
%LOCALAPPDATA%\pwbridge-tab\
  server\server.ps1
  web\index.html
  web\app.js
```

A Start Menu shortcut launches `pwsh server\server.ps1`. With `-AutoStart`, a logon Scheduled Task does the same.
