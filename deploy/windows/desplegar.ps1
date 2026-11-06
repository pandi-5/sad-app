<#
.SYNOPSIS
  Copia el proyecto a las cuatro VM servidoras y ejecuta setup.sh en cada una.

.DESCRIPTION
  Orden  servidor-a, servidor-b, servidor-c, servidor-d, y una segunda pasada completa.
  Necesita deploy\lab.conf con TS_AUTHKEY y SSH_PASSWORD. Se crea copiando lab.conf.example.
  El mismo lab.conf se sube a todos los servidores, así todos usan los mismos valores.
  Los clientes WSL se instalan aparte con cliente-wsl.cmd. Cuando estén, vuelve a correr
  este script con -Pasadas 1 para que los servidores intercambien llaves con ellos.
#>
param([switch]$SinCapturas, [int]$Pasadas = 2, [string[]]$Solo = @())
. (Join-Path $PSScriptRoot "comun.ps1")
$Solo = @($Solo | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$sel = if ($Solo.Count -gt 0) { @($script:Nodos | Where-Object { $Solo -contains $_.Host }) } else { $script:Nodos }
try { Start-Transcript -Path (Join-Path $script:LogDir ("desplegar-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

$conf = Join-Path $script:Repo "deploy\lab.conf"
if (-not (Test-Path $conf)) {
  Copy-Item (Join-Path $script:Repo "deploy\lab.conf.example") $conf
  Write-Host "Creé deploy\lab.conf. Ábrelo, pon TS_AUTHKEY y SSH_PASSWORD y vuelve a ejecutar." -ForegroundColor Yellow
  notepad $conf
  exit 1
}
if (-not (Select-String -Path $conf -Pattern '^TS_AUTHKEY="?tskey-' -Quiet)) {
  Write-Host "Aviso: deploy\lab.conf no tiene TS_AUTHKEY. Cada VM pedirá autorizarse con un enlace." -ForegroundColor Yellow
}

# 1. Empaquetar y copiar el proyecto. Los finales de línea de Windows (CRLF) rompían
#    setup.sh y lab.conf, por eso se convierten a LF dentro de la VM.
$tar = Join-Path $env:TEMP "sad-lab.tar.gz"
Push-Location $script:Repo
& tar -czf $tar --exclude=.git --exclude=.venv --exclude=logs --exclude=capturas --exclude=__pycache__ --exclude=.env --exclude="data/*.db*" .
Pop-Location
foreach ($n in $sel) {
  Write-Host "`n== Preparando $($n.Host) =="
  & scp @($script:SshOpts) -P $n.Port $tar "$($script:User)@127.0.0.1:/tmp/sad-lab.tar.gz" 2>&1 | Out-Null
  $prep = "rm -rf ~/sad-app && mkdir -p ~/sad-app && tar -xzf /tmp/sad-lab.tar.gz -C ~/sad-app && " +
          "find ~/sad-app -type f \( -name '*.sh' -o -name '*.py' -o -name '*.conf*' -o -name '*.txt' \) -exec sed -i 's/\r$//' {} + && " +
          "chmod +x ~/sad-app/setup.sh && sudo mkdir -p /etc/sad-lab && sudo install -m 600 ~/sad-app/deploy/lab.conf /etc/sad-lab/lab.conf && echo listo"
  $r = Remoto $n.Host $prep
  if ($r.Code -ne 0) { $r.Out | Write-Host; throw "No pude preparar $($n.Host)" }
  Write-Host "  proyecto y lab.conf copiados a $($n.Host)"
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
Write-Host "Siguiente paso: en cada computador con WSL ejecuta deploy\windows\cliente-wsl.cmd"
try { Stop-Transcript | Out-Null } catch { }
