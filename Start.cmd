@echo off
if exist "%~dp0UuWol.exe" (
    start "" "%~dp0UuWol.exe"
) else (
    start "" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Gui.ps1"
)
