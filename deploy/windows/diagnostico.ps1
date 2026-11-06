# Reúne información del equipo para preparar el despliegue. No modifica nada.
$ErrorActionPreference = "Continue"
$logDir = Join-Path $PSScriptRoot "..\..\logs"; New-Item -ItemType Directory -Force $logDir | Out-Null
$logDir = (Resolve-Path $logDir).Path
try { Start-Transcript -Path (Join-Path $logDir "diagnostico.log") -Force | Out-Null } catch { Write-Host "No se pudo iniciar el registro, se continúa sin él." }
$vbm = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
Write-Host "== Windows =="; [Environment]::OSVersion.VersionString; (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
Write-Host "== VirtualBox =="; if (Test-Path $vbm) { & $vbm --version; & $vbm list hostonlyifs; & $vbm list hostonlynets 2>&1; & $vbm list vms; & $vbm list ostypes | Select-String "Ubuntu_64" } else { "VBoxManage no encontrado" }
Write-Host "== ISO en Descargas =="; Get-ChildItem "$HOME\Downloads" -Filter "*.iso" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host "== Herramientas =="; foreach ($t in "ssh","scp","ssh-keygen","tar","wt","py","python","msedge","git") { $c = Get-Command $t -ErrorAction SilentlyContinue; "{0,-12} {1}" -f $t, $(if ($c) { $c.Source } else { "NO" }) }
Write-Host "== Plantillas de instalación desatendida =="
$tpl = "C:\Program Files\Oracle\VirtualBox\UnattendedTemplates"
Get-ChildItem $tpl -ErrorAction SilentlyContinue | Select-Object Name | Format-Table -AutoSize
$dest = Join-Path $logDir "plantillas"; New-Item -ItemType Directory -Force $dest | Out-Null
Get-ChildItem $tpl -Filter "*ubuntu*" -ErrorAction SilentlyContinue | Copy-Item -Destination $dest -Force
Write-Host "Listo. Los resultados están en $logDir"
try { Stop-Transcript | Out-Null } catch { }
