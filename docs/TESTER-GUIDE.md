# pwbridge-tab tester guide

This guide assumes nothing. You do not need Git, Node.js, PowerShell 7, or a
command prompt. You need Windows 11, an Android phone and a USB cable.

## Before you start: what this program is

pwbridge-tab opens a page in your browser with two tabs.

- **PowerShell** — a real, live command prompt on your PC. Anything typed there
  runs immediately, as you, with all your permissions. It can read, change and
  delete your files. Only run commands you understand or that come from someone
  you trust.
- **Phone** — see and control an Android phone plugged in over USB.

It listens only on 127.0.0.1 (this PC only) and refuses to start on any other
address. It does not run as administrator. It does not start by itself.

## 1. Install

1. Download `pwbridge-tab-<version>-setup.exe`.
2. Optional but recommended — check the download is intact. Open the Start menu,
   type `powershell`, press Enter, then paste:

   ```powershell
   Get-FileHash "$env:USERPROFILE\Downloads\pwbridge-tab-0.2.0-setup.exe" -Algorithm SHA256
   ```

   The hash should match the one in `SHA256SUMS.txt` on the release page.
3. Double-click the EXE.
4. **Windows will show a blue "Windows protected your PC" box.** This is
   expected: the installer is not code-signed. Click **More info**, then
   **Run anyway**.
5. Read the warning page, accept the licence, click through. It installs into
   your own user folder and never asks for an administrator password.
6. Leave **Start pwbridge-tab now** ticked and click Finish.

## 2. First run

The first time it starts, it downloads about 11 MB of Android tools (scrcpy,
which includes adb) from their official servers. Each file is checked against a
known SHA-256 before it is used. This takes a few seconds on a normal
connection. A console window shows the progress and then closes.

Your browser opens at `http://127.0.0.1:8765`. The top right should say
`bridge v0.2.0` in green.

If you want to try the shell, click the **PowerShell** tab, type `Get-Date` and
press Enter.

## 3. Prepare your phone

You only have to do this once per phone.

1. On the phone, open **Settings → About phone**.
2. Tap **Build number** seven times. It will say "You are now a developer".
   - Samsung: **Settings → About phone → Software information → Build number**.
3. Go back to **Settings → System → Developer options** (Samsung: Settings →
   Developer options).
4. Turn on **USB debugging**.

## 4. Connect

1. Plug the phone into the PC with a USB cable. **Use a cable that can carry
   data** — some charge-only cables will not work, and this is the single most
   common problem.
2. On the phone, a box appears: **"Allow USB debugging?"** Unlock the phone,
   tick **Always allow from this computer**, tap **Allow**.
   - If no box appears, pull down the phone's notification shade, tap the USB
     notification, and choose **File transfer / Android Auto** rather than
     "Charging only".
3. In the browser, click the **Phone** tab, then **Check phone**.

You should see a green `phone ready` chip and your phone's model and Android
version.

## 5. See and control the phone

Two ways, use whichever works better for you.

**Open in scrcpy** (recommended) opens a separate window with a smooth, full
speed picture. You can click and type in that window normally. Close the window,
or click **Close scrcpy**, when you are done.

**Start preview** shows the phone inside the browser page. It is a few frames
per second — deliberately simple, because it needs nothing but adb, so it works
when everything else does not. In the preview:

- **Click** the screen to tap that spot.
- **Click and drag** to swipe.
- Use the **Home / Back / Recents / Power / Volume** buttons on the right.
- Type in the text box and press Enter to send text to the phone.
- Drag the **Frames per second** slider if it feels slow or is using too much
  battery.

## 6. Stopping

- **Stop bridge** in the browser page, or
- **Stop pwbridge-tab** in the Start menu, or
- just close the console window.

Stopping also closes any scrcpy window pwbridge-tab started.

## 7. If something goes wrong

The Start menu has three tools:

- **pwbridge-tab Doctor** — checks the prerequisites and the phone connection
  and prints what is wrong in plain language. Try this first.
- **Repair pwbridge-tab** — re-downloads and re-verifies the Android tools.
- **pwbridge-tab Diagnostics** — saves a zip to your Desktop that you can send
  for support. It contains logs, versions and tool paths. It does **not**
  contain your access token, and your phone's serial number is replaced with a
  short hash.

`docs\TROUBLESHOOTING.md` lists specific symptoms and fixes.

## 8. Uninstalling

**Settings → Apps → Installed apps → pwbridge-tab → Uninstall**, or use
**Add or remove programs**. It will ask whether to also delete the downloaded
Android tools and logs. Answer Yes for a clean removal.
