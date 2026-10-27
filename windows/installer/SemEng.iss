; Установщик версии для компьютера.
;
; Ставит SemEng пользователю, без прав администратора: в
; %LOCALAPPDATA%\Programs\SemEng, с ярлыком в «Пуске» (и на рабочем столе —
; по галочке). Новая версия ставится тем же установщиком поверх: открытое
; приложение он закроет сам. Удаляется из «Приложения и возможности».
;
; Собирает workflow «Build Windows»; руками — из корня проекта, после
; flutter build windows --release:
;   iscc /DMyAppVersion=1.26.0+66 windows\installer\SemEng.iss

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
; Постоянный: по нему Windows узнаёт, что новая версия — это то же
; приложение, и ставит её поверх, а не рядом.
AppId={{8C6B2F7E-6C1D-4E8A-9B7A-5E3F2A1C9D40}
AppName=SemEng
AppVersion={#MyAppVersion}
AppPublisher=AO Semey Engineering
AppPublisherURL=https://se-btrz.com
DefaultDirName={localappdata}\Programs\SemEng
DefaultGroupName=SemEng
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\build\installer
OutputBaseFilename=SemEng-setup-{#MyAppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SemEng.exe
UninstallDisplayName=SemEng
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
WizardStyle=modern

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Папка сборки целиком: SemEng.exe без соседних библиотек и data\ не
; запустится.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SemEng"; Filename: "{app}\SemEng.exe"
Name: "{autodesktop}\SemEng"; Filename: "{app}\SemEng.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SemEng.exe"; Description: "{cm:LaunchProgram,SemEng}"; Flags: nowait postinstall skipifsilent
