@echo off
rem Lanza desplegar.ps1 en Windows Terminal maximizada. Basta con hacer doble clic.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1"
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1"
)
