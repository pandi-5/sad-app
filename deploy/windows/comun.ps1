# Funciones compartidas por desplegar.ps1 y escenario.ps1. Se importa con  . .\comun.ps1
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$script:Repo   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:LogDir = if ($env:SAD_LOGDIR) { $env:SAD_LOGDIR } else { Join-Path $script:Repo "logs" }
$script:CapDir = if ($env:SAD_CAPDIR) { $env:SAD_CAPDIR } else { Join-Path $script:Repo "capturas" }
New-Item -ItemType Directory -Force $script:LogDir, $script:CapDir | Out-Null
$script:User   = "lab"
# Servidores, máquinas virtuales de este equipo. Se entra por SSH a un puerto local.
$script:Nodos  = @(
  @{ Host = "servidor-a"; Port = 2201; Arg = "servidor-a" },
  @{ Host = "servidor-b"; Port = 2202; Arg = "servidor-b" },
  @{ Host = "servidor-c"; Port = 2203; Arg = "servidor-c" },
  @{ Host = "servidor-d"; Port = 2204; Arg = "servidor-d" }
)
# Clientes, máquinas WSL de cada integrante.
$script:Clientes = @("cliente-1", "cliente-2", "cliente-3")
# SAD_LOCAL=1  los siete nodos son VM de este equipo. Los clientes van primero porque
# son miembros de etcd, y a todos se entra directo por su puerto local.
$script:Local = ($env:SAD_LOCAL -eq "1")
if ($script:Local) {
  $script:Nodos = @(
    @{ Host = "cliente-1"; Port = 2205; Arg = "cliente 1" },
    @{ Host = "cliente-2"; Port = 2206; Arg = "cliente 2" },
    @{ Host = "cliente-3"; Port = 2207; Arg = "cliente 3" }
  ) + $script:Nodos
}
# Servidor que corre en ESTE computador. Cada integrante tiene solo una VM, así que a
# los demás nodos se llega saltando desde ella por Tailscale como sadlab.
# Se cambia con la variable de entorno SAD_PROPIO, por ejemplo  set SAD_PROPIO=servidor-b
$script:Propio = if ($env:SAD_PROPIO) { $env:SAD_PROPIO } else { "servidor-a" }
$script:Setup = "sudo /opt/sad-app/setup.sh"
$script:SshOpts = @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-o","LogLevel=ERROR","-o","BatchMode=yes","-o","ConnectTimeout=8")
function PortDe($host_) { ($script:Nodos | Where-Object { $_.Host -eq $host_ }).Port }

# ---------- ejecución remota ----------
function Remoto([string]$nodo, [string]$cmd, [switch]$Tty, [string]$Log = "") {
  if (-not $script:Local -and $nodo -ne $script:Propio) {
    # El nodo está en otro computador. Se ejecuta desde la VM propia como sadlab por Tailscale.
    $q = $cmd -replace "'", "'\''"
    $cmd = "sudo -u sadlab ssh -tt -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new sadlab@$nodo '$q'"
    $nodo = $script:Propio
  }
  $port = PortDe $nodo
  $args_ = @() + $script:SshOpts
  if ($Tty) { $args_ += "-tt" }
  $out = & ssh @args_ -p $port "$($script:User)@127.0.0.1" $cmd 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  if ($Log) { $out | Set-Content -Encoding UTF8 -Path (Join-Path $script:LogDir $Log) }
  [pscustomobject]@{ Code = $code; Out = $out }
}

# ---------- capturas reales de pantalla ----------
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@ -ErrorAction SilentlyContinue
[void][Win]::SetProcessDPIAware()

function Captura([string]$nombre) {
  Start-Sleep -Milliseconds 700
  $h = [Win]::GetForegroundWindow(); $r = New-Object Win+RECT
  if ([Win]::GetWindowRect($h, [ref]$r) -and ($r.R - $r.L) -gt 300) {
    $x = [Math]::Max($r.L, 0); $y = [Math]::Max($r.T, 0); $w = $r.R - $r.L; $hh = $r.B - $r.T
  } else {
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $x = $b.X; $y = $b.Y; $w = $b.Width; $hh = $b.Height
  }
  $bmp = New-Object Drawing.Bitmap $w, $hh
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object Drawing.Size $w, $hh))
  $path = Join-Path $script:CapDir "$nombre.png"
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
  Write-Host "  [captura guardada: $nombre.png]" -ForegroundColor DarkGray
}

# Muestra un comando remoto como en una terminal real y fotografía la pantalla.
function Evidencia([string]$nombre, [string]$nodo, [string]$cmd, [int]$lineas = 36) {
  Clear-Host
  Write-Host "$($script:User)@$nodo`:~`$ $cmd" -ForegroundColor Green
  $r = Remoto $nodo $cmd -Tty
  $salida = @($r.Out)
  if ($salida.Count -gt $lineas) { $salida = $salida | Select-Object -Last $lineas }
  $salida | ForEach-Object { Write-Host ($_ -replace "`r","") }
  Captura $nombre
  Add-Content -Encoding UTF8 -Path (Join-Path $script:LogDir "evidencias.txt") -Value (@("", "===== $nombre  [$nodo]  $cmd", "codigo=$($r.Code)") + ($r.Out | ForEach-Object { $_ -replace "`r","" }))
}

# Muestra un fragmento de un registro ya guardado, para capturar el inicio o el final de una ejecución larga.
function EvidenciaLog([string]$nombre, [string]$titulo, [string]$archivo, [string]$parte, [int]$lineas = 36) {
  Clear-Host
  Write-Host $titulo -ForegroundColor Green
  $txt = Get-Content -Encoding UTF8 (Join-Path $script:LogDir $archivo)
  if ($parte -eq "inicio") { $txt = $txt | Select-Object -First $lineas } else { $txt = $txt | Select-Object -Last $lineas }
  $txt | ForEach-Object { Write-Host ($_ -replace "`r","") }
  Captura $nombre
}
