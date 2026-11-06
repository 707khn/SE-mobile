@echo off
rem Loads a menu file and puts it on TODAY, whatever date the file carries.
rem Drag the 1C export onto this file, or double-click and pick it.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0upload_menu.ps1" -FilePath "%~1" -Today
if errorlevel 1 (
  echo.
  echo ---------------------------------------------
  echo Zagruzka ne udalas. Podrobnosti vyshe i v faile
  echo    upload_log.txt
  echo ---------------------------------------------
  pause
)
