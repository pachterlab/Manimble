; The Manimble for Windows installer (Inno Setup 6): Manimble-Windows-Setup.exe.
;
; build_release.ps1 -Installer compiles it from the staged, self-contained app:
;   ISCC.exe /DStage=<staged app folder> /DAppVersion=<VERSION> /O<output folder> installer\Manimble.iss
; With /DSign it also signs the uninstaller (ISCC gets the signing command as /Ssigntool=...).
;
; It installs for the current user only (no administrator rights), in %LOCALAPPDATA%\Programs\Manimble, the folder
; install_manimble.ps1 uses, so either one upgrades the other. Python with Manim is not part of it: the app's
; first-launch setup window installs that (install_dependencies.ps1) into %LOCALAPPDATA%\Manimble, which the
; uninstaller leaves alone, along with the user's settings and decks.

#ifndef Stage
  #error Pass /DStage=<the staged app folder>
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{CAC7746C-3631-4243-A2E0-5DEF5EA06309}
AppName=Manimble
AppVersion={#AppVersion}
AppVerName=Manimble {#AppVersion}
AppPublisher=Pachter Lab
AppPublisherURL=https://github.com/pachterlab/Manimble
AppSupportURL=https://github.com/pachterlab/Manimble/issues
AppUpdatesURL=https://github.com/pachterlab/Manimble/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Manimble
DisableDirPage=auto
DefaultGroupName=Manimble
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputBaseFilename=Manimble-Windows-Setup
SetupIconFile=..\Manimble\Assets\Manimble.ico
UninstallDisplayIcon={app}\Manimble.exe
UninstallDisplayName=Manimble
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; an open Manimble is closed for the upgrade (and not restarted: the last page offers to launch it)
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
#ifdef Sign
SignTool=signtool
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; an upgrade replaces the bundled engine and runtime whole, so files a newer version dropped don't linger
Type: filesandordirs; Name: "{app}\engine"

[UninstallDelete]
; folders an earlier install (install_manimble.ps1, or the zip unpacked here) made: gone once empty
Type: dirifempty; Name: "{app}\runtimes\win-x64\native"
Type: dirifempty; Name: "{app}\runtimes\win-x64"
Type: dirifempty; Name: "{app}\runtimes"
Type: dirifempty; Name: "{app}\examples\hello\deck"
Type: dirifempty; Name: "{app}\examples\hello"
Type: dirifempty; Name: "{app}\examples"
Type: dirifempty; Name: "{app}\Assets"
Type: dirifempty; Name: "{app}\Terminal"
Type: dirifempty; Name: "{app}\engine"
Type: dirifempty; Name: "{app}"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Manimble"; Filename: "{app}\Manimble.exe"; Comment: "Make slides with Manim by editing them on screen"
Name: "{userdesktop}\Manimble"; Filename: "{app}\Manimble.exe"; Tasks: desktopicon

[Registry]
; .manimble packages open in Manimble with their own icon (the app writes the same keys on start: FileAssociation.cs)
Root: HKCU; Subkey: "Software\Classes\.manimble"; ValueType: string; ValueName: ""; ValueData: "Manimble.Project"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.manimble"; ValueType: string; ValueName: "Content Type"; ValueData: "application/zip"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Manimble.Project"; ValueType: string; ValueName: ""; ValueData: "Manimble Project"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Manimble.Project\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\ManimbleDocument.ico"
Root: HKCU; Subkey: "Software\Classes\Manimble.Project\shell\open"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Manimble"
Root: HKCU; Subkey: "Software\Classes\Manimble.Project\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Manimble.exe"" ""%1"""

[Run]
Filename: "{app}\Manimble.exe"; Description: "{cm:LaunchProgram,Manimble}"; Flags: nowait postinstall skipifsilent
