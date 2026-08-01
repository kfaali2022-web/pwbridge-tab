@echo off
REM pwbridge-tab launcher. Every shortcut points here so the tester never has
REM to type a command. Uses Windows PowerShell, which ships with Windows 11.
setlocal
set "PWB_CMD=%~1"
if "%PWB_CMD%"=="" set "PWB_CMD=start"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0pwbridge.ps1" %PWB_CMD% %2 %3 %4
set "PWB_EXIT=%ERRORLEVEL%"

if not "%PWB_EXIT%"=="0" (
  echo.
  echo pwbridge-tab reported a problem ^(exit code %PWB_EXIT%^).
  echo Use the "pwbridge-tab Diagnostics" shortcut and send the zip to whoever asked you to test.
  pause
)
endlocal & exit /b %PWB_EXIT%
