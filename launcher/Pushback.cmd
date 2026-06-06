@echo off
REM Addon Pushback Manager double-click launcher.
REM Prefers PowerShell 7 (pwsh.exe) when available; falls back to Windows
REM PowerShell 5.1 (powershell.exe, preinstalled on Windows 10/11).
REM
REM -ExecutionPolicy Bypass is scoped to THIS invocation only and does
REM not change any user or machine setting.

setlocal
set "PWSH=pwsh.exe"
where %PWSH% >nul 2>nul
if errorlevel 1 set "PWSH=powershell.exe"

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Pushback.Gui.ps1" %*
exit /b %ERRORLEVEL%
