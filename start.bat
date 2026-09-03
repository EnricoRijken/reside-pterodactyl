@rem Starts the packaged ReSide core services and opens the admin panel on Windows.
@echo off
setlocal

start "" /b /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 (
    echo.
    echo ReSide could not start. Read the message above for the next step.
    pause
    exit /b 1
)

echo.
echo ReSide server management is ready in the admin panel.
echo Double-click stop.bat when you are finished hosting.
pause
