@echo off
chcp 65001 >nul
rem This script has been renamed to 一键部署.bat - forwarding...
setlocal
echo [INFO] This script has been renamed to "一键部署.bat". Running it now...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0v3_music_tool.ps1"
echo.
pause
endlocal
