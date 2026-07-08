# Contributing

Thanks for your interest in pwbridge-tab. This is an early Windows-first alpha, so contributions of all sizes are welcome — bug reports, docs, and code.

## Ways to help

- **Test it** on your machine and open an issue with your Windows + PowerShell version.
- **Report bugs** with steps to reproduce and any console output from `server.ps1`.
- **Improve the UI** (`web/`) or the server (`server/server.ps1`).
- **Docs** fixes are always appreciated.

## Dev setup

```powershell
git clone https://github.com/kfaali2022-web/pwbridge-tab.git
cd pwbridge-tab
pwsh -ExecutionPolicy Bypass -File .\server\server.ps1 -Port 8765
```

Then open `http://127.0.0.1:8765/` and click Connect.

## Pull requests

1. Fork and create a feature branch: `feat/short-description`.
2. Keep changes focused; one topic per PR.
3. Test the install + connect + run-command flow before submitting.
4. Update `README.md` / `ROADMAP.md` if behavior changes.
5. Describe what you changed and how you tested it.

## Style

- PowerShell: prefer explicit parameters, `$ErrorActionPreference = "Stop"`, and verify every file/registry write.
- JS: keep the client dependency-free for now.
- No telemetry, no network calls beyond loopback.

## Security

Do not open public issues with working exploit payloads. See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## Code of conduct

Be respectful and constructive. Assume good intent.
