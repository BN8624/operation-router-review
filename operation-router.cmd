@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\operation-router\scripts\run-operation.ps1" %*
