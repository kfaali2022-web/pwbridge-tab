# pwbridge-tab

![status](https://img.shields.io/badge/status-alpha-orange) ![platform](https://img.shields.io/badge/platform-Windows-blue) ![shell](https://img.shields.io/badge/shell-PowerShell%205.1%20%7C%207-5391FE) ![license](https://img.shields.io/badge/license-MIT-green)

A PowerShell console **and an Android phone** in a browser tab. The UI runs in
your browser; everything executes **locally** through a small loopback bridge.
Windows-first alpha. MIT licensed.

> Your shell and your phone stay in the browser workspace where you already
> work, but nothing runs off your machine.

---

## What it is

Two tabs on one local page:

1. **PowerShell** — a live shell on this PC over a WebSocket to `127.0.0.1:8765`.
2. **Phone** — an Android device connected over USB, mirrored and controllable
   from the same page.

No browser extension, no cloud, no inbound network exposure.

## Install (testers)

Download `pwbridge-tab-<version>-setup.exe` from the
[releases page](https://github.com/kfaali2022-web/pwbridge-tab/releases) and run
it. It installs per-user, asks for no administrator password, and creates
desktop and Start Menu shortcuts.

**You do not need Git, Node.js, PowerShell 7, or a command prompt.**

Step-by-step with screenshots of what to expect (including the SmartScreen
warning): **[docs/TESTER-GUIDE.md](docs/TESTER-GUIDE.md)**.

On first run it downloads ~11 MB of Android tools (scrcpy, which ships adb) from
their official servers and checks each archive against a pinned SHA-256 before
using it. Nothing third-party is bundled in the EXE — see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Using the phone tab

1. On the phone: Settings → About phone → tap **Build number** seven times, then
   Developer options → **USB debugging** on.
2. Plug it in with a **data** cable and tap **Allow** on the "Allow USB
   debugging?" prompt.
3. In the browser, open the **Phone** tab and click **Check phone**.

Any authorised device is detected automatically — no serial is configured
anywhere. If several are plugged in, a picker appears. Unauthorised, offline,
missing-driver and no-device states each get a specific message telling you what
to do next.

Two ways to see the screen:

| | Quality | Needs |
| --- | --- | --- |
| **Open in scrcpy** | Full frame rate video in its own window | scrcpy (downloaded on first run) |
| **Start preview** | A few frames per second, in the page | adb only — the dependable fallback |

The in-page preview supports click-to-tap, drag-to-swipe, hardware keys and text
entry. If you already run your own [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy)
on port 8000, an **Embed ws-scrcpy** button appears; pwbridge-tab never installs
or requires one.

## Start, stop, diagnose

From the Start Menu, or from `tools\pwbridge.cmd`:

| Command | What it does |
| --- | --- |
| `pwbridge start` | Start the bridge and open the tab |
| `pwbridge stop` | Stop the bridge and anything it launched |
| `pwbridge status` | Is it running, on which port, with which device |
| `pwbridge doctor` | Check prerequisites and the phone connection |
| `pwbridge setup -Force` | Re-download and re-verify the Android tools |
| `pwbridge logs` | Tail the log |
| `pwbridge diagnostics` | Write a support zip to the Desktop |

The browser page also has **Stop bridge** and **Logs / diagnostics** buttons.

## Run from source

```powershell
git clone https://github.com/kfaali2022-web/pwbridge-tab.git
cd pwbridge-tab
powershell -ExecutionPolicy Bypass -File .\tools\pwbridge.ps1 start
```

Or the server alone, without the launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\server\server.ps1 -Port 8765
```

`install.ps1` / `uninstall.ps1` remain as the source-tree install path for
developers; testers should use the EXE.

## Building the installer

```powershell
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

Needs [Inno Setup 6.3+](https://jrsoftware.org/isdl.php). Output lands in
`dist\`. CI builds the same artifact on every push. See
[docs/BUILD-RELEASE.md](docs/BUILD-RELEASE.md).

## Security

pwbridge-tab exposes **a real shell and adb over a local socket**. Treat it
accordingly.

- Binds to **loopback only**; a non-loopback bind is refused outright.
- A unique 256-bit token is generated per machine on first run and required on
  every request and on the WebSocket handshake.
- Cross-origin requests are rejected; the page runs under a strict CSP.
- Runs as **you**, never elevated. Nothing starts by itself.
- Every value that reaches an `adb shell` command line is allowlist-validated,
  not escaped.
- Diagnostics bundles exclude the token and hash device serials.

Full model: [SECURITY.md](SECURITY.md).

## Documentation

- [docs/TESTER-GUIDE.md](docs/TESTER-GUIDE.md) — install and use, assuming nothing
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — symptoms and fixes
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
- [SECURITY.md](SECURITY.md) — threat model and hardening
- [docs/BUILD-RELEASE.md](docs/BUILD-RELEASE.md) — building and releasing the EXE
- [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) — licences and what is downloaded
- [ROADMAP.md](ROADMAP.md) — planned features

## Status

Windows-first **alpha**. Automated validation runs on every push; the phone path
is manually tested. Feedback and issues welcome.

## License

MIT — see [LICENSE](LICENSE).
