<#
.SYNOPSIS
  Instala un cliente del laboratorio dentro de WSL en este computador.

.DESCRIPTION
  1. Deja WSL encendido aunque se cierren las ventanas. Antes WSL se apagaba solo, el
     testigo desaparecía de Tailscale y el vigilante no tenía mayoría para decidir.
  2. Copia el proyecto a WSL convirtiendo los finales de línea a LF.
  3. Ejecuta setup.sh cliente N como root dentro de WSL.
  Necesita deploy\lab.conf, el mismo que se usó en los servidores.

.EXAMPLE
  .\cliente-wsl.ps1 -Numero 2
  .\cliente-wsl.ps1 -Numero 3 -Distro Ubuntu-24.04
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet(1, 2, 3)][int]$Numero,
  [string]$Distro = "Ubuntu"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$conf = Join-Path $repo "deploy\lab.conf"
if (-not (Test-Path $conf)) { throw "Falta deploy\lab.conf. Cópialo del computador que desplegó los servidores." }

$lista = (wsl.exe -l -q) -replace "`0", "" | Where-Object { $_ -match "\S" } | ForEach-Object { $_.Trim() }
if ($lista -notcontains $Distro) { throw "No encuentro la distribución $Distro en WSL. Disponibles: $($lista -join ', '). Usa -Distro." }

# 1. WSL encendido
$wslconfig = Join-Path $HOME ".wslconfig"
$txt = if (Test-Path $wslconfig) { Get-Content $wslconfig -Raw } else { "" }
if ($txt -notmatch "(?m)^\s*vmIdleTimeout\s*=") {
  if ($txt -notmatch "(?m)^\[wsl2\]") { $txt = $txt.TrimEnd() + "`r`n[wsl2]`r`n" }
  $txt = $txt -replace "(?m)^\[wsl2\]\s*$", "[wsl2]`r`nvmIdleTimeout=-1"
  Set-Content -Path $wslconfig -Value $txt -Encoding ASCII
  Write-Host "Configuré vmIdleTimeout=-1 en $wslconfig" -ForegroundColor Cyan
}
Write-Host "Dejando $Distro encendido en segundo plano..."
Start-Process -WindowStyle Hidden -FilePath "wsl.exe" -ArgumentList "-d", $Distro, "-u", "root", "--exec", "sleep", "infinity"
# Que siga encendido después de reiniciar Windows.
$accion = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Distro -u root --exec sleep infinity"
$disparo = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask -TaskName "sad-lab WSL encendido" -Action $accion -Trigger $disparo -Force | Out-Null

# 2. Copiar el proyecto
$src = (wsl.exe -d $Distro -u root wslpath -a "$repo").Trim()
$copiar = "rm -rf /root/sad-app-src && mkdir -p /root/sad-app-src && cp -r '$src'/. /root/sad-app-src/ && " +
          "rm -rf /root/sad-app-src/.git /root/sad-app-src/.venv && " +
          "find /root/sad-app-src -type f \( -name '*.sh' -o -name '*.py' -o -name '*.conf*' -o -name '*.txt' \) -exec sed -i 's/\r$//' {} + && " +
          "chmod +x /root/sad-app-src/setup.sh && echo copiado"
wsl.exe -d $Distro -u root -- bash -c $copiar
if ($LASTEXITCODE -ne 0) { throw "No pude copiar el proyecto a WSL." }

# 3. setup.sh
Write-Host "`n>>>>>>>> cliente-$Numero en WSL: setup.sh cliente $Numero" -ForegroundColor Cyan
wsl.exe -d $Distro -u root -- bash -c "SUDO_USER= /root/sad-app-src/setup.sh cliente $Numero"
$code = $LASTEXITCODE
if ($code -ne 0) {
  Write-Host "`nsetup.sh terminó con código $code." -ForegroundColor Yellow
  Write-Host "Si dice que activó systemd o cambió el nombre, ejecuta  wsl --shutdown  y vuelve a correr este script."
} else {
  Write-Host "`ncliente-$Numero listo. Prueba con:  wsl -d $Distro -u root /opt/sad-app/setup.sh status" -ForegroundColor Green
}
