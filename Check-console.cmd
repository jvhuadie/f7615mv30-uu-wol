@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Auto.ps1" -CheckOnly
echo.
pause
