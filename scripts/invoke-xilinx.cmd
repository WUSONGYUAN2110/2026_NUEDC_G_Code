@echo off
setlocal

rem Run the PowerShell workflow without changing the machine or user execution policy.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-xilinx.ps1" %*
exit /b %ERRORLEVEL%
