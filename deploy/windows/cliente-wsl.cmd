@echo off
rem Instala este computador como cliente del laboratorio dentro de WSL. Doble clic.
cd /d "%~dp0"
set /p N=Numero de este cliente (1, 2 o 3): 
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0cliente-wsl.ps1" -Numero %N%
