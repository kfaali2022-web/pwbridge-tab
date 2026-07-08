# Roadmap

pwbridge-tab is a Windows-first alpha. This is the rough plan; issues and PRs welcome.

## v0.1 (current alpha)

- [x] Local WebSocket + static UI server (`server/server.ps1`)
- [x] Browser tab terminal UI (`web/`)
- [x] Stream stdout/stderr from a live `pwsh` session
- [x] Send commands, Ctrl+C interrupt
- [x] Loopback-only bind + optional token auth
- [x] One-command installer / uninstaller
- [x] Works in Chrome and Comet

## v0.2 (usability)

- [ ] Proper terminal emulation (xterm.js) with colors and cursor control
- [ ] Command history (up/down arrows)
- [ ] Reconnect / auto-reconnect handling
- [ ] Resize / PTY-style behavior
- [ ] Copy/paste polish
- [ ] Persistent "connected" indicator and session log

## v0.3 (safety + multi-session)

- [ ] Multiple tabs / sessions
- [ ] Optional command allowlist mode
- [ ] Session transcript export
- [ ] Auto-generated token on install by default
- [ ] Diagnostics bundle command

## v0.4 (distribution)

- [ ] Signed installer (MSI/EXE)
- [ ] GitHub Releases with checksums
- [ ] Winget package
- [ ] Optional Chromium extension wrapper for a true one-click tab

## Later / maybe

- [ ] Windows PowerShell (5.1) fallback
- [ ] macOS / Linux host (bash/zsh/pwsh)
- [ ] File upload/download helpers
- [ ] Org policy mode for managed installs

## Non-goals

- Exposing the shell to a network without a proper auth/TLS proxy
- Acting as a production remote-management tool
