@echo off
setlocal
title PCL 2.99.0 Unlock Patch
cd /d "%~dp0"

set "TARGET=%~1"

if not "%TARGET%"=="" goto :run
if exist "%~dp0Plain Craft Launcher 2.exe" set "TARGET=%~dp0Plain Craft Launcher 2.exe"
if not "%TARGET%"=="" goto :run
if exist "%~dp0..\Plain Craft Launcher 2.exe" set "TARGET=%~dp0..\Plain Craft Launcher 2.exe"

:run
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0unlock.ps1" "%TARGET%"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo  ^>^> Finished. Press any key to exit.
) else (
  echo  ^>^> Stopped with errors ^(code %RC%^). Read the messages above.
)
pause >nul
endlocal
