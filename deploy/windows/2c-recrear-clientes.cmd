@echo off
rem Recrea solo las VM cliente-1 y cliente-2.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Solo cliente-1,cliente-2
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Solo cliente-1,cliente-2
)
