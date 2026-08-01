# Building and releasing the installer

## What the EXE contains

Only files from this repository: `server/`, `web/`, `tools/`, the docs and the
licence. No third-party binaries — see `THIRD-PARTY-NOTICES.md` for why, and
`tools/deps.json` for what is fetched at first run instead.

## Prerequisites

- Windows 10 1809 or newer, x64
- [Inno Setup 6.3+](https://jrsoftware.org/isdl.php)
- PowerShell 5.1 (in-box) — PowerShell 7 optional
- For validation: `Install-Module Pester -MinimumVersion 5.5.0` and
  `Install-Module PSScriptAnalyzer`

## Local build

```powershell
git clone https://github.com/kfaali2022-web/pwbridge-tab.git
cd pwbridge-tab
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

Output:

```
dist\pwbridge-tab-<version>-setup.exe
dist\pwbridge-tab-<version>-setup.exe.sha256
```

`build.ps1` runs the full validation suite first. Pass `-SkipValidation` to skip
it, `-Version 0.3.0` to override the version, or `-IsccPath` if `ISCC.exe` is
not on `PATH` or in a default location.

The compiler is located by `installer\Ensure-InnoSetup.ps1`, which checks
`PATH`, the default install directories and the uninstall registry key, and
accepts anything 6.3 or newer. A local build never installs Inno Setup for you;
CI runs the same script with `-Install` so it falls back to Chocolatey only when
the runner image has none.

Compiling the `.iss` directly also works:

```powershell
iscc /DAppVersion=0.2.0 installer\pwbridge-tab.iss
```

## Validation

```powershell
pwsh -File tests\Invoke-Tests.ps1
```

This runs:

| Check | What it covers |
| --- | --- |
| `tests\Test-Syntax.ps1` | Every `.ps1`/`.psm1` parses. Run it under Windows PowerShell 5.1 to catch PS7-only syntax. |
| `tests\Invoke-Lint.ps1` | PSScriptAnalyzer, errors and warnings fail the build. |
| Pester `tests\*.Tests.ps1` | Unit tests for the adb parsers, device-state resolution, input validation, auth and the dependency manifest. |
| Manifest tests | `deps.json` schema, SHA-256 format, HTTPS-only, host allowlist. |
| Packaging tests | Every `Source:` in the `.iss` exists; the `.iss` version matches `Get-PwBridgeVersion`. |

CI (`.github/workflows/ci.yml`) runs the same thing on `windows-latest` on every
push and PR, then builds the installer and uploads it as a workflow artifact.
That artifact is the easiest way to get a test build without tagging.

## Version bump

`Get-PwBridgeVersion` in `server/modules/PwBridge.Common.psm1` is the single
source of truth. The `.iss` default and the release workflow both defer to it,
and a Pester test plus a release-workflow guard fail if they drift.

To release 0.3.0:

1. Edit `Get-PwBridgeVersion` to return `'0.3.0'`.
2. Update `README.md` / `docs/TESTER-GUIDE.md` if the version appears in an
   example command.
3. Commit, open a PR, merge.
4. `git tag v0.3.0 && git push origin v0.3.0`.

## Release

Pushing a `v*` tag runs `.github/workflows/release.yml`, which validates,
builds, writes `SHA256SUMS.txt` and creates a **draft** GitHub release with the
EXE attached. Publishing the draft is a manual step — review the artifact first.

`workflow_dispatch` with a `version` input does the same thing without a tag.

## Reproducibility

Same commit + same Inno Setup version + same LZMA2 settings gives a
byte-identical EXE, with the exception of the timestamp Inno embeds in the
`VersionInfo` resource. CI does not pin an exact compiler version — it takes
whatever the runner image provides, so two builds months apart may differ. To
compare two builds, build them on one machine, or pass `-IsccPath` to point both
at the same compiler. Publishing `SHA256SUMS.txt` alongside the EXE is what
actually lets a tester verify what they downloaded.

## Code signing

The EXE is unsigned, so SmartScreen warns on first run. Signing needs an
Authenticode certificate, which is a purchase and an organisational decision,
not a code change. When one is available:

1. Add the PFX and password as repository secrets.
2. Add a `signtool sign /fd sha256 /tr <timestamp-url> /td sha256` step to
   `release.yml` after the build.
3. Optionally set `SignTool=` in the `[Setup]` section so Inno signs the
   uninstaller too.

Until then, `SHA256SUMS.txt` and the "More info → Run anyway" instructions in
the tester guide are the mitigation.
