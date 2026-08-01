# Security

pwbridge-tab runs **a real PowerShell shell and adb access reachable over a
local socket**. Anyone who can reach that socket and present the token can run
commands as your user, and can control any Android device you have authorised.
Read this before running it on a shared or untrusted machine.

## Trust boundary

- Commands execute on **your machine**, as **your Windows user**, with your full
  privileges. Nothing is elevated, and the installer never asks for
  administrator rights.
- The bridge binds to **loopback only** (`127.0.0.1`) and refuses to start on
  anything else. It is not exposed to your LAN, ever, by design.
- Nothing starts by itself. There is no service, no logon task, no autostart.

## Controls

### Authentication

A 256-bit token from `RandomNumberGenerator` is generated on first run and
stored in `%LOCALAPPDATA%\pwbridge-tab\config.json`, whose ACL is reset to the
current user only. Every HTTP request must present it in `X-PwBridge-Token`;
the WebSocket handshake presents it in `?token=` because browsers cannot set
headers on an upgrade. Comparison is constant-time.

The launcher hands the token to the browser in the URL. `app.js` moves it to
`sessionStorage` and strips it from the address bar immediately, so it does not
persist in browser history.

### Origin and CSRF

`Origin` is validated against the three loopback forms of the bridge's own port.
A malicious page on another origin therefore cannot use the API even if it
guesses the port — and it cannot guess the token either. A missing `Origin` is
accepted because same-origin `fetch` and WebSocket handshakes omit it.

The page is served under a strict CSP: `default-src 'self'`, no inline script or
style, `connect-src` limited to the bridge's own WebSocket, `base-uri 'none'`.
`frame-src` allows `127.0.0.1:8000` solely for the optional ws-scrcpy embed.

### Command injection

Every value that reaches an `adb shell` command line is validated against an
**allowlist**, not escaped:

- Keycodes must be one of ~27 literal `KEYCODE_*` names.
- Text must match `^[A-Za-z0-9 _.,:@\-+/?!#=]{0,500}$`. Quotes, `$`, backtick,
  `;`, `&`, `|`, `<`, `>`, `\` and `*` are rejected rather than escaped.
- Serials must match `^[A-Za-z0-9._:\-]{1,64}$`.
- Coordinates and durations are bounds-checked integers.

This matters because adb concatenates its arguments and runs them through the
device's `/system/bin/sh`. Rejecting is safer than quoting, and it is covered by
unit tests.

`Invoke-Adb` is the single choke point for device commands, so there is one
place to audit.

### Static file serving

Paths are resolved to a full path and must remain under the web root; anything
that escapes it returns 403 before touching the filesystem.

### Supply chain

Runtime downloads are pinned by URL **and** SHA-256 in `tools/deps.json`, must
be HTTPS, and must come from an allowlisted host (`github.com`,
`objects.githubusercontent.com`, `release-assets.githubusercontent.com`,
`dl.google.com`). A mismatch discards the file with an explicit message rather
than falling back to using it. Version numbers are pinned; nothing resolves
`/latest/`.

Nothing third-party is bundled in the installer, so the EXE contains only code
you can read in this repository.

### Diagnostics

The support bundle contains logs, versions and tool paths. It **never** contains
the access token, and device serials are replaced with a 12-hex-character
SHA-256 prefix.

### No device identity in the package

There is no configured or hard-coded serial anywhere. Device selection is purely
"what is attached and authorised", and a test asserts that no serial-shaped
constant appears in any shipped file.

## Residual risks

- **Any local process running as you** can read `config.json` and therefore use
  the bridge. On a single-user machine that process could already run PowerShell
  directly; on a shared machine, only run the bridge while you need it.
- **No sandboxing.** It is a full shell, by design. The installer says so before
  you install, and the page says so above the terminal.
- **No TLS.** Traffic is plaintext but never leaves loopback.
- **adb is transitive trust.** Once a phone is authorised, anything that can use
  the bridge can drive that phone.
- **The installer is unsigned**, so SmartScreen warns. Verify the published
  SHA-256 before running it. See `docs/BUILD-RELEASE.md` for what signing would
  take.

## Recommendations

- Stop the bridge when you are not using it (**Stop pwbridge-tab**, or the
  **Stop bridge** button).
- Revoke USB debugging authorisations on the phone when testing is finished.
- Do not edit `bind` to a non-loopback address. The code refuses it; if you
  patch that out, you are exposing a root-equivalent shell to your network.
- Verify the installer hash against the release page.

## Reporting a vulnerability

Open a private security advisory on this repository, or a GitHub issue for
non-sensitive reports. Please do not include working exploit payloads in public
issues.

## Scope

**Alpha**, for single-machine, single-user developer and tester use. Not
hardened for multi-tenant or production environments.
