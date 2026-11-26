; TallyIsle Windows Inno Setup 6 Installer Script (x64 / arm64)
; Version, build number, arch, source directory, output directory, and repo root
; are injected dynamically by tool/packaging/windows/package_windows.ps1.

#ifndef MyAppVersion
  #error "MyAppVersion must be provided via /DMyAppVersion=X.Y.Z"
#endif
#ifndef MyBuildNumber
  #error "MyBuildNumber must be provided via /DMyBuildNumber=N"
#endif
#ifndef MyArch
  #define MyArch "x64"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\..\build\windows\" + MyArch + "\runner\Release"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\.."
#endif
#ifndef MyRepoRoot
  #define MyRepoRoot "..\..\.."
#endif

[Setup]
AppId={{6D8A4E72-9F31-4C5B-8A10-2E7B9C4D5F61}
AppName=TallyIsle
AppVersion={#MyAppVersion}
AppVerName=TallyIsle {#MyAppVersion}
AppPublisher=TallyIsle
AppPublisherURL=https://github.com/tallyisle/tallyisle
AppSupportURL=https://github.com/tallyisle/tallyisle/issues
AppUpdatesURL=https://github.com/tallyisle/tallyisle/releases
DefaultDirName={autopf}\TallyIsle
DefaultGroupName=TallyIsle
AllowNoIcons=yes
#if MyArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
#if Ver >= EncodeVer(6, 3, 0, 0)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#endif
#endif
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#MyOutputDir}
OutputBaseFilename=TallyIsle-Windows-{#MyArch}-setup
SetupIconFile={#MyRepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\tallyisle.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
VersionInfoVersion={#MyAppVersion}.{#MyBuildNumber}
VersionInfoProductName=TallyIsle
VersionInfoDescription=TallyIsle Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#elif FileExists(AddBackslash(CompilerPath) + "Languages\Unofficial\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\Unofficial\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\TallyIsle"; Filename: "{app}\tallyisle.exe"
Name: "{group}\{cm:UninstallProgram,TallyIsle}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\TallyIsle"; Filename: "{app}\tallyisle.exe"; Tasks: desktopicon

[Registry]
; Exclusively register tallyisle:// URL protocol
Root: HKCU; Subkey: "Software\Classes\tallyisle"; ValueType: string; ValueName: ""; ValueData: "URL:TallyIsle Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\tallyisle"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\tallyisle\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\tallyisle.exe"",0"
Root: HKCU; Subkey: "Software\Classes\tallyisle\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\tallyisle.exe"" ""%1"""

; Register .tally backup file association
Root: HKCU; Subkey: "Software\Classes\.tally"; ValueType: string; ValueName: ""; ValueData: "TallyIsle.Backup"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\TallyIsle.Backup"; ValueType: string; ValueName: ""; ValueData: "TallyIsle Backup Archive"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\TallyIsle.Backup\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\tallyisle.exe"",0"
Root: HKCU; Subkey: "Software\Classes\TallyIsle.Backup\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\tallyisle.exe"" ""%1"""

[Run]
Filename: "{app}\tallyisle.exe"; Description: "{cm:LaunchProgram,TallyIsle}"; Flags: nowait postinstall skipifsilent
