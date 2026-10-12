@echo off
setlocal

if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0AndroidBuildInstall-Session.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0AndroidBuildInstall-Session.ps1" ^
        -Project "%~1"
)

set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo Android build/install session finished.
) else (
    echo Android build/install session finished after an error.
    echo Detailed reports are available from the Reports button.
)

echo.
pause
exit /b %EXIT_CODE%
