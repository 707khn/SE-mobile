@echo off
rem Double-click to export today's menu. To get another day, pass a date:
rem   "Vygruzit menu.bat" 2026-08-20
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_menu.ps1" "%~1"
if errorlevel 1 (
  echo.
  echo ---------------------------------------------
  echo Vygruzka ne udalas. Podrobnosti vyshe i v faile
  echo    upload_log.txt
  echo ---------------------------------------------
  pause
)
