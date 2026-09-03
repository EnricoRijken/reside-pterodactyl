@echo off
setlocal

set "SCRIPT_DIRECTORY=%~dp0"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo.
    echo [ERROR] Windows PowerShell could not be found. 1>&2
    echo         Run CollectLogs.sh from Bash instead, or contact ReSide support. 1>&2
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIRECTORY%CollectLogs.ps1"

if errorlevel 1 (
    echo.
    echo [ERROR] ReSide log collection failed. Review the message above. 1>&2
    pause
    exit /b 1
)

echo.
echo The ReSide log collector finished successfully.
pause
exit /b 0
