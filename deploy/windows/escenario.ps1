<#
.SYNOPSIS
  Recorre el escenario completo del laboratorio y toma capturas reales de cada paso.

.DESCRIPTION
  Etapas, en orden  Normal, Web, Caida, Caida2, WebCaida, Failback.
  Normal    estado de los siete nodos, NFS, réplica y pruebas desde cliente-1.
  Caida     cae servidor-a, asume servidor-b.
  Caida2    cae también servidor-b, asume servidor-c. Muestra la sucesión.
  Failback  servidor-a recupera el servicio y los demás vuelven a réplica.
  Las etapas se leen de escenario-etapas.txt, una por línea. Si no existe se hacen todas.
  A los clientes WSL se llega desde servidor-a por Tailscale, ver Remoto en comun.ps1.
#>
. (Join-Path $PSScriptRoot "comun.ps1")
try { Start-Transcript -Path (Join-Path $script:LogDir ("escenario-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

$etapasFile = Join-Path $PSScriptRoot "escenario-etapas.txt"
$etapas = if (Test-Path $etapasFile) { Get-Content $etapasFile | Where-Object { $_ -match "\S" } | ForEach-Object { $_.Trim() } } else { @("Normal","Web","Caida","Caida2","WebCaida","Failback") }
Write-Host "Etapas a ejecutar: $($etapas -join ', ')" -ForegroundColor Cyan
$S = $script:Setup
$adminPass = (Remoto "servidor-a" "sudo cat /etc/sad-lab/credenciales.txt").Out | Select-String "clave=(\S+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1

# Las capturas de la web se toman con un navegador sin pantalla en servidor-d.
function CapturasWeb([string]$base, [string]$prefijo) {
  Write-Host "`n== Capturas de la web hacia $base ==" -ForegroundColor Cyan
  $r = Remoto "servidor-d" "test -x ~/pw/bin/python || { python3 -m venv ~/pw && ~/pw/bin/pip install -q playwright && sudo ~/pw/bin/playwright install --with-deps chromium; } 2>&1 | tail -3; echo listo-playwright"
  $r.Out | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe "servidor-d") (Join-Path $script:Repo "deploy\capturas_web.py") "$($script:User)@127.0.0.1:/tmp/capturas_web.py" 2>&1 | Out-Null
  $r = Remoto "servidor-d" "rm -rf ~/capturas-web && ~/pw/bin/python /tmp/capturas_web.py $base ~/capturas-web $prefijo $adminPass 2>&1 | tail -15" -Log "capturas-web-$prefijo.log"
  $r.Out | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe "servidor-d") "$($script:User)@127.0.0.1:~/capturas-web/*.png" $script:CapDir 2>&1 | Out-Null
}

function EsperarPrimario([string]$nodo, [int]$segundos = 60) {
  Write-Host "Esperando a que $nodo asuma como primario..." -ForegroundColor Cyan
  $null = Remoto $nodo "for i in `$(seq 1 $segundos); do test -f /var/lib/sad-lab/primary && break; sleep 1; done"
}

function EsperarEscritura([string]$cliente) {
  Write-Host "Esperando a que $cliente vuelva a montar con escritura..." -ForegroundColor Cyan
  $null = Remoto $cliente "for i in `$(seq 1 40); do touch /mnt/compartido/.espera 2>/dev/null && rm -f /mnt/compartido/.espera && break; sleep 3; done"
}

if ($etapas -contains "Normal") {
  Evidencia "tailscale-servidor-a" "servidor-a" "tailscale status; echo; sed -n '/sad-lab begin/,/sad-lab end/p' /etc/hosts"
  Evidencia "tailscale-cliente-1"  "cliente-1"  "tailscale ip -4; uname -r; grep -i microsoft /proc/sys/kernel/osrelease && echo 'cliente en WSL'"
  Evidencia "diagnostico-cliente-1" "cliente-1" "$S doctor"
  Evidencia "etcd-cliente-1" "cliente-1" "ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 endpoint status --cluster -w table; echo; python3 /opt/sad-app/cluster/elector.py status"
  Evidencia "montajes-cliente-1" "cliente-1" "mount | grep -E 'compartido|lectura'; cat /run/sad-escritura /run/sad-lectura"
  Evidencia "nfs-exportacion-servidor-a" "servidor-a" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "nfs-exportacion-servidor-b" "servidor-b" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "nfs-montaje-cliente-1" "cliente-1" "mount | grep compartido; df -h /mnt/compartido; ls -la /mnt/compartido"
  Evidencia "servicios-servidor-a" "servidor-a" "for s in nfs-server sad-app sad-replicator sad-elector sad-agent; do printf '%-16s %s\n' `$s `$(systemctl is-active `$s); done; echo; journalctl -u sad-replicator -n 8 --no-pager"
  Evidencia "replica-servidor-c" "servidor-c" "ls -la /srv/compartido/.cluster; cat /srv/compartido/.cluster/heartbeat; echo; journalctl -u sad-elector -n 4 --no-pager"
  Evidencia "estado-del-cluster" "cliente-1" "$S status"
  Evidencia "pruebas-punta-a-punta" "cliente-1" "$S test" 44
}
if ($etapas -contains "Web") { CapturasWeb "http://servidor-a:5000" "web-a" }
if ($etapas -contains "Caida") {
  Evidencia "caida-simulada-servidor-a" "servidor-a" "$S simulate-failure"
  EsperarPrimario "servidor-b"
  Evidencia "caida-elector-servidor-b" "servidor-b" "sudo grep elector /var/log/sad-lab.log | tail -n 10; echo; grep -E '^/srv' /etc/exports; systemctl is-active sad-app"
  Evidencia "caida-elector-servidor-c" "servidor-c" "sudo grep elector /var/log/sad-lab.log | tail -n 6"
  EsperarEscritura "cliente-1"
  Evidencia "caida-estado-del-cluster" "cliente-1" "$S status"
  Evidencia "caida-montaje-cliente" "cliente-1" "sudo tail -n 4 /var/log/sad-lab.log; mount | grep compartido; touch /mnt/compartido/escrito-tras-la-caida.txt && echo 'escritura correcta tras la caida'"
}
if ($etapas -contains "Caida2") {
  Evidencia "caida2-simulada-servidor-b" "servidor-b" "$S simulate-failure"
  EsperarPrimario "servidor-c"
  Evidencia "caida2-elector-servidor-c" "servidor-c" "sudo grep elector /var/log/sad-lab.log | tail -n 10; echo; grep -E '^/srv' /etc/exports"
  EsperarEscritura "cliente-1"
  Evidencia "caida2-estado-del-cluster" "cliente-1" "$S status"
}
if ($etapas -contains "WebCaida") { CapturasWeb "http://servidor-c:5000" "web-c-tras-caidas" }
if ($etapas -contains "Failback") {
  Evidencia "failback-servidor-a" "servidor-a" "$S failback" 40
  $null = Remoto "servidor-b" "sudo systemctl start nfs-server sad-agent sad-replicator sad-elector"
  Start-Sleep -Seconds 12
  Evidencia "failback-estado-del-cluster" "cliente-1" "$S status"
}
Write-Host "`nEscenario terminado. Capturas en $($script:CapDir)" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
