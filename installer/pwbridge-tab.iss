; pwbridge-tab Windows installer (Inno Setup 6.3 or newer).
;
; Produces a single per-user EXE. No administrator rights are requested: the
; app installs under %LOCALAPPDATA%\Programs and keeps all of its state under
; %LOCALAPPDATA%\pwbridge-tab.
;
; Build:  iscc /DAppVersion=0.2.0 installer\pwbridge-tab.iss
; See docs/BUILD-RELEASE.md.

#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif

; AppVersion is numeric because the version resource rejects a prerelease
; suffix. AppVersionLabel is the human-facing string, "0.2.0-alpha.2".
#ifndef AppVersionLabel
  #define AppVersionLabel AppVersion
#endif

#define AppName "pwbridge-tab"
#define AppPublisher "pwbridge-tab contributors"
#define AppUrl "https://github.com/kfaali2022-web/pwbridge-tab"

[Setup]
AppId={{7C2B9E14-3A57-4C1E-9E3E-6B1F0D2A8C41}
AppName={#AppName}
AppVersion={#AppVersionLabel}
AppVerName={#AppName} {#AppVersionLabel}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} setup

DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
AllowNoIcons=yes
LicenseFile=..\LICENSE
InfoBeforeFile=WARNING.txt
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVersionLabel}-setup
SetupIconFile=assets\pwbridge.ico
UninstallDisplayIcon={app}\installer\assets\pwbridge.ico
UninstallDisplayName={#AppName} {#AppVersionLabel}

; Per-user install: no UAC prompt, nothing written outside the user profile.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\server\server.ps1";            DestDir: "{app}\server";         Flags: ignoreversion
Source: "..\server\modules\*.psm1";        DestDir: "{app}\server\modules"; Flags: ignoreversion
Source: "..\web\*";                        DestDir: "{app}\web";            Flags: ignoreversion
Source: "..\tools\pwbridge.ps1";           DestDir: "{app}\tools";          Flags: ignoreversion
Source: "..\tools\pwbridge.cmd";           DestDir: "{app}\tools";          Flags: ignoreversion
Source: "..\tools\PwBridge.Deps.psm1";     DestDir: "{app}\tools";          Flags: ignoreversion
Source: "..\tools\deps.json";              DestDir: "{app}\tools";          Flags: ignoreversion
Source: "..\LICENSE";                      DestDir: "{app}";                Flags: ignoreversion
Source: "..\THIRD-PARTY-NOTICES.md";       DestDir: "{app}";                Flags: ignoreversion
Source: "..\README.md";                    DestDir: "{app}";                Flags: ignoreversion
Source: "..\SECURITY.md";                  DestDir: "{app}";                Flags: ignoreversion
Source: "..\docs\TESTER-GUIDE.md";         DestDir: "{app}\docs";           Flags: ignoreversion
Source: "..\docs\TROUBLESHOOTING.md";      DestDir: "{app}\docs";           Flags: ignoreversion
Source: "assets\pwbridge.ico";             DestDir: "{app}\installer\assets"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";                    Filename: "{app}\tools\pwbridge.cmd"; Parameters: "start";       IconFilename: "{app}\installer\assets\pwbridge.ico"; Comment: "Start the bridge and open the browser tab"
Name: "{group}\Stop {#AppName}";               Filename: "{app}\tools\pwbridge.cmd"; Parameters: "stop";        IconFilename: "{app}\installer\assets\pwbridge.ico"; Comment: "Stop the bridge and close anything it started"
Name: "{group}\{#AppName} Doctor";             Filename: "{app}\tools\pwbridge.cmd"; Parameters: "doctor";      IconFilename: "{app}\installer\assets\pwbridge.ico"; Comment: "Check prerequisites and the phone connection"
Name: "{group}\Repair {#AppName}";             Filename: "{app}\tools\pwbridge.cmd"; Parameters: "setup -Force"; IconFilename: "{app}\installer\assets\pwbridge.ico"; Comment: "Re-download and re-verify the Android tools"
Name: "{group}\{#AppName} Diagnostics";        Filename: "{app}\tools\pwbridge.cmd"; Parameters: "diagnostics"; IconFilename: "{app}\installer\assets\pwbridge.ico"; Comment: "Save a diagnostics zip to send for support"
Name: "{group}\Tester guide";                  Filename: "{app}\docs\TESTER-GUIDE.md"
Name: "{autodesktop}\{#AppName}";              Filename: "{app}\tools\pwbridge.cmd"; Parameters: "start";       IconFilename: "{app}\installer\assets\pwbridge.ico"; Tasks: desktopicon; Comment: "Start the bridge and open the browser tab"

[Run]
Filename: "{app}\tools\pwbridge.cmd"; Parameters: "start"; Description: "Start {#AppName} now"; Flags: postinstall nowait skipifsilent shellexec

[UninstallRun]
; Stop the bridge and any scrcpy window before the files are deleted.
Filename: "{app}\tools\pwbridge.cmd"; Parameters: "stop"; Flags: runhidden; RunOnceId: "StopBridge"

[Code]
function StateDir(): String;
begin
  Result := ExpandConstant('{localappdata}\pwbridge-tab');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Launcher: String;
begin
  // An upgrade over a running bridge would leave a stale process holding the
  // port, so stop it first if a previous install is present.
  if CurStep = ssInstall then
  begin
    Launcher := ExpandConstant('{app}\tools\pwbridge.cmd');
    if FileExists(Launcher) then
      Exec(ExpandConstant('{cmd}'), '/c "" "' + Launcher + '" stop', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Dir := StateDir();
    if DirExists(Dir) then
    begin
      if MsgBox('Also remove downloaded Android tools, logs and the local access token?' + #13#10 + #13#10 +
                Dir + #13#10 + #13#10 +
                'Choose No to keep them for a future reinstall.',
                mbConfirmation, MB_YESNO) = IDYES then
        DelTree(Dir, True, True, True);
    end;
  end;
end;
