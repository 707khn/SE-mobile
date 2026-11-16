@echo off
rem Drag the turnstile report (.xls) onto this file, or just double-click it.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0upload_access.ps1" "%~1"
if errorlevel 1 (
  echo.
  echo ---------------------------------------------
  echo Zagruzka ne udalas. Podrobnosti vyshe i v faile
  echo    upload_log.txt
  echo ---------------------------------------------
  pause
)
