<#
.SYNOPSIS
  Recorre el escenario completo del laboratorio y toma capturas reales de cada paso.

.DESCRIPTION
  Etapas, en orden  Normal, Web, Caida, WebCaida, Failback.
  Las etapas que se ejecutan se leen de escenario-etapas.txt, una por línea. Si no existe se hacen todas.
  Cada captura es una fotografía real de la pantalla con la salida del comando que se acaba de ejecutar.
#>
. (Join-Path $PSScriptRoot "comun.ps1")
try { Start-Transcript -Path (Join-Path $script:LogDir ("escenario-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

$etapasFile = Join-Path $PSScriptRoot "escenario-etapas.txt"
$etapas = if (Test-Path $etapasFile) { Get-Content $etapasFile | Where-Object { $_ -match "\S" } | ForEach-Object { $_.Trim() } } else { @("Normal","Web","Caida","WebCaida","Failback") }
Write-Host "Etapas a ejecutar: $($etapas -join ', ')" -ForegroundColor Cyan
$cmdSetup = "cd ~/sad-app && sudo ./setup.sh"
$adminPass = (Remoto "servidor-a" "sudo cat /etc/sad-lab/credenciales.txt").Out | Select-String "clave=(\S+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1

function CapturasWeb([string]$nodoWeb, [string]$base, [string]$prefijo) {
  Write-Host "`n== Capturas de la web desde cliente-1 hacia $base ==" -ForegroundColor Cyan
  $r = Remoto "cliente-1" "test -x ~/pw/bin/python || { python3 -m venv ~/pw && ~/pw/bin/pip install -q playwright && ~/pw/bin/playwright install --with-deps chromium; } 2>&1 | tail -3; echo listo-playwright"
  $r.Out | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe "cliente-1") (Join-Path $script:Repo "deploy\capturas_web.py") "$($script:User)@127.0.0.1:/tmp/capturas_web.py" 2>&1 | Out-Null
  $r = Remoto "cliente-1" "rm -rf ~/capturas-web && ~/pw/bin/python /tmp/capturas_web.py $base ~/capturas-web $prefijo $adminPass 2>&1 | tail -15" -Log "capturas-web-$prefijo.log"
  $r.Out | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe "cliente-1") "$($script:User)@127.0.0.1:~/capturas-web/*.png" $script:CapDir 2>&1 | Out-Null
}

if ($etapas -contains "Normal") {
  Evidencia "red-simulada-servidor-a" "servidor-a" "cat /etc/sad-lab/overlay-mode; ip -4 -br addr show; ip route | grep 100.64"
  Evidencia "red-simulada-cliente-1"  "cliente-1"  "cat /etc/sad-lab/overlay-mode; ip -4 -br addr show; ip route | grep 100.64"
  Evidencia "nfs-exportacion-servidor-a" "servidor-a" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "nfs-exportacion-servidor-b" "servidor-b" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "nfs-montaje-cliente-1" "cliente-1" "mount | grep compartido; df -h /mnt/compartido; ls -la /mnt/compartido"
  Evidencia "servicios-servidor-a" "servidor-a" "for s in nfs-server sad-app sad-replicator sad-agent; do printf '%-16s %s\n' `$s `$(systemctl is-active `$s); done; echo; journalctl -u sad-replicator -n 6 --no-pager"
  Evidencia "replica-servidor-b" "servidor-b" "ls -la /srv/compartido /srv/compartido/.cluster; cat /srv/compartido/.cluster/heartbeat; echo; systemctl is-active sad-watchdog"
  Evidencia "estado-del-cluster" "cliente-1" "$cmdSetup status"
  Evidencia "pruebas-punta-a-punta" "cliente-1" "$cmdSetup test" 40
}
if ($etapas -contains "Web") { CapturasWeb "servidor-a" "http://100.64.0.11:5000" "web-a" }
if ($etapas -contains "Caida") {
  Evidencia "caida-simulada-servidor-a" "servidor-a" "$cmdSetup simulate-failure"
  Write-Host "Esperando a que el vigilante de servidor-b decida..." -ForegroundColor Cyan
  Start-Sleep -Seconds 25
  Evidencia "caida-vigilante-servidor-b" "servidor-b" "sudo tail -n 14 /var/log/sad-lab.log; echo; grep -E '^(/srv|NODE_ROLE)' /etc/exports /home/lab/sad-app/.env; systemctl is-active sad-app"
  Write-Host "Esperando a que el cliente remonte la carpeta desde servidor-b..." -ForegroundColor Cyan
  $null = Remoto "cliente-1" "for i in `$(seq 1 40); do touch /mnt/compartido/.espera 2>/dev/null && rm -f /mnt/compartido/.espera && break; sleep 3; done"
  Evidencia "caida-estado-del-cluster" "cliente-1" "$cmdSetup status"
  Evidencia "caida-montaje-cliente" "cliente-1" "sudo tail -n 6 /var/log/sad-lab.log; mount | grep compartido; touch /mnt/compartido/escrito-tras-la-caida.txt && echo 'escritura correcta tras la caida'; ls /mnt/compartido"
}
if ($etapas -contains "WebCaida") { CapturasWeb "servidor-b" "http://100.64.0.12:5000" "web-b-tras-caida" }
if ($etapas -contains "Failback") {
  Evidencia "failback-servidor-a" "servidor-a" "$cmdSetup failback" 40
  Start-Sleep -Seconds 12
  Evidencia "failback-estado-del-cluster" "cliente-1" "$cmdSetup status"
}
Write-Host "`nEscenario terminado. Capturas en $($script:CapDir)" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
