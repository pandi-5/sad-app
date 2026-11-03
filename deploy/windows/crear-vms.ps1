<#
.SYNOPSIS
  Crea las cuatro máquinas virtuales del laboratorio en VirtualBox con Ubuntu Server.

.DESCRIPTION
  Instala Ubuntu Server de forma desatendida en servidor-a, servidor-b, cliente-1 y cliente-2.
  Cada máquina tiene dos tarjetas de red.
    1. NAT, para tener internet y para entrar por SSH desde Windows mediante un puerto local.
    2. Solo anfitrión, para que las máquinas se vean entre sí con IP fijas que fija setup.sh.
  Puertos SSH desde Windows  servidor-a 2201, servidor-b 2202, cliente-1 2203, cliente-2 2204.

.EXAMPLE
  .\crear-vms.ps1
  .\crear-vms.ps1 -Iso "C:\Users\yo\Downloads\ubuntu-24.04-live-server-amd64.iso" -Rebuild
#>
param(
  [string]$Iso = "",
  [string]$VmDir = "$HOME\VirtualBox VMs",
  [string]$User = "lab",
  [string]$Password = "lab",
  [switch]$Rebuild,
  [int]$EsperaMinutos = 45
)
$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "..\..\logs"; New-Item -ItemType Directory -Force $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir ("crear-vms-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

$vbm = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $vbm)) { $vbm = (Get-Command VBoxManage -ErrorAction Stop).Source }
function Vbm { & $vbm @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage falló: $($args -join ' ')" } }
function VbmTry { & $vbm @args 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }

if (-not $Iso) {
  $found = Get-ChildItem "$HOME\Downloads" -Filter "*ubuntu*server*.iso" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $found) { throw "No encuentro la ISO de Ubuntu Server en Descargas. Usa -Iso ruta." }
  $Iso = $found.FullName
}
Write-Host "ISO: $Iso"
Write-Host "VirtualBox: $(& $vbm --version)"

# Red solo anfitrión
$hostonly = (& $vbm list hostonlyifs | Select-String "^Name:\s+(.+)$" | Select-Object -First 1).Matches.Groups[1].Value
if (-not $hostonly) { Vbm hostonlyif create | Out-Null; $hostonly = (& $vbm list hostonlyifs | Select-String "^Name:\s+(.+)$" | Select-Object -First 1).Matches.Groups[1].Value }
Write-Host "Adaptador solo anfitrión: $hostonly"

$nodes = @(
  @{ Name = "sad-servidor-a"; Host = "servidor-a"; Ram = 2048; Cpu = 2; DiskMb = 20480; Port = 2201 },
  @{ Name = "sad-servidor-b"; Host = "servidor-b"; Ram = 2048; Cpu = 2; DiskMb = 20480; Port = 2202 },
  @{ Name = "sad-cliente-1";  Host = "cliente-1";  Ram = 1024; Cpu = 1; DiskMb = 10240; Port = 2203 },
  @{ Name = "sad-cliente-2";  Host = "cliente-2";  Ram = 1024; Cpu = 1; DiskMb = 10240; Port = 2204 }
)

foreach ($n in $nodes) {
  $existing = (& $vbm list vms | Select-String ('"' + $n.Name + '"'))
  if ($existing) {
    if (-not $Rebuild) { Write-Host "La VM $($n.Name) ya existe, se conserva. Usa -Rebuild para rehacerla."; continue }
    VbmTry controlvm $n.Name poweroff | Out-Null; Start-Sleep 3
    Vbm unregistervm $n.Name --delete | Out-Null
  }
  Write-Host "`n== Creando $($n.Name) ($($n.Ram) MB, $($n.Cpu) CPU, $([int]($n.DiskMb/1024)) GB) =="
  Vbm createvm --name $n.Name --ostype Ubuntu_64 --basefolder $VmDir --register | Out-Null
  Vbm modifyvm $n.Name --memory $n.Ram --cpus $n.Cpu --vram 16 --graphicscontroller vmsvga --audio-driver none --boot1 dvd --boot2 disk --nic1 nat
  if (-not (VbmTry modifyvm $n.Name --nic2 hostonly --hostonlyadapter2 $hostonly)) {
    Vbm modifyvm $n.Name --nic2 hostonly --host-only-adapter2 $hostonly
  }
  Vbm modifyvm $n.Name --natpf1 "ssh,tcp,127.0.0.1,$($n.Port),,22"
  $disk = Join-Path $VmDir "$($n.Name)\$($n.Name).vdi"
  Vbm createmedium disk --filename $disk --size $n.DiskMb --format VDI | Out-Null
  Vbm storagectl $n.Name --name SATA --add sata --controller IntelAhci
  Vbm storageattach $n.Name --storagectl SATA --port 0 --device 0 --type hdd --medium $disk
  Vbm unattended install $n.Name --iso="$Iso" --user=$User --password=$Password --full-user-name="Laboratorio" `
      --hostname="$($n.Host).lab" --time-zone=America/Bogota --locale=es_CO --country=CO --start-vm=headless
  Write-Host "Instalación desatendida de $($n.Name) iniciada."
}

# Espera a que cada máquina acepte SSH por su puerto local.
$deadline = (Get-Date).AddMinutes($EsperaMinutos)
foreach ($n in $nodes) {
  Write-Host "Esperando SSH de $($n.Host) en 127.0.0.1:$($n.Port)..."
  while ($true) {
    $ok = $false
    try {
      $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect("127.0.0.1", $n.Port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) {
        $s = $c.GetStream(); $s.ReadTimeout = 3000; $buf = New-Object byte[] 64
        $len = $s.Read($buf, 0, 64); $ok = ([Text.Encoding]::ASCII.GetString($buf, 0, $len) -like "SSH-*")
      }
      $c.Close()
    } catch { }
    if ($ok) { Write-Host "  $($n.Host) responde por SSH."; break }
    if ((Get-Date) -gt $deadline) { throw "Se agotó la espera de $($n.Host). Revisa la ventana de la VM en VirtualBox." }
    Start-Sleep 15
  }
}
Write-Host "`nLas cuatro máquinas están listas. Usuario $User, contraseña $Password."
Stop-Transcript | Out-Null
