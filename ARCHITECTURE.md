# Architecture

Everything runs on one machine, over loopback, as the logged-in user.

```
  Browser tab (web/)                Bridge (server/)                  Local resources
 +---------------------+          +--------------------------+
 | app.js   terminal   | <--WS--> | HttpListener :8765       | --stdio--> pwsh / powershell
 | phone.js phone view | <--HTTP->|  runspace pool           | --exec---> adb --USB--> phone
 | index.html + CSS    |          |  static files + JSON API | --spawn--> scrcpy window
 +---------------------+          +--------------------------+
        token in header/query           127.0.0.1 only
```

## Components

### Browser tab (`web/`)

| File | Role |
| --- | --- |
| `index.html` | Two panels, no inline script or style so the CSP can stay strict |
| `app.js` | Token handling, `fetch` wrapper, the WebSocket terminal, health polling |
| `phone.js` | Device state, screencap preview, input injection, scrcpy control |
| `styles.css` | All presentation |

The token arrives once in the query string (the only way a launcher can hand it
to a fresh tab), is moved into `sessionStorage`, and is stripped from the address
bar with `history.replaceState` so it does not linger in history. Every request
carries it in `X-PwBridge-Token`; the WebSocket handshake carries it in `?token=`
because browsers cannot set headers on a WebSocket upgrade.

The two panels communicate through `pwbridge-health` and `pwbridge-tab-changed`
CustomEvents rather than sharing globals.

### Bridge (`server/server.ps1` + `server/modules/`)

| Module | Role |
| --- | --- |
| `PwBridge.Common` | Config, token generation, ACLs, logging, state paths |
| `PwBridge.Http` | Auth, security headers, static files, the JSON API, diagnostics |
| `PwBridge.Shell` | Shell process lifecycle and the stdout/stderr pumps |
| `PwBridge.Android` | adb invocation, device resolution, input validation, scrcpy |

`server.ps1` owns an `HttpListener` on loopback and a **runspace pool**. Each
request is dispatched into its own runspace. This matters: a WebSocket shell
session lives for as long as the tab is open, and in the original single-threaded
accept loop it blocked every other request. Concurrent dispatch is what makes a
phone tab and a terminal tab work at the same time.

Shared state is a `[hashtable]::Synchronized(@{})` carrying config, resolved tool
paths, the selected serial and the scrcpy PID.

Written for **Windows PowerShell 5.1** so it runs on a stock Windows 11 with no
prerequisite. The *bridged* shell prefers PowerShell 7 when present and falls
back to Windows PowerShell.

### Shell process

`pwsh -NoLogo -NoProfile -Command -` (or `powershell.exe`), one per WebSocket
session, stdin/stdout/stderr redirected. Two pump runspaces read the output
streams and serialise their sends through a `Monitor` lock, because a
`ClientWebSocket` permits only one in-flight send. Interrupt kills the process
tree and respawns.

### Android path

`adb` and `scrcpy` come from `%LOCALAPPDATA%\pwbridge-tab\runtime`, downloaded
and hash-verified on first run by `tools/PwBridge.Deps.psm1` against
`tools/deps.json`. `Invoke-Adb` is the single choke point for every device
command, which is what makes the input validation auditable and the parsers
unit-testable.

Mirroring has two independent paths, deliberately:

1. **Native scrcpy** — real video, own window, best quality.
2. **In-page preview** — polled `adb exec-out screencap -p` frames plus
   `adb shell input` injection. A few frames per second, but it needs nothing
   beyond adb, so it works when the video path does not. ws-scrcpy has been
   unreliable on Android 16, so the fallback is not optional.

ws-scrcpy is detected at `127.0.0.1:8000` and can be embedded if the tester
already runs one. It is never installed — it would drag in Node.js.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Version, shell name, tool availability, mirroring state |
| GET | `/api/android/devices` | Device list, resolved status, message and hint |
| POST | `/api/android/select` | Choose among multiple authorised devices |
| GET | `/api/android/screen` | One PNG frame |
| POST | `/api/android/input` | tap / swipe / key / text |
| POST | `/api/android/mirror` | Launch scrcpy |
| POST | `/api/android/mirror/stop` | Close scrcpy |
| GET | `/api/android/wsscrcpy` | Detect an existing ws-scrcpy |
| GET | `/api/logs?tail=N` | Recent log lines |
| GET | `/api/diagnostics` | Support zip |
| POST | `/api/control/shutdown` | Graceful stop |

## WebSocket protocol

Unchanged from v0.1, so an existing client keeps working:

| Direction | Frame |
| --- | --- |
| Browser → Bridge | `{ "type": "exec", "data": "Get-Date" }` |
| Browser → Bridge | `{ "type": "interrupt" }` |
| Bridge → Browser | `{ "type": "stdout", "data": "..." }` |
| Bridge → Browser | `{ "type": "stderr", "data": "..." }` |
| Bridge → Browser | `{ "type": "info", "data": "..." }` (new, advisory only) |

## Why a local web server rather than a browser extension

- No extension review or per-browser packaging.
- Identical in Chrome and Comet.
- Auditable: a handful of plain-text PowerShell files.

The trade-off is an open local port while running; see [SECURITY.md](SECURITY.md).

## Layout

Installed (`%LOCALAPPDATA%\Programs\pwbridge-tab\`, per-user, no admin):

```
server\server.ps1
server\modules\*.psm1
web\*
tools\pwbridge.ps1  pwbridge.cmd  PwBridge.Deps.psm1  deps.json
docs\  LICENSE  README.md  SECURITY.md  THIRD-PARTY-NOTICES.md
```

State (`%LOCALAPPDATA%\pwbridge-tab\`):

```
config.json         port, token, preferences (ACL: current user only)
pwbridge.log        rolls at 5 MB, one .1 kept
pwbridge.pid        for stop and upgrade
runtime\scrcpy\     downloaded, hash-verified
runtime\platform-tools\   only if adb was not found in scrcpy
diagnostics\        support zips
```

Separating the two means an upgrade never touches the token or the downloaded
tools, and an uninstall can offer to remove state independently of the program.
