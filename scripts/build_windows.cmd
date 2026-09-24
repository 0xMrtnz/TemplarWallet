@echo off
rem Double-click to build Templar Wallet for Windows. Details: build_windows.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
echo.
pause
