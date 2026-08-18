@echo off
setlocal

rem Attach to an already configured FPGA, capture ILA data, and summarize it.
rem This command never programs the FPGA or writes QSPI Flash.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-ila.ps1" %*
exit /b %ERRORLEVEL%
