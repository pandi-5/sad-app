<#
.SYNOPSIS
  Crea las cuatro máquinas virtuales del laboratorio en VirtualBox con Ubuntu Server.

.DESCRIPTION
  Instala Ubuntu Server de forma desatendida en servidor-a, servidor-b, cliente-1 y cliente-2.
  Cada máquina tiene dos tarjetas de red.
    1. NAT, para tener internet y para entrar por SSH desde Windows mediante un puerto local.
    2. Solo anfitrión, para que las máquinas se vean entre sí con IP fijas que fija setup.sh.
  Puertos locales  SSH 2201 a 2204 y web 8001 y 8002 para servidor-a y servidor-b.
  La llave pública SSH de Windows se instala durante la instalación, así que no hay contraseñas.
#>
param(
  [string]$Iso = "",
  [string]$VmDir = "$HOME\VirtualBox VMs",
  [string]$User = "lab",
  [string]$Password = "lab",
  [switch]$Rebuild,
  [string[]]$Solo = @(),
  [int]$EsperaMinutos = 60
)
$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "..\..\logs"; New-Item -ItemType Directory -Force $logDir | Out-Null
$logDir = (Resolve-Path $logDir).Path
try { Start-Transcript -Path (Join-Path $logDir ("crear-vms-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }

$vbmDir = "C:\Program Files\Oracle\VirtualBox"
$vbm = Join-Path $vbmDir "VBoxManage.exe"
if (-not (Test-Path $vbm)) { $vbm = (Get-Command VBoxManage -ErrorAction Stop).Source; $vbmDir = Split-Path $vbm }
function Vbm {
  # VBoxManage escribe el progreso en stderr, por eso se baja ErrorActionPreference mientras corre.
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $out = & $vbm @args 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE; $ErrorActionPreference = $prev
  if ($code -ne 0) { Write-Host ($out -join "`n"); throw "VBoxManage falló con código ${code}: $($args -join ' ')" }
  return $out
}
function VbmTry {
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $null = & $vbm @args 2>&1; $code = $LASTEXITCODE; $ErrorActionPreference = $prev
  return ($code -eq 0)
}

if (-not $Iso) {
  $found = Get-ChildItem "$HOME\Downloads" -Filter "*ubuntu*server*.iso" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $found) { throw "No encuentro la ISO de Ubuntu Server en Descargas. Usa -Iso ruta." }
  $Iso = $found.FullName
}
Write-Host "ISO: $Iso"
Write-Host "VirtualBox: $(& $vbm --version)"

# Llave SSH de Windows, se instala en las máquinas durante la instalación.
$keyFile = Join-Path $HOME ".ssh\id_ed25519"
if (-not (Test-Path "$keyFile.pub")) {
  New-Item -ItemType Directory -Force (Join-Path $HOME ".ssh") | Out-Null
  & ssh-keygen -q -t ed25519 -N '""' -f $keyFile
}
$pubKey = (Get-Content "$keyFile.pub" -Raw).Trim()

# Plantilla de autoinstall de VirtualBox con SSH y sudo sin contraseña añadidos.
$tpl = Get-Content (Join-Path $vbmDir "UnattendedTemplates\ubuntu_autoinstall_user_data") -Raw
$sshBlock = @"
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - $pubKey

  user-data:
"@
$tpl = $tpl -replace "(?m)^  user-data:\s*`r?`n", ($sshBlock + "`n")
$late = "    - curtin in-target --target=/target -- sh -c 'echo `"$User ALL=(ALL) NOPASSWD:ALL`" > /etc/sudoers.d/90-sad-lab && chmod 440 /etc/sudoers.d/90-sad-lab'`n    - cp /cdrom/vboxpostinstall.sh /target/root/vboxpostinstall.sh"
$tpl = $tpl -replace "(?m)^    - cp /cdrom/vboxpostinstall.sh /target/root/vboxpostinstall.sh", $late
$tplPath = Join-Path $logDir "autoinstall-user-data.generado"
[IO.File]::WriteAllText($tplPath, ($tpl -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Plantilla generada en $tplPath"

# Red solo anfitrión
$hostonly = (Vbm list hostonlyifs | Select-String "^Name:\s+(.+)$" | Select-Object -First 1).Matches.Groups[1].Value.Trim()
if (-not $hostonly) { $null = Vbm hostonlyif create; $hostonly = (Vbm list hostonlyifs | Select-String "^Name:\s+(.+)$" | Select-Object -First 1).Matches.Groups[1].Value.Trim() }
Write-Host "Adaptador solo anfitrión: $hostonly"

$nodes = @(
  @{ Name = "sad-servidor-a"; Host = "servidor-a"; Ram = 2048; Cpu = 2; DiskMb = 20480; Port = 2201; Web = 8001 },
  @{ Name = "sad-servidor-b"; Host = "servidor-b"; Ram = 2048; Cpu = 2; DiskMb = 20480; Port = 2202; Web = 8002 },
  @{ Name = "sad-cliente-1";  Host = "cliente-1";  Ram = 2048; Cpu = 1; DiskMb = 10240; Port = 2203; Web = 0 },
  @{ Name = "sad-cliente-2";  Host = "cliente-2";  Ram = 2048; Cpu = 1; DiskMb = 10240; Port = 2204; Web = 0 }
)

$Solo = @($Solo | ForEach-Object { $_ -split "," } | Where-Object { $_ })
if ($Solo.Count -gt 0) { $nodes = @($nodes | Where-Object { $Solo -contains $_.Host }); $Rebuild = $true }
foreach ($n in $nodes) {
  $exists = (Vbm list vms | Select-String ('"' + $n.Name + '"'))
  if ($exists) {
    if (-not $Rebuild) { Write-Host "La VM $($n.Name) ya existe, se conserva. Usa -Rebuild para rehacerla."; continue }
    $null = VbmTry controlvm $n.Name poweroff; Start-Sleep 3
    $null = Vbm unregistervm $n.Name --delete
  }
  # Restos de un intento anterior fallido de esta misma VM.
  $vmFolder = Join-Path $VmDir $n.Name
  if (Test-Path $vmFolder) {
    $null = VbmTry closemedium disk (Join-Path $vmFolder "$($n.Name).vdi") --delete
    Remove-Item -Recurse -Force $vmFolder -ErrorAction SilentlyContinue
  }
  try {
    Write-Host "`n== Creando $($n.Name), $($n.Ram) MB, $($n.Cpu) CPU, $([int]($n.DiskMb/1024)) GB =="
    $null = Vbm createvm --name $n.Name --ostype Ubuntu_64 --basefolder $VmDir --register
    $null = Vbm modifyvm $n.Name --memory $n.Ram --cpus $n.Cpu --vram 16 --graphicscontroller vmsvga --nic1 nat
    if (-not (VbmTry modifyvm $n.Name --nic2 hostonly --host-only-adapter2 $hostonly)) {
      $null = Vbm modifyvm $n.Name --nic2 hostonly --hostonlyadapter2 $hostonly
    }
    $null = Vbm modifyvm $n.Name --natpf1 "ssh,tcp,127.0.0.1,$($n.Port),,22"
    if ($n.Web -gt 0) { $null = Vbm modifyvm $n.Name --natpf1 "web,tcp,127.0.0.1,$($n.Web),,5000" }
    $disk = Join-Path $VmDir "$($n.Name)\$($n.Name).vdi"
    $null = Vbm createmedium disk --filename $disk --size $n.DiskMb --format VDI
    $null = Vbm storagectl $n.Name --name SATA --add sata --controller IntelAhci
    $null = Vbm storageattach $n.Name --storagectl SATA --port 0 --device 0 --type hdd --medium $disk
    $null = Vbm unattended install $n.Name --iso="$Iso" --user=$User --password=$Password --full-user-name="Laboratorio" `
        --hostname="$($n.Host).lab" --time-zone=America/Bogota --locale=es_CO --country=CO `
        --script-template="$tplPath" --start-vm=headless
    Write-Host "Instalación desatendida de $($n.Name) iniciada."
  } catch {
    Write-Host "Falló la creación de $($n.Name): $_"
    $null = VbmTry controlvm $n.Name poweroff
    $null = VbmTry unregistervm $n.Name --delete
    throw
  }
}

# Espera a que cada máquina acepte SSH con la llave de Windows.
$ErrorActionPreference = "Continue"
$ssh = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4")
$deadline = (Get-Date).AddMinutes($EsperaMinutos)
foreach ($n in $nodes) {
  Write-Host "Esperando SSH de $($n.Host) en 127.0.0.1:$($n.Port)..."
  while ($true) {
    $null = & ssh @ssh -p $n.Port "$User@127.0.0.1" "true" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "  $($n.Host) responde por SSH."; break }
    if ((Get-Date) -gt $deadline) { throw "Se agotó la espera de $($n.Host). Revisa la VM en VirtualBox." }
    Start-Sleep 20
  }
}
Write-Host "`nLas cuatro máquinas están listas. Usuario $User."
try { Stop-Transcript | Out-Null } catch { }
