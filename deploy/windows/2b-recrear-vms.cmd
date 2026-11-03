@echo off
rem Borra las VM sad-* y las crea de nuevo. Usalo solo si quieres empezar de cero.
cd /d "%~dp0"
where wt >nul 2>nul
if %errorlevel%==0 (
  start "" wt -M powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Rebuild
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0crear-vms.ps1" -Rebuild
)
