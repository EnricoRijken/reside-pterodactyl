@rem Stops packaged ReSide services and managed servers while preserving persistent data.
@echo off
setlocal

@rem stop.ps1 is the renamed package-root launcher; do not call the API copy directly.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
if errorlevel 1 (
    echo.
    echo ReSide services could not be stopped. Read the message above for the next step.
    pause
    exit /b 1
)

echo.
echo ReSide services stopped. Saved database and game-server data were preserved.
pause
