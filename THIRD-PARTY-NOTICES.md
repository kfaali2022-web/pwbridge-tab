# Third-party notices

pwbridge-tab itself is MIT licensed (see `LICENSE`).

**No third-party binaries are bundled in the installer.** The setup EXE contains
only files from this repository. The Android tools below are downloaded on first
run, from their official release servers over HTTPS, and each archive is checked
against a pinned SHA-256 in `tools/deps.json` before it is unpacked. They are
stored under `%LOCALAPPDATA%\pwbridge-tab\runtime` and are removed when you
uninstall (if you answer Yes to the prompt).

## scrcpy

- Project: <https://github.com/Genymobile/scrcpy>
- Version pinned: 4.1 (`scrcpy-win64-v4.1.zip`)
- Copyright: Copyright (C) 2018 Genymobile, Copyright (C) 2018-2025 Romain Vimont
- Licence: Apache License 2.0 — <https://www.apache.org/licenses/LICENSE-2.0>

scrcpy is redistributable under Apache-2.0, but pwbridge-tab still downloads it
rather than bundling it, so that the tester provably gets an unmodified official
build and so the installer stays small.

The Windows release of scrcpy bundles its own `adb.exe`, plus FFmpeg and SDL2.
The full notices for those components ship inside the scrcpy archive; see the
`LICENSE` and `NOTICE` files in `%LOCALAPPDATA%\pwbridge-tab\runtime\scrcpy`
after first run.

## Android SDK Platform-Tools (adb)

- Source: <https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip>
- Version pinned: 37.0.1
- Copyright: Copyright (C) The Android Open Source Project
- Licence: Android Software Development Kit License Agreement —
  <https://developer.android.com/studio/terms>

**Not redistributable.** The Android SDK licence does not permit us to
redistribute platform-tools, so it is marked `"redistributable": false` in
`tools/deps.json` and is never placed in the installer. It is downloaded
directly from Google, by you, on your machine, and only as a *fallback* when
`adb.exe` cannot be found — normally the copy inside scrcpy is used and this
download never happens.

By letting pwbridge-tab download platform-tools you accept the Android SDK
licence agreement linked above.

## ws-scrcpy

- Project: <https://github.com/NetrisTV/ws-scrcpy>
- Licence: MIT

ws-scrcpy is **not downloaded, installed, bundled or required**. pwbridge-tab
only probes `http://127.0.0.1:8000` and, if you happen to already be running
ws-scrcpy yourself, offers to embed it in the phone tab. Nothing about
pwbridge-tab depends on it.

## Inno Setup

- Project: <https://jrsoftware.org/isinfo.php>
- Licence: Inno Setup License (permits distribution of installers it produces)

Used as a build tool only. Inno Setup's own installer stub code is embedded in
the produced EXE, which its licence expressly allows.
