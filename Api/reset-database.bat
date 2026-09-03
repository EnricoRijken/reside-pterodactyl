@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset-database.ps1"
if errorlevel 1 (
    echo.
    echo Failed to reset the ReSide database.
    pause
    exit /b 1
)

echo.
echo ReSide database reset successfully.
pause
