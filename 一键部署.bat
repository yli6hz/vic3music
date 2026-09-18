@echo off
rem Victoria 3 custom music mod - one-click deploy (no Python needed)
setlocal
where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found. It is built into Windows 7+.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0v3_music_tool.ps1"
echo.
pause
endlocal
