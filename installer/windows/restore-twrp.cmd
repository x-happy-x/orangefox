@echo off
setlocal
title Restore TWRP - Xiaomi 17 Pro Max (popsicle)
echo Restore the bundled working TWRP on the CURRENT recovery slot of Xiaomi 17 Pro Max (popsicle).
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-recovery.ps1" -Mode RestoreTwrp %*
set "INSTALL_EXIT=%ERRORLEVEL%"
echo.
if not "%INSTALL_EXIT%"=="0" echo Restore FAILED. Read the error above and keep the device connected.
pause
exit /b %INSTALL_EXIT%
