@echo off
rem Vuelve a copiar el proyecto y ejecuta setup.sh una vez en los cuatro servidores, sin capturas.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1" -SinCapturas -Pasadas 1
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1" -SinCapturas -Pasadas 1
)
