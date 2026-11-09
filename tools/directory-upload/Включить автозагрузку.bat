@echo off
rem Turns on automatic directory upload: a watcher starts now and at every
rem Windows logon, and offers to upload each new directory spreadsheet.
rem Comments are in English on purpose: cmd reads .bat in the OEM codepage
rem and Cyrillic here would come out garbled.
setlocal
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0autostart.ps1" -Enable
if errorlevel 1 pause
