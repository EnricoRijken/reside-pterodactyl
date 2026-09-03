@echo off
setlocal

@rem Keep this wrapper paired with the runtime stop.ps1 staged beside it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
if errorlevel 1 (
    echo.
    echo Failed to stop ReSide services.
    pause
    exit /b 1
)

echo.
echo ReSide services stopped successfully.
pause
