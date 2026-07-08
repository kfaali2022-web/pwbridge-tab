# pwbridge-tab

![status](https://img.shields.io/badge/status-alpha-orange) ![platform](https://img.shields.io/badge/platform-Windows-blue) ![shell](https://img.shields.io/badge/shell-PowerShell%207-5391FE) ![license](https://img.shields.io/badge/license-MIT-green)

A PowerShell console that lives in a **browser tab** in Chrome and Comet. The UI runs in your browser; commands execute **locally** on your machine through a small WebSocket bridge. Windows-first alpha. MIT licensed.

> Your shell stays in the browser workspace where you already work, but nothing runs off your machine.

## Screenshot

> Add a screenshot or GIF of the terminal tab here. Save it to `docs/screenshot.png` and it will render below.

![pwbridge-tab terminal in a browser tab](docs/screenshot.png)

---

## What it is

pwbridge-tab is two small pieces:

1. **A local server** (`server/server.ps1`) that listens on `127.0.0.1:8765`, serves the terminal UI, and bridges a WebSocket connection to a live `pwsh` process.
2. **A browser tab UI** (`web/`) that connects to that WebSocket, sends commands, and streams stdout/stderr back in real time.

Because it is just a loopback web server, it works identically in **Chrome** and **Comet** with no extension to install.

## Why

- Keep terminal-driven automation inside the same browser you use for everything else.
- Drive PowerShell from AI/browser workflows without a separate terminal window.
- Simple, auditable, single-machine tooling.

## Requirements

- Windows 10/11
- PowerShell 7 (`pwsh`) — install with `winget install --id Microsoft.PowerShell`

## Quick start (one command)

Clone, then run the installer from the repo root:

```powershell
git clone https://github.com/kfaali2022-web/pwbridge-tab.git
cd pwbridge-tab
pwsh -ExecutionPolicy Bypass -File .\install.ps1
```

The installer:

1. Verifies `pwsh` and required files.
2. Copies files to `%LOCALAPPDATA%\pwbridge-tab`.
3. Creates a **Start Menu shortcut** ("pwbridge-tab").
4. Starts the bridge and **opens the tab** at `http://127.0.0.1:8765/`.

In the tab, click **Connect**, then type a command and press **Enter**.

### Options

```powershell
# Custom port
pwsh -File .\install.ps1 -Port 9000

# Require a shared token (recommended)
pwsh -File .\install.ps1 -Token "my-secret"

# Start automatically at login
pwsh -File .\install.ps1 -AutoStart
```

When a token is set, enter it in the **Token** field in the tab before clicking Connect.

## Run without installing

```powershell
pwsh -ExecutionPolicy Bypass -File .\server\server.ps1 -Port 8765
```

Then open `http://127.0.0.1:8765/`.

## Usage

| Action | How |
| --- | --- |
| Run a command | Type in the input box, press Enter |
| Interrupt | Ctrl+C in the input box |
| Disconnect | Click Disconnect |
| Change target | Edit the WS URL field, reconnect |

Example: `Get-Process | Sort-Object CPU -Descending | Select -First 5`

## Uninstall

```powershell
pwsh -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the scheduled task, shortcut, and installed files. Your cloned repo is untouched.

## Security

pwbridge-tab exposes a **PowerShell shell over a local socket**. Treat it accordingly. Highlights:

- Binds to **loopback only** (`127.0.0.1`); non-loopback binds are refused.
- Optional shared-token auth via `?token=`.
- Nothing runs until you click **Connect** and send a command.

Read the full model in [SECURITY.md](SECURITY.md) before exposing this on a shared machine.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
- [SECURITY.md](SECURITY.md) — threat model and hardening
- [ROADMAP.md](ROADMAP.md) — planned features

## Status

Windows-first **alpha**. Tested manually. Feedback and issues welcome.

## License

MIT — see [LICENSE](LICENSE).
