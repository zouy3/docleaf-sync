@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-and-start-docleaf.ps1"
set "DOCLEAF_EXIT=%ERRORLEVEL%"
if not "%DOCLEAF_EXIT%"=="0" pause
exit /b %DOCLEAF_EXIT%
