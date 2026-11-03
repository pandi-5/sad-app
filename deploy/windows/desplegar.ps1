<#
.SYNOPSIS
  Copia el proyecto a las cuatro máquinas virtuales y ejecuta setup.sh en cada una.

.DESCRIPTION
  Orden  servidor-a, servidor-b, cliente-1, cliente-2, y una segunda pasada completa.
  La segunda pasada demuestra que setup.sh es idempotente y cierra las llaves SSH que
  faltaban en la primera. Guarda un registro por nodo y capturas reales de la terminal.
#>
param([switch]$SinCapturas, [int]$Pasadas = 2, [string[]]$Solo = @())
. (Join-Path $PSScriptRoot "comun.ps1")
$Solo = @($Solo | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$sel = if ($Solo.Count -gt 0) { @($script:Nodos | Where-Object { $Solo -contains $_.Host }) } else { $script:Nodos }
try { Start-Transcript -Path (Join-Path $script:LogDir ("desplegar-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

# 1. Empaquetar y copiar el proyecto
$tar = Join-Path $env:TEMP "sad-lab.tar.gz"
Push-Location $script:Repo
& tar -czf $tar --exclude=.git --exclude=.venv --exclude=logs --exclude=capturas --exclude=__pycache__ --exclude=.env --exclude="data/*.db*" .
Pop-Location
foreach ($n in $sel) {
  Write-Host "`n== Preparando $($n.Host) =="
  & scp @($script:SshOpts) -P $n.Port $tar "$($script:User)@127.0.0.1:/tmp/sad-lab.tar.gz" 2>&1 | Out-Null
  $r = Remoto $n.Host "mkdir -p ~/sad-app && tar -xzf /tmp/sad-lab.tar.gz -C ~/sad-app && chmod +x ~/sad-app/setup.sh && sudo mkdir -p /etc/sad-lab && { [ -f /etc/sad-lab/lab.conf ] || sudo cp ~/sad-app/deploy/lab.conf.example /etc/sad-lab/lab.conf; } && sudo sed -i 's/^SSH_PASSWORD=.*/SSH_PASSWORD=lab/' /etc/sad-lab/lab.conf && echo listo"
  if ($r.Code -ne 0) { $r.Out | Write-Host; throw "No pude preparar $($n.Host)" }
  Write-Host "  proyecto copiado a $($n.Host)"
}

# 2. Ejecutar setup.sh en orden
$fallos = @()
foreach ($pasada in 1..$Pasadas) {
  Write-Host "`n########## Pasada $pasada de $Pasadas ##########"
  foreach ($n in $sel) {
    Write-Host "`n>>>>>>>> $($n.Host): sudo ./setup.sh $($n.Arg)" -ForegroundColor Cyan
    $log = "setup-$($n.Host)-pasada$pasada.log"
    $r = Remoto $n.Host "cd ~/sad-app && sudo ./setup.sh $($n.Arg)" -Tty -Log $log
    $r.Out | Select-Object -Last 22 | ForEach-Object { Write-Host ($_ -replace "`r","") }
    if ($r.Code -ne 0) { $fallos += "$($n.Host) pasada $pasada"; Write-Host "  !! terminó con código $($r.Code)" -ForegroundColor Red }
    if (-not $SinCapturas -and $pasada -eq 1) {
      EvidenciaLog "setup-$($n.Host)-1-inicio" "$($script:User)@$($n.Host):~`$ sudo ./setup.sh $($n.Arg)" $log inicio 38
      EvidenciaLog "setup-$($n.Host)-2-validacion" "$($script:User)@$($n.Host):~`$ sudo ./setup.sh $($n.Arg)   (final)" $log fin 38
    }
  }
}
Write-Host "`n########## Resumen ##########"
if ($fallos.Count -eq 0) { Write-Host "Todas las ejecuciones terminaron bien." -ForegroundColor Green }
else { Write-Host ("Fallaron: " + ($fallos -join ", ")) -ForegroundColor Red }
try { Stop-Transcript | Out-Null } catch { }
