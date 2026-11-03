@echo off
rem Despliega solo servidor-a y servidor-b, sin capturas.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1" -Solo servidor-a,servidor-b -SinCapturas -Pasadas 1
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0desplegar.ps1" -Solo servidor-a,servidor-b -SinCapturas -Pasadas 1
)
