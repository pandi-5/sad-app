<#
.SYNOPSIS
  Recorre el escenario completo del laboratorio y toma capturas reales de cada paso.

.DESCRIPTION
  Etapas, en orden  Normal, Web, Fotos, Etcd, Caida, Caida2, Fencing, WebCaida, Failback.
  Normal    red, etcd, NFS, réplica, montajes y pruebas desde cliente-1.
  Fotos     se borra un archivo por error y se recupera de una foto.
  Etcd      se apagan dos miembros de etcd y el sistema sigue con mayoría.
  Caida     cae servidor-a, asume servidor-b.
  Caida2    cae también servidor-b, asume servidor-c.
  Fencing   servidor-c pierde la red, se aísla en solo lectura y asume servidor-d.
  Failback  servidor-a recupera el servicio y los demás vuelven a réplica.
  Las etapas se leen de escenario-etapas.txt, una por línea. Si no existe se hacen todas.
  Con SAD_LOCAL=1 los siete nodos son VM de este equipo. Si no, a los demás se llega desde
  la VM propia por Tailscale, ver Remoto en comun.ps1.
#>
. (Join-Path $PSScriptRoot "comun.ps1")
try { Start-Transcript -Path (Join-Path $script:LogDir ("escenario-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

$todas = @("Normal","Web","Fotos","Etcd","Caida","Caida2","Fencing","WebCaida","Failback")
$etapasFile = Join-Path $PSScriptRoot "escenario-etapas.txt"
$etapas = if (Test-Path $etapasFile) { Get-Content $etapasFile | Where-Object { $_ -match "\S" } | ForEach-Object { $_.Trim() } } else { $todas }
Write-Host "Etapas a ejecutar: $($etapas -join ', ')" -ForegroundColor Cyan
$S = $script:Setup
$E = "python3 /opt/sad-app/cluster/elector.py"
$adminPass = (Remoto "servidor-a" "sudo cat /etc/sad-lab/credenciales.txt").Out | Select-String "clave=(\S+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1

function Titulo([string]$t) { Clear-Host; Write-Host "`n  $t`n" -ForegroundColor Yellow; Start-Sleep -Seconds 3 }
function Lider { ((Remoto "cliente-1" "$E leader").Out | Select-Object -First 1) -replace "`r","" }

# Las capturas de la web se toman con un navegador sin pantalla en la VM propia.
function CapturasWeb([string]$base, [string]$prefijo) {
  Write-Host "`n== Capturas de la web hacia $base ==" -ForegroundColor Cyan
  $r = Remoto $script:Propio "test -x ~/pw/bin/python || { python3 -m venv ~/pw && ~/pw/bin/pip install -q playwright && sudo ~/pw/bin/playwright install --with-deps chromium; } 2>&1 | tail -3; echo listo-playwright"
  $r.Out | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe $script:Propio) (Join-Path $script:Repo "deploy\capturas_web.py") "$($script:User)@127.0.0.1:/tmp/capturas_web.py" 2>&1 | Out-Null
  $r = Remoto $script:Propio "rm -rf ~/capturas-web && ~/pw/bin/python /tmp/capturas_web.py $base ~/capturas-web $prefijo $adminPass 2>&1 | tail -15" -Log "capturas-web-$prefijo.log"
  $r.Out | ForEach-Object { Write-Host $_ }
  & scp @($script:SshOpts) -P (PortDe $script:Propio) "$($script:User)@127.0.0.1:~/capturas-web/*.png" $script:CapDir 2>&1 | Out-Null
}

function EsperarPrimario([string]$nodo, [int]$segundos = 90) {
  Write-Host "Esperando a que $nodo asuma como primario..." -ForegroundColor Cyan
  $null = Remoto $nodo "for i in `$(seq 1 $segundos); do test -f /var/lib/sad-lab/primary && break; sleep 1; done"
}

function EsperarEscritura([string]$cliente) {
  Write-Host "Esperando a que $cliente vuelva a montar con escritura..." -ForegroundColor Cyan
  $null = Remoto $cliente "for i in `$(seq 1 40); do touch /mnt/compartido/.espera 2>/dev/null && rm -f /mnt/compartido/.espera && break; sleep 3; done"
}

if ($etapas -contains "Normal") {
  Titulo "1. La red: siete nodos unidos por Tailscale y etcd con Raft"
  Evidencia "tailscale-servidor-a" "servidor-a" "tailscale status; echo; sed -n '/sad-lab begin/,/sad-lab end/p' /etc/hosts"
  Evidencia "etcd-cliente-1" "cliente-1" "ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 endpoint status --cluster -w table; echo; $E status"
  Evidencia "diagnostico-cliente-1" "cliente-1" "$S doctor"
  Titulo "2. NFS: el primario exporta con escritura, las réplicas en solo lectura"
  Evidencia "nfs-exportacion-servidor-a" "servidor-a" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "nfs-exportacion-servidor-b" "servidor-b" "cat /etc/exports; echo; sudo exportfs -v"
  Evidencia "montajes-cliente-1" "cliente-1" "mount | grep -E 'compartido|lectura'; echo; echo escribe en: `$(cat /run/sad-escritura); echo lee de: `$(cat /run/sad-lectura)"
  Titulo "3. Carpeta compartida y réplica casi inmediata"
  Evidencia "escritura-cliente-1" "cliente-1" "echo 'hola desde cliente-1' > /mnt/compartido/saludo.txt; date +%T.%N; ls -l /mnt/compartido"
  Evidencia "lectura-cliente-2" "cliente-2" "cat /mnt/compartido/saludo.txt; cat /mnt/lectura/saludo.txt; date +%T.%N"
  Evidencia "replica-servidor-c" "servidor-c" "ls -l /srv/compartido; cat /srv/compartido/.cluster/heartbeat; echo; systemctl is-active sad-elector etcd"
  Evidencia "servicios-servidor-a" "servidor-a" "for s in nfs-server sad-app sad-replicator sad-elector sad-agent sad-snapshot.timer; do printf '%-20s %s\n' `$s `$(systemctl is-active `$s); done; echo; journalctl -u sad-elector -n 6 --no-pager"
  Evidencia "estado-del-cluster" "cliente-1" "$S status"
  Titulo "4. Pruebas de punta a punta: concurrencia con y sin flock, réplica y lectura"
  Evidencia "pruebas-punta-a-punta" "cliente-1" "$S test" 44
}
if ($etapas -contains "Web") { Titulo "5. La aplicación web"; CapturasWeb "http://servidor-a:5000" "web-a" }
if ($etapas -contains "Fotos") {
  Titulo "6. Error humano: se borra un archivo y se recupera de una foto"
  Evidencia "fotos-tomar-servidor-a" "servidor-a" "sudo systemctl start sad-snapshot.service; $S snapshots"
  Evidencia "fotos-borrado-cliente-2" "cliente-2" "rm -v /mnt/compartido/saludo.txt; sleep 2; ls /mnt/compartido /mnt/lectura"
  Evidencia "fotos-restaurar-servidor-a" "servidor-a" "f=`$(ls /var/lib/sad-lab/snapshots | grep -v tmp | tail -1); $S restore `$f saludo.txt"
  Evidencia "fotos-recuperado-cliente-3" "cliente-3" "sleep 2; cat /mnt/compartido/saludo.txt; cat /mnt/lectura/saludo.txt"
}
if ($etapas -contains "Etcd") {
  Titulo "7. Consenso: se apagan dos de los cinco miembros de etcd"
  $null = Remoto "cliente-2" "sudo systemctl stop etcd"
  $null = Remoto "cliente-3" "sudo systemctl stop etcd"
  Start-Sleep -Seconds 5
  Evidencia "etcd-dos-caidos-cliente-1" "cliente-1" "ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 endpoint health --cluster 2>&1 | sort; echo; $E status; echo; echo 'escritura con 3 de 5:' > /mnt/compartido/etcd.txt && cat /mnt/compartido/etcd.txt"
  $null = Remoto "cliente-2" "sudo systemctl start etcd"
  $null = Remoto "cliente-3" "sudo systemctl start etcd"
  Start-Sleep -Seconds 8
  Evidencia "etcd-recuperado-cliente-1" "cliente-1" "ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 endpoint health --cluster 2>&1 | sort; echo; $E status"
}
if ($etapas -contains "Caida") {
  Titulo "8. Cae el primario servidor-a"
  Evidencia "caida-simulada-servidor-a" "servidor-a" "$S simulate-failure"
  EsperarPrimario "servidor-b"
  Evidencia "caida-elector-servidor-b" "servidor-b" "journalctl -u sad-elector -n 10 --no-pager; echo; grep -E '^/srv' /etc/exports; systemctl is-active sad-app"
  Evidencia "caida-elector-servidor-c" "servidor-c" "journalctl -u sad-elector -n 6 --no-pager"
  EsperarEscritura "cliente-1"
  Evidencia "caida-estado-del-cluster" "cliente-1" "$S status"
  Evidencia "caida-montaje-cliente" "cliente-1" "sudo grep cliente /var/log/sad-lab.log | tail -n 4; mount | grep compartido; touch /mnt/compartido/escrito-tras-la-caida.txt && echo 'escritura correcta tras la caída'"
}
if ($etapas -contains "Caida2") {
  Titulo "9. Cae también servidor-b"
  Evidencia "caida2-simulada-servidor-b" "servidor-b" "$S simulate-failure"
  EsperarPrimario "servidor-c"
  Evidencia "caida2-elector-servidor-c" "servidor-c" "journalctl -u sad-elector -n 10 --no-pager; echo; grep -E '^/srv' /etc/exports"
  EsperarEscritura "cliente-1"
  Evidencia "caida2-estado-del-cluster" "cliente-1" "$S status"
}
if ($etapas -contains "Fencing") {
  Titulo "10. Fencing: el primario pierde la red y se aísla solo"
  $p = Lider
  if (-not $p) { $p = "servidor-c" }
  $null = Remoto $p "sudo systemctl stop tailscaled"
  Start-Sleep -Seconds 4
  Evidencia "fencing-aislado-$p" $p "journalctl -u sad-elector -n 6 --no-pager; echo; grep -E '^/srv' /etc/exports; test -f /var/lib/sad-lab/primary && echo 'sigue primario' || echo 'ya no es primario'"
  for ($i = 0; $i -lt 30; $i++) { $q = Lider; if ($q -and $q -ne $p) { break }; Start-Sleep -Seconds 2 }
  Start-Sleep -Seconds 5
  Evidencia "fencing-nuevo-primario" "cliente-1" "$E status; echo; $S status"
  $null = Remoto $p "sudo systemctl start tailscaled; sleep 3; sudo systemctl start sad-hosts.service 2>/dev/null; true"
  Start-Sleep -Seconds 8
  EsperarEscritura "cliente-1"
}
if ($etapas -contains "WebCaida") {
  $p = Lider
  if ($p) { Titulo "11. La web sigue funcionando en $p"; CapturasWeb "http://${p}:5000" "web-tras-caidas" }
}
if ($etapas -contains "Failback") {
  Titulo "12. Failback: servidor-a recupera el servicio"
  Evidencia "failback-servidor-a" "servidor-a" "$S failback" 40
  $null = Remoto "servidor-b" "sudo systemctl start nfs-server sad-agent sad-replicator sad-elector"
  Start-Sleep -Seconds 12
  Evidencia "failback-estado-del-cluster" "cliente-1" "$E status; echo; $S status"
  Evidencia "pruebas-finales" "cliente-1" "$S test" 44
}
Write-Host "`nEscenario terminado. Capturas en $($script:CapDir)" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
