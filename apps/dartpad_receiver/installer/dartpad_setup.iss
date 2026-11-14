; DartPad Windows Installer Script (Inno Setup 6)
; Produces a single, one-click Windows Setup Wizard: DartPad-Setup.exe

#define MyAppName "DartPad Receiver"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "ferdlcx"
#define MyAppURL "https://github.com/ferdlcx/konsol"
#define MyAppExeName "DartPad.exe"

[Setup]
AppId={{8F4E2D1A-7C3B-49E1-9A2D-5B6C8E0F1A2B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\DartPad
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Install for current user by default (can overwrite existing DartPad.exe cleanly!)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\..\release-output
OutputBaseFilename=DartPad-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Buat Shortcut di Desktop (Create a &desktop shortcut)"; GroupDescription: "Shortcut & Otomatisasi:"
Name: "autostart"; Description: "Jalankan otomatis saat Windows menyala (Auto-Start untuk Auto-Pair HP)"; GroupDescription: "Shortcut & Otomatisasi:"

[Files]
Source: "..\..\..\DartPad.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Comment: "DartPad Virtual Gamepad Receiver & GUI Dashboard"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; Comment: "DartPad Virtual Gamepad Receiver & GUI Dashboard"

[Registry]
; Auto-Start when Windows boots so Android APK can Auto-Pair anytime over Wi-Fi or USB
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "DartPadReceiver"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

; Register dartpad:// URI scheme
Root: HKCU; Subkey: "Software\Classes\dartpad"; ValueType: string; ValueName: ""; ValueData: "URL:DartPad Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\dartpad"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\dartpad\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\dartpad\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
; Allow UDP 42100 & TCP 42101 in Windows Firewall so HP <-> PC Auto-Pair & QR work cleanly
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""DartPad Receiver UDP"" dir=in action=allow protocol=UDP localport=42100 profile=any"; Flags: runhidden; StatusMsg: "Mengatur izin Firewall UDP 42100..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""DartPad Receiver TCP"" dir=in action=allow protocol=TCP localport=42101 profile=any"; Flags: runhidden; StatusMsg: "Mengatur izin Firewall TCP 42101..."
Filename: "{app}\{#MyAppExeName}"; Description: "Jalankan {#MyAppName} (GUI Dashboard) sekarang"; Flags: nowait postinstall skipifsilent
