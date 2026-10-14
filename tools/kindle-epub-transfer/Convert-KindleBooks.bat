@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-KindleTransfer.ps1" -Action convert
set "transfer_exit=%errorlevel%"
pause
exit /b %transfer_exit%
