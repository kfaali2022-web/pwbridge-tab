# Troubleshooting

Run **pwbridge-tab Doctor** from the Start menu first. It checks everything
below and prints what it finds. If you are sending a report, use
**pwbridge-tab Diagnostics** and attach the zip it saves to your Desktop.

## Installing and starting

### "Windows protected your PC" when running the installer

Expected. The EXE is not code-signed. Click **More info** → **Run anyway**.
Verify the SHA-256 against the release page first if you want to be careful.

### The browser tab says "unauthorized"

The tab does not have the access token. Close it and start pwbridge-tab from
its desktop or Start menu shortcut, which supplies the token. Typing
`127.0.0.1:8765` by hand will not work — that is the point of the token.

### The browser tab says "bridge offline"

The bridge is not running. Use the **pwbridge-tab** shortcut. If it exits
immediately, run **pwbridge-tab Doctor** to see the error.

### "Port 8765 is already in use"

Something else has the port. Either stop that program, or change the port:
edit `%LOCALAPPDATA%\pwbridge-tab\config.json`, set `"port"` to another number
such as `8790`, save, and start pwbridge-tab again.

### Nothing happens when I click the shortcut

Open **pwbridge-tab Doctor** instead — it keeps its window open and shows the
error. The most common cause is that your organisation's policy blocks
PowerShell script execution; the launcher already passes `-ExecutionPolicy
Bypass`, which handles the normal per-user case but cannot override a machine
policy set by an administrator.

### The first-run download fails

Symptoms: "Download failed" or "Checksum mismatch".

- Check you have internet access. The bridge needs `github.com` and (rarely)
  `dl.google.com` over HTTPS.
- A corporate proxy that rewrites TLS will cause a checksum mismatch. That is
  the check doing its job — the file that arrived is not the file we pinned.
  Try from a normal network.
- Then run **Repair pwbridge-tab** to retry.

## Phone connection

The Phone tab tells you which of these states you are in.

### "No phone detected"

- Use a cable that carries **data**, not just power. This is the most common
  cause by a wide margin — try a different cable before anything else.
- Try a different USB port; prefer a port directly on the PC over a hub.
- Pull down the phone's notification shade, tap the USB notification, and select
  **File transfer** rather than **Charging only**.
- Confirm **USB debugging** is on: Settings → Developer options.

### "Phone is connected but not authorised"

Unlock the phone. A dialog says **"Allow USB debugging?"** — tick **Always allow
from this computer** and tap **Allow**. If it never appears:

1. Settings → Developer options → **Revoke USB debugging authorisations**.
2. Unplug and replug the cable.
3. Watch the phone screen while it reconnects.

### "Phone is offline"

The device answered but is not usable. Unplug, wait five seconds, plug back in.
If it persists, turn USB debugging off and on again, or reboot the phone.

### "More than one device is connected"

Pick one from the dropdown that appears next to the Refresh button, or unplug
the others. Note that a running Android emulator counts as a device.

### "adb has no permission for this device" / device appears then vanishes

Usually a driver problem on Windows.

- Install the OEM USB driver for your phone
  (Samsung: Samsung USB Driver for Mobile Phones; Google: Google USB Driver).
- Some phone-manager applications (Samsung Smart Switch, Kies, Xiaomi Mi PC
  Suite, Vysor, Android Studio) run their own adb server that fights with ours.
  Close them, then run **Repair pwbridge-tab**.

## Mirroring

### "Open in scrcpy" fails

Run **Repair pwbridge-tab** to re-download and re-verify scrcpy. If it still
fails, use **Start preview** in the browser — it only needs adb.

### scrcpy opens then closes immediately

Usually the screen locked or the authorisation was revoked mid-session. Unlock
the phone and try again. On some Android 16 builds, disabling **Developer
options → Disable permission monitoring** is unnecessary; do not change
security settings you do not understand.

### The browser preview is very slow

That is expected — it is polled screenshots, not video. Lower the frames per
second slider (it reduces load, not smoothness, once you are below what your
phone can produce), or use **Open in scrcpy**, which is a real video stream.

### The preview stopped on its own

Three consecutive failed frames stop it, to avoid hammering a disconnected
phone. Check the phone is still unlocked and plugged in, then click
**Start preview** again.

### ws-scrcpy

pwbridge-tab does not install or require ws-scrcpy. If you happen to be running
one on `http://127.0.0.1:8000`, an **Embed ws-scrcpy** button appears and can
show it inside the page. It has been unreliable on Android 16 — if the embedded
view is black or stalls, close it and use native scrcpy instead.

## The PowerShell tab

### "Not connected. Press Connect first."

Click **Connect** in the toolbar. If it goes straight back to `disconnected`,
the bridge has stopped — restart it from the shortcut.

### A command is stuck

Press **Ctrl+C** in the command box (with no text selected). That kills the
running command and restarts the shell; you will see an italic note in the
output when it happens.

### Which PowerShell am I getting?

The status bar shows `shell: PowerShell 7` or `shell: Windows PowerShell 5.1`.
pwbridge-tab prefers PowerShell 7 if it is installed but never requires it.

## Getting help

Run **pwbridge-tab Diagnostics**. The zip contains the log, versions, tool
paths and health output. It never contains your access token, and device serials
are hashed. Attach it to an issue at
<https://github.com/kfaali2022-web/pwbridge-tab/issues>.
