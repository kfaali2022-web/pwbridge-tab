# Roadmap

pwbridge-tab is a Windows-first alpha. This is the rough plan; issues and PRs
welcome.

## v0.1

- [x] Local WebSocket + static UI server (`server/server.ps1`)
- [x] Browser tab terminal UI (`web/`)
- [x] Stream stdout/stderr from a live `pwsh` session
- [x] Send commands, Ctrl+C interrupt
- [x] Loopback-only bind + optional token auth
- [x] One-command installer / uninstaller
- [x] Works in Chrome and Comet

## v0.2 (current — installer + Android)

- [x] Single per-user EXE installer, no administrator rights
- [x] Auto-generated token on first run, required on every request
- [x] Windows PowerShell 5.1 support, so PowerShell 7 is no longer a prerequisite
- [x] Concurrent request handling (a shell session no longer blocks the UI)
- [x] Android phone tab: auto-detected device, no configured serial
- [x] In-page screencap preview with tap, swipe, key and text injection
- [x] Native scrcpy launch and stop
- [x] Optional embed of a ws-scrcpy the tester already runs
- [x] Hash-pinned first-run download of scrcpy/adb from official hosts
- [x] Start / stop / status / doctor / setup / logs / diagnostics CLI
- [x] Diagnostics bundle command
- [x] Command history (up/down arrows)
- [x] Automated validation: syntax, PSScriptAnalyzer, Pester, JS/JSON checks
- [x] Tester guide and troubleshooting docs

## v0.3 (terminal quality)

- [ ] Proper terminal emulation (xterm.js) with colours and cursor control
- [ ] Auto-reconnect after a bridge restart
- [ ] PTY-style resize behaviour
- [ ] Multiple concurrent shell sessions
- [ ] Session transcript export
- [ ] Optional command allowlist mode

## v0.4 (distribution)

- [ ] Code-signed installer (removes the SmartScreen warning)
- [ ] Published GitHub Release with checksums
- [ ] Winget package
- [ ] Delta/upgrade-in-place polish

## v0.5 (phone)

- [ ] Hardware-accelerated in-page video instead of polled screenshots
- [ ] File push/pull between PC and phone
- [ ] Wireless (adb over Wi-Fi) pairing, opt-in only
- [ ] Screen recording capture

## Later / maybe

- [ ] macOS / Linux host (bash/zsh/pwsh)
- [ ] Org policy mode for managed installs
- [ ] Optional Chromium extension wrapper for a true one-click tab

## Non-goals

- Exposing the shell or adb to a network without a proper auth/TLS proxy
- Acting as a production remote-management tool
- Bundling third-party components whose licence forbids redistribution
