@echo off
rem Перетащите на этот файл выгрузку меню из 1С — или просто запустите двойным
rem щелчком, тогда откроется окно выбора файла.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload_menu.ps1" "%~1"
