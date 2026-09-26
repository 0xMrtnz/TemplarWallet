; Inno Setup script for the Templar Wallet Windows installer.
;
; Build (on Windows, after `flutter build windows --release`):
;   iscc packaging\windows\templar-wallet.iss
;
; The compiler is free: https://jrsoftware.org/isdl.php  (or: winget install
; JRSoftware.InnoSetup). Output lands in dist\.
;
; Override the version at compile time so it tracks pubspec.yaml:
;   iscc /DMyAppVersion=0.1.0 packaging\windows\templar-wallet.iss
;
; CODE SIGNING: an unsigned installer triggers SmartScreen ("Windows protected
; your PC"). To sign, define a SignTool named "templar" in the IDE
; (Tools > Configure Sign Tools) or pass /Stemplar=... on the command line, then
; compile with /DSIGN. See docs/build/RELEASE.md.

#define MyAppName "Templar Wallet"
#define MyAppPublisher "Templar Wallet"
#define MyAppURL "https://github.com/0xB4LdW1n/TemplarWallet"
#define MyAppExeName "templar_wallet.exe"

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

; Path to the Flutter release bundle, relative to this .iss file.
#define BundleDir "..\..\src\templar_wallet\build\windows\x64\runner\Release"

[Setup]
; Never reuse this GUID for another product — it is the identity Windows uses
; to recognise an upgrade of this app rather than a second copy of it.
AppId={{96397739-22B0-44B1-99C3-D44E5279D6EA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Two folders are chosen in this wizard and they are not interchangeable:
;   {app}  — the program. Replaced wholesale by the next update.
;   data   — wallets, vault and cache. Never written by an update or removed
;            by the uninstaller. Picked on the custom page below ([Code]).
; "auto" (the default) hides the destination page as soon as a previous
; install is found, which is exactly when someone reinstalling wants to move
; the program to another drive. Always ask.
DisableDirPage=no
; Both chosen paths are restated on the Ready page, before anything is written.
AlwaysShowDirOnReadyPage=yes
; Windows-specific plain text, not the Markdown release notes: Inno renders
; Markdown as raw text.
InfoBeforeFile=info-before.txt
; Inno's modern style hides the welcome page by default. Keep it: it is where
; the branded artwork and the testnet warning are read, before anything is
; written to disk.
DisableWelcomePage=no
OutputDir=..\..\dist
OutputBaseFilename=TemplarWallet-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\..\src\templar_wallet\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
WizardImageFile=wizard-large.bmp
WizardSmallImageFile=wizard-small.bmp
; The Flutter desktop embedder is x64-only.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-machine install when elevation is available, per-user otherwise, so the
; installer never dead-ends on a locked-down account.
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0.17763

#ifdef SIGN
SignTool=templar
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter bundle: executable, ICU data, the Flutter engine DLL, the
; Rust FFI library, and the assets tree. Anything missing here surfaces at
; runtime as a blank window, not a build error.
Source: "{#BundleDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BundleDir}\*.dll";           DestDir: "{app}"; Flags: ignoreversion
Source: "{#BundleDir}\data\*";          DestDir: "{app}\data"; \
  Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\docs\RELEASE_NOTES.md";  DestDir: "{app}"; \
  DestName: "README.md"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";           Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";     Filename: "{app}\{#MyAppExeName}"; \
  Tasks: desktopicon

[Registry]
; templar:// URL scheme (Templar Protocol loan requests). HKA = HKLM for a per-machine
; install, HKCU for a per-user one; uninstall removes the keys.
Root: HKA; Subkey: "Software\Classes\templar"; ValueType: string; ValueName: ""; \
  ValueData: "URL:Templar Protocol"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\templar"; ValueType: string; ValueName: "URL Protocol"; \
  ValueData: ""
Root: HKA; Subkey: "Software\Classes\templar\DefaultIcon"; ValueType: string; ValueName: ""; \
  ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\templar\shell\open\command"; ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; \
  Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Crash logs the app writes beside itself, and the install-time marker written
; by [Code] (files created there are not logged, so they are not removed
; automatically). The wallet data folder is deliberately LEFT BEHIND wherever
; the user put it: uninstalling must never destroy someone's keys.
Type: filesandordirs; Name: "{app}\logs"
Type: files;          Name: "{app}\install.conf"

[Messages]
WelcomeLabel1=Install [name]
WelcomeLabel2=This will install [name/ver] on your computer.%n%nTemplar Wallet is a Bitcoin and Liquid wallet for the TEST networks only - it has no mainnet spending path. Do not use it with real funds.%n%nIt is recommended that you close all other applications before continuing.
; The default finish page says nothing about the two things a first-time user
; needs to know next.
; Fallback wording only — CurPageChanged rewrites this with the data folder
; the user actually picked.
FinishedLabel=Setup has finished installing [name] on your computer.%n%nOn first run you will set an app password (it encrypts wallet storage on this computer) and write down a recovery phrase. Your wallet data folder is left in place if you uninstall.
; Said where the choice is made, not afterwards.
SelectDirDesc=Where should [name] be installed?%n%nThis folder holds the program only, and an update replaces all of it. The next page asks where to keep your wallets and keys.

[Code]
// ── Wallet data folder ───────────────────────────────────────────────────────
//
// A second destination the user chooses, because the program folder is the
// wrong place for it: the app directory is replaced by every update and is
// read-only for normal accounts under a per-machine install, while wallets,
// the encrypted vault and the chain cache have to outlive both.
//
// The choice is handed to the app in install.conf beside the executable,
// which wallet-ffi reads ONCE — on the first run of a fresh install, when it
// has no config of its own yet (AppFfiState::new, src/wallet-ffi/src/state.rs).
// From then on the app remembers the location itself, so a later reinstall can
// never redirect an existing user away from the wallets they already have.
//
// NOTE: Pascal block comments do not nest here, so every comment in this
// section is a // line — a brace-quoted one containing an Inno constant would
// end at that constant's closing brace and spill code into the compiler.

var
  DataDirPage: TInputDirWizardPage;

function DefaultDataDir: String;
begin
  Result := ExpandConstant('{userappdata}\templar_wallet');
end;

procedure InitializeWizard;
var
  Param: String;
begin
  DataDirPage := CreateInputDirPage(wpSelectDir,
    'Select Wallet Data Location',
    'Where should Templar Wallet keep your wallets and keys?',
    'Your wallets, the encrypted vault and the transaction cache are stored in the folder below.'#13#10 +
    'It is kept separate from the program folder on purpose: updates never write to it, and uninstalling Templar Wallet leaves it untouched.'#13#10#13#10 +
    'Choose a folder you back up, then click Next.',
    False, '');
  DataDirPage.Add('');

  // /DATADIR="..." wins (unattended installs), then the folder chosen by a
  // previous run of this installer, then the per-user default.
  Param := ExpandConstant('{param:datadir|}');
  if Param <> '' then
    DataDirPage.Values[0] := Param
  else
    DataDirPage.Values[0] := GetPreviousData('DataDir', DefaultDataDir);
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'DataDir', DataDirPage.Values[0]);
end;

function IsInsideAppDir(const Path: String): Boolean;
var
  App: String;
begin
  App := AddBackslash(ExpandConstant('{app}'));
  Result := CompareText(Copy(AddBackslash(Path), 1, Length(App)), App) = 0;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Dir: String;
begin
  Result := True;
  if CurPageID <> DataDirPage.ID then
    Exit;

  Dir := Trim(DataDirPage.Values[0]);
  if Dir = '' then
  begin
    MsgBox('Choose a folder for your wallet data.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if IsInsideAppDir(Dir) then
  begin
    MsgBox('Wallet data cannot live inside the program folder.'#13#10#13#10 +
           'An update replaces everything in ' + ExpandConstant('{app}') +
           ', and on a per-machine install that folder is read-only for normal accounts.'#13#10#13#10 +
           'Pick a folder outside it.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  // Created now rather than at first run: a path on a drive that is not there,
  // or one this account cannot write to, is worth catching while the user is
  // still looking at the folder they typed.
  if not ForceDirectories(Dir) then
  begin
    MsgBox('Setup could not create' + #13#10#13#10 + Dir + #13#10#13#10 +
           'Pick a folder you can write to.', mbError, MB_OK);
    Result := False;
  end;
end;

function UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo,
  MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
            'Wallet data location:' + NewLine +
            Space + DataDirPage.Values[0] + NewLine +
            Space + '(kept if you uninstall)' + NewLine;
  if MemoGroupInfo <> '' then
    Result := Result + NewLine + MemoGroupInfo + NewLine;
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + MemoTasksInfo + NewLine;
end;

// How the path is written to install.conf. A folder under the installing
// user's AppData is stored as an unexpanded %APPDATA% reference, so that ONE
// per-machine install still gives every Windows account on the box its own
// private wallet folder instead of pointing them all at the installing user's
// profile. wallet-ffi expands %NAME% references when it reads the file.
function PortableDataDir(const Dir: String): String;
var
  Roaming, Rest: String;
begin
  Roaming := AddBackslash(ExpandConstant('{userappdata}'));
  if CompareText(Copy(AddBackslash(Dir), 1, Length(Roaming)), Roaming) = 0 then
  begin
    Rest := Copy(Dir, Length(Roaming) + 1, MaxInt);
    if Rest = '' then
      Result := '%APPDATA%'
    else
      Result := '%APPDATA%\' + Rest;
  end
  else
    Result := Dir;
end;

procedure WriteInstallConf;
var
  Lines: TArrayOfString;
begin
  SetArrayLength(Lines, 6);
  Lines[0] := '# Written by the Templar Wallet setup wizard.';
  Lines[1] := '# Read once, on the first run of a fresh install, to place the';
  Lines[2] := '# wallet data folder. After that the app records the location in';
  Lines[3] := '# its own config, so editing this file will not move existing wallets.';
  Lines[4] := 'version={#MyAppVersion}';
  Lines[5] := 'data_dir=' + PortableDataDir(DataDirPage.Values[0]);
  // Not fatal: without the file the app falls back to its own default
  // location, which is what every build before this one did.
  if not SaveStringsToFile(ExpandConstant('{app}\install.conf'), Lines, False) then
    MsgBox('Setup could not record your wallet data folder.'#13#10#13#10 +
           'Templar Wallet will use its default location instead: ' +
           DefaultDataDir + #13#10#13#10 +
           'Settings > Vault & backup shows the folder actually in use.',
           mbInformation, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WriteInstallConf;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // The default finish page says nothing about the two things a first-time
  // user needs to know next, and the folder they chose is worth repeating
  // where they will still see it.
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption :=
      'Setup has finished installing Templar Wallet on your computer.'#13#10#13#10 +
      'On first run you will set an app password (it encrypts wallet storage on this computer) and write down a recovery phrase.'#13#10#13#10 +
      'Wallet data folder:'#13#10 +
      DataDirPage.Values[0] + #13#10 +
      'It is left in place if you uninstall.';
end;
