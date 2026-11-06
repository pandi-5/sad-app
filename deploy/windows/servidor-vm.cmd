@echo off
rem Crea la VM de ESTE integrante e instala su servidor. Doble clic.
rem Cada integrante tiene una sola VM: a, b, c o d.
cd /d "%~dp0"
set /p L=Letra de tu servidor (a, b, c o d): 
set /p CREAR=Crear la VM nueva? Escribe s, o n si ya la tienes con SSH en el puerto local: 
if /i "%CREAR%"=="s" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0crear-vms.ps1" -Solo servidor-%L% || goto error
set SAD_PROPIO=servidor-%L%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0desplegar.ps1" -Solo servidor-%L% -Pasadas 1 -SinCapturas || goto error
echo.
echo servidor-%L% listo. Vuelve a ejecutar este script cuando todos los nodos esten unidos, para cerrar las llaves SSH.
pause
exit /b 0
:error
echo.
echo Algo fallo. Copia el mensaje de arriba y pasalo al grupo.
pause
exit /b 1
