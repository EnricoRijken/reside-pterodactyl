@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
if errorlevel 1 (
    echo.
    echo Failed to start ReSide services.
    pause
    exit /b 1
)

echo.
echo ReSide services started successfully.
pause
