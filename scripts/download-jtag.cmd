@echo off
setlocal

rem Temporary JTAG download. The PowerShell wrapper uses an execution-policy
rem bypass for this child process only and never writes QSPI Flash.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-jtag.ps1" %*
exit /b %ERRORLEVEL%
