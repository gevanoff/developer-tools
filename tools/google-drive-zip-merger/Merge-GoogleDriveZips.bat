@echo off
setlocal

rem Double-click to open the merger, or drag the folder of ZIP files onto this file.
if "%~1"=="" (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass ^
        -File "%~dp0Merge-GoogleDriveZips.ps1"
) else (
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass ^
        -File "%~dp0Merge-GoogleDriveZips.ps1" ^
        -Source "%~1"
)

set "EXIT_CODE=%ERRORLEVEL%"
rem The window shows the result. Keep this console open only if PowerShell itself failed.
if not "%EXIT_CODE%"=="0" if not "%EXIT_CODE%"=="1" pause
exit /b %EXIT_CODE%
