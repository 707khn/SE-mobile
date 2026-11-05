@echo off
rem Turns automatic directory upload off: removes the logon shortcut and
rem stops the running watcher. Drag-and-drop upload keeps working.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autostart.ps1" -Disable
if errorlevel 1 pause
