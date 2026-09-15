; Inno Setup script for the Ghostty Windows installer.
;
; Compile through scripts/build-installer.ps1, which supplies every define
; below from the release tree and optionally configures Authenticode signing.
; Requires Inno Setup 6.3 or newer (x64compatible architecture names).
;
; Defines:
;   GhosttyVersion         Semantic version string, e.g. 1.3.2-windows.1
;   GhosttyNumericVersion  Four-part numeric version, e.g. 1.3.2.1
;   GhosttySourceDir       Release prefix that contains bin\ and share\
;   GhosttyOutputDir       Directory that receives the installer
;   GhosttyOutputBase      Installer file name without extension
;   GhosttySign            Defined when the installer and uninstaller are
;                          signed with the "ghosttysign" sign tool that the
;                          build script registers on the ISCC command line.

#ifndef GhosttyVersion
  #error GhosttyVersion must be defined (use scripts/build-installer.ps1)
#endif
#ifndef GhosttyNumericVersion
  #error GhosttyNumericVersion must be defined
#endif
#ifndef GhosttySourceDir
  #error GhosttySourceDir must be defined
#endif
#ifndef GhosttyOutputDir
  #define GhosttyOutputDir "..\..\zig-out\installer"
#endif
#ifndef GhosttyOutputBase
  #define GhosttyOutputBase "ghostty-" + GhosttyVersion + "-x64-setup"
#endif

[Setup]
; Keep this GUID stable across releases so upgrades replace the previous
; installation instead of creating a second entry.
AppId={{6F0C5B4E-2B6D-4E4A-9C2E-3A1D5F7B8C90}
AppName=Ghostty
AppVersion={#GhosttyVersion}
AppVerName=Ghostty {#GhosttyVersion}
AppPublisher=fukuyori
AppPublisherURL=https://github.com/fukuyori/ghostty
AppSupportURL=https://github.com/fukuyori/ghostty/issues
AppUpdatesURL=https://github.com/fukuyori/ghostty/releases
VersionInfoVersion={#GhosttyNumericVersion}
VersionInfoTextVersion={#GhosttyVersion}
VersionInfoProductTextVersion={#GhosttyVersion}
VersionInfoDescription=Ghostty terminal emulator setup
VersionInfoProductName=Ghostty
DefaultDirName={autopf}\Ghostty
DefaultGroupName=Ghostty
DisableProgramGroupPage=yes
UninstallDisplayName=Ghostty
UninstallDisplayIcon={app}\bin\ghostty.exe
LicenseFile=..\..\LICENSE
SetupIconFile=ghostty.ico
; The terminal is x64 only. x64compatible also covers Arm64 hosts that run
; x64 binaries through emulation.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user installs need no elevation; the dialog lets the user pick
; a machine-wide install under Program Files instead.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Windows 10 1809 is the oldest release with the DirectComposition and
; Per-Monitor V2 behaviour the Win32 app runtime relies on.
MinVersion=10.0.17763
OutputDir={#GhosttyOutputDir}
OutputBaseFilename={#GhosttyOutputBase}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
CloseApplications=yes
RestartApplications=no
#ifdef GhosttySign
SignTool=ghosttysign
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[CustomMessages]
english.AddToPath=Add Ghostty to the PATH environment variable
english.EnvironmentGroup=Environment:
japanese.AddToPath=環境変数 PATH に Ghostty を追加する
japanese.EnvironmentGroup=環境:

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "{cm:AddToPath}"; GroupDescription: "{cm:EnvironmentGroup}"; Flags: unchecked

[Files]
; The layout must stay bin\ + share\ because the executable locates its
; resources by climbing from its own path until share\terminfo\ghostty.terminfo
; is found; share\ghostty next to it then becomes the resources directory.
Source: "{#GhosttySourceDir}\bin\ghostty.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#GhosttySourceDir}\share\terminfo\ghostty.terminfo"; DestDir: "{app}\share\terminfo"; Flags: ignoreversion
Source: "{#GhosttySourceDir}\share\ghostty\*"; DestDir: "{app}\share\ghostty"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Ghostty"; Filename: "{app}\bin\ghostty.exe"; WorkingDir: "{userdocs}"
Name: "{group}\Uninstall Ghostty"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Ghostty"; Filename: "{app}\bin\ghostty.exe"; WorkingDir: "{userdocs}"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\ghostty.exe"; Description: "{cm:LaunchProgram,Ghostty}"; Flags: nowait postinstall skipifsilent

[Code]
// PATH is edited in the registry hive that matches the install mode:
// HKLM for machine-wide installs, HKCU for per-user installs. The
// ChangesEnvironment directive makes Setup broadcast the change afterwards.

const
  MachineEnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  UserEnvironmentKey = 'Environment';

function EnvironmentRootKey: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function EnvironmentSubKey: String;
begin
  if IsAdminInstallMode then
    Result := MachineEnvironmentKey
  else
    Result := UserEnvironmentKey;
end;

function PathContains(const Path, Dir: String): Boolean;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') > 0;
end;

procedure AddDirToPath(const Dir: String);
var
  Path: String;
begin
  if not RegQueryStringValue(EnvironmentRootKey, EnvironmentSubKey, 'Path', Path) then
    Path := '';
  if PathContains(Path, Dir) then
    exit;
  if (Path <> '') and (Path[Length(Path)] <> ';') then
    Path := Path + ';';
  Path := Path + Dir;
  if not RegWriteExpandStringValue(EnvironmentRootKey, EnvironmentSubKey, 'Path', Path) then
    Log('Failed to add ' + Dir + ' to PATH');
end;

procedure RemoveDirFromPath(const Dir: String);
var
  Path, Rebuilt, Entry: String;
  Start, Sep: Integer;
begin
  if not RegQueryStringValue(EnvironmentRootKey, EnvironmentSubKey, 'Path', Path) then
    exit;
  if not PathContains(Path, Dir) then
    exit;

  Rebuilt := '';
  Start := 1;
  while Start <= Length(Path) do
  begin
    Sep := Pos(';', Copy(Path, Start, Length(Path) - Start + 1));
    if Sep = 0 then
      Entry := Copy(Path, Start, Length(Path) - Start + 1)
    else
      Entry := Copy(Path, Start, Sep - 1);
    if (Entry <> '') and (Uppercase(Entry) <> Uppercase(Dir)) then
    begin
      if Rebuilt <> '' then
        Rebuilt := Rebuilt + ';';
      Rebuilt := Rebuilt + Entry;
    end;
    if Sep = 0 then
      break;
    Start := Start + Sep;
  end;

  if not RegWriteExpandStringValue(EnvironmentRootKey, EnvironmentSubKey, 'Path', Rebuilt) then
    Log('Failed to remove ' + Dir + ' from PATH');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddDirToPath(ExpandConstant('{app}\bin'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveDirFromPath(ExpandConstant('{app}\bin'));
end;
