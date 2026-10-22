@echo off
rem Drag the stock balance report from 1C onto this file, or just double-click it.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload_stock.ps1" "%~1"
if errorlevel 1 (
  echo.
  echo ---------------------------------------------
  echo Zagruzka ne udalas. Podrobnosti vyshe i v faile
  echo    upload_log.txt
  echo ---------------------------------------------
  pause
)
