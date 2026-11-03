<#
.SYNOPSIS
  Copia el proyecto a las cuatro máquinas virtuales y ejecuta setup.sh en cada una.

.DESCRIPTION
  Orden  servidor-a, servidor-b, cliente-1, cliente-2, y una segunda pasada completa.
  La segunda pasada demuestra que setup.sh es idempotente y cierra las llaves SSH que
  faltaban en la primera. Al final ejecuta status y las pruebas de punta a punta.
#>
param(
  [string]$User = "lab",
  [string]$Password = "lab",
  [switch]$SoloPruebas
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logDir = Join-Path $repo "logs"; New-Item -ItemType Directory -Force $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir ("desplegar-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

$nodes = @(
  @{ Host = "servidor-a"; Port = 2201; Args = "servidor-a" },
  @{ Host = "servidor-b"; Port = 2202; Args = "servidor-b" },
  @{ Host = "cliente-1";  Port = 2203; Args = "cliente 1" },
  @{ Host = "cliente-2";  Port = 2204; Args = "cliente 2" }
)
$ssh = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "LogLevel=ERROR")

function Remote($port, $cmd) {
  & ssh @ssh -p $port "$User@127.0.0.1" $cmd
  if ($LASTEXITCODE -ne 0) { throw "El comando remoto falló en el puerto ${port}: $cmd" }
}

# Si no hay claves, usamos sshpass del lado de Windows no existe, así que se pide la contraseña una vez
# por máquina o se instala la llave pública del usuario. Aquí se copia la llave de Windows a cada VM.
$pub = Join-Path $HOME ".ssh\id_ed25519.pub"
if (-not (Test-Path $pub)) { & ssh-keygen -q -t ed25519 -N '""' -f (Join-Path $HOME ".ssh\id_ed25519") }

if (-not $SoloPruebas) {
  $tar = Join-Path $env:TEMP "sad-lab.tar.gz"
  Push-Location $repo
  & tar -czf $tar --exclude=.git --exclude=.venv --exclude=logs --exclude=__pycache__ --exclude=.env --exclude=data/*.db* .
  Pop-Location
  foreach ($n in $nodes) {
    Write-Host "`n== Preparando $($n.Host) =="
    $keyLine = (Get-Content $pub -Raw).Trim()
    Remote $n.Port "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$keyLine' ~/.ssh/authorized_keys 2>/dev/null || echo '$keyLine' >> ~/.ssh/authorized_keys"
    & scp @ssh -P $n.Port $tar "$User@127.0.0.1:/tmp/sad-lab.tar.gz"
    Remote $n.Port "mkdir -p ~/sad-app && tar -xzf /tmp/sad-lab.tar.gz -C ~/sad-app && chmod +x ~/sad-app/setup.sh"
    Remote $n.Port "echo '$Password' | sudo -S -p '' sh -c 'echo ""$User ALL=(ALL) NOPASSWD:ALL"" > /etc/sudoers.d/90-sad-lab && chmod 440 /etc/sudoers.d/90-sad-lab'"
    Remote $n.Port "sudo mkdir -p /etc/sad-lab && [ -f /etc/sad-lab/lab.conf ] || sudo cp ~/sad-app/deploy/lab.conf.example /etc/sad-lab/lab.conf"
    Remote $n.Port "sudo sed -i 's/^SSH_PASSWORD=.*/SSH_PASSWORD=\`"$Password\`"/' /etc/sad-lab/lab.conf"
  }

  foreach ($pass in 1..2) {
    Write-Host "`n########## Pasada $pass de 2 ##########"
    foreach ($n in $nodes) {
      Write-Host "`n>>>>>>>> $($n.Host): setup.sh $($n.Args)"
      Remote $n.Port "cd ~/sad-app && sudo ./setup.sh $($n.Args)"
    }
  }
}

Write-Host "`n########## Estado ##########"
Remote 2203 "cd ~/sad-app && sudo ./setup.sh status"
Write-Host "`n########## Pruebas de punta a punta ##########"
Remote 2203 "cd ~/sad-app && sudo ./setup.sh test"
Stop-Transcript | Out-Null
