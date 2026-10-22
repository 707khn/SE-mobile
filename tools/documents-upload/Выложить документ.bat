@echo off
rem Drag a document (PDF, Word, Excel, scan) onto this file, or double-click it.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload_document.ps1" "%~1"
if errorlevel 1 (
  echo.
  echo ---------------------------------------------
  echo Zagruzka ne udalas. Podrobnosti vyshe i v faile
  echo    upload_log.txt
  echo ---------------------------------------------
  pause
)
