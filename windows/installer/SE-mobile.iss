; Установщик версии для компьютера.
;
; Ставит SE-mobile пользователю, без прав администратора: в
; %LOCALAPPDATA%\Programs\SE-mobile, с ярлыком в «Пуске» (и на рабочем столе —
; по галочке). Новая версия ставится тем же установщиком поверх: открытое
; приложение он закроет сам. Удаляется из «Приложения и возможности».
;
; Собирает workflow «Build Windows»; руками — из корня проекта, после
; flutter build windows --release:
;   iscc /DMyAppVersion=1.26.0+66 windows\installer\SE-mobile.iss

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
; Постоянный: по нему Windows узнаёт, что новая версия — это то же
; приложение, и ставит её поверх, а не рядом.
AppId={{8C6B2F7E-6C1D-4E8A-9B7A-5E3F2A1C9D40}
AppName=SE-mobile
AppVersion={#MyAppVersion}
AppPublisher=AO Semey Engineering
AppPublisherURL=https://se-btrz.com
; Кто ставил ещё под именем SemEng, обновится в прежнюю папку
; (Programs\SemEng): Inno Setup берёт папку прошлой установки по AppId.
DefaultDirName={localappdata}\Programs\SE-mobile
DefaultGroupName=SE-mobile
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\build\installer
OutputBaseFilename=SE-mobile-setup-{#MyAppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SE-mobile.exe
UninstallDisplayName=SE-mobile
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
; Папка сборки целиком: SE-mobile.exe без соседних библиотек и data\ не
; запустится.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Раньше приложение называлось SemEng. Без этого после обновления рядом
; остался бы старый SemEng.exe, а ярлыки вели бы на него — то есть на
; прежнюю версию.
Type: files; Name: "{app}\SemEng.exe"
Type: files; Name: "{autoprograms}\SemEng.lnk"
Type: files; Name: "{autodesktop}\SemEng.lnk"

[Icons]
Name: "{autoprograms}\SE-mobile"; Filename: "{app}\SE-mobile.exe"
Name: "{autodesktop}\SE-mobile"; Filename: "{app}\SE-mobile.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SE-mobile.exe"; Description: "{cm:LaunchProgram,SE-mobile}"; Flags: nowait postinstall skipifsilent
