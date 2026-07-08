# Security

pwbridge-tab runs a **PowerShell shell reachable over a local WebSocket**. Anyone who can reach that socket and pass the (optional) token can run commands as your user. Read this before running it on a shared or untrusted machine.

## Trust boundary

- Commands execute on **your machine**, as **your Windows user**, with your full privileges.
- The server binds to **loopback only** (`127.0.0.1`). The script refuses non-loopback binds.
- Only processes on the same machine can connect. It is **not** exposed to your LAN by default.

## Built-in protections

1. **Loopback-only bind.** `-Bind` is validated; anything other than `127.0.0.1`/`localhost` aborts startup.
2. **Optional token.** Start with `-Token "secret"`; connections without `?token=secret` get `401`.
3. **Explicit connect.** No shell exists until the tab connects and you send a command.
4. **Per-connection process.** Each WebSocket gets its own `pwsh`, killed on disconnect.

## Residual risks

- **Local malware / other local users** could connect to the port. Use a token, and prefer machines where you are the only user.
- **CSRF-style access:** a malicious web page in the same browser could attempt to open a WebSocket to `127.0.0.1`. A token mitigates this because the page cannot guess it. **Always set a token if you keep the bridge running.**
- **No sandboxing.** Commands are not restricted; this is a full shell.
- **No TLS.** Traffic is plaintext, but it never leaves loopback.

## Recommendations

- Set a token: `install.ps1 -Token "$(New-Guid)"`.
- Only run the bridge while you need it; use `uninstall.ps1` or close the process otherwise.
- Do not use `-AutoStart` on shared machines.
- Do not change `-Bind` to expose it to a network. If you must, put it behind a real reverse proxy with auth and TLS — that is out of scope for this project.

## Reporting a vulnerability

Open a GitHub issue, or for sensitive reports use a private security advisory on this repository. Please do not include working exploit payloads in public issues.

## Scope

This is an **alpha** tool for single-machine, single-user developer use. It is not hardened for multi-tenant or production environments.
