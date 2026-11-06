@echo off
rem Recrea solo las VM servidor-c y servidor-d.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Solo servidor-c,servidor-d
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Solo servidor-c,servidor-d
)
