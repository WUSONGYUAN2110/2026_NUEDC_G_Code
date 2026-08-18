@echo off
setlocal

rem Remove generated workspaces; published artifacts require explicit opt-in.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0clean-generated.ps1" %*
exit /b %ERRORLEVEL%
