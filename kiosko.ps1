<#
.SYNOPSIS
    Shell del modo kiosko de telemonitoreo.

.DESCRIPTION
    Se ejecuta en lugar del Escritorio de Windows (explorer.exe) para el usuario kiosko.

    - Abre Microsoft Edge en modo kiosko con la URL configurada y lo vuelve a abrir si se cierra.
    - Verifica la conexión a internet cada pocos segundos.
    - Si no hay internet: cierra el navegador, muestra una pantalla de aviso y abre la
      configuración de red de Windows. Cuando vuelve la conexión, cierra la configuración
      y vuelve a abrir el navegador.
    - No toca el antivirus ni ninguna otra configuración de seguridad del equipo.

    Registro de eventos: %LOCALAPPDATA%\Kiosko\kiosko.log (del usuario kiosko).
#>
param(
    [string]$RutaConfig
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# --------------------------------------------------------------------------------------
# Configuración
# --------------------------------------------------------------------------------------
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RutaConfig) { $RutaConfig = Join-Path $base 'config.json' }

$config = @{
    Url                      = 'about:blank'
    Titulo                   = 'Telemonitoreo'
    RutaNavegador            = ''
    ArgumentosNavegador      = @('--kiosk', '{URL}', '--edge-kiosk-type=fullscreen', '--no-first-run')
    UrlsVerificacion         = @('http://www.msftconnecttest.com/connecttest.txt', 'http://clients3.google.com/generate_204')
    IntervaloVerificacionSeg = 5
    TimeoutVerificacionSeg   = 4
    FallosParaSinConexion    = 3
    PaginaConfiguracionRed   = 'auto'
    ReabrirConfiguracionSeg  = 60
}
if (Test-Path $RutaConfig) {
    $json = Get-Content -Path $RutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $config[$p.Name] = $p.Value }
}

# --------------------------------------------------------------------------------------
# Registro de eventos
# --------------------------------------------------------------------------------------
$dirLog = Join-Path $env:LOCALAPPDATA 'Kiosko'
New-Item -ItemType Directory -Force -Path $dirLog | Out-Null
$archivoLog = Join-Path $dirLog 'kiosko.log'
if ((Test-Path $archivoLog) -and (Get-Item $archivoLog).Length -gt 1MB) {
    Move-Item $archivoLog "$archivoLog.anterior" -Force
}

function Write-Log([string]$Mensaje) {
    try {
        Add-Content -Path $archivoLog -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Mensaje)
    } catch { }
}

# Una sola instancia por sesión.
$mutex = New-Object System.Threading.Mutex($false, 'Local\KioskoTelemonitoreo')
if (-not $mutex.WaitOne(0)) { exit }

Write-Log "Inicio del kiosko. URL: $($config.Url)"

# Solo informativo: el kiosko nunca modifica el antivirus.
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Write-Log "Defender: antivirus=$($mp.AntivirusEnabled) tiempo real=$($mp.RealTimeProtectionEnabled)"
} catch {
    Write-Log 'Defender no disponible para consulta (puede haber otro antivirus activo).'
}

$sesion = (Get-Process -Id $PID).SessionId

function Get-ProcesoDeSesion([string]$Nombre) {
    @(Get-Process -Name $Nombre -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sesion })
}

# --------------------------------------------------------------------------------------
# Navegador
# --------------------------------------------------------------------------------------
function Get-RutaNavegador {
    if ($config.RutaNavegador -and (Test-Path $config.RutaNavegador)) { return $config.RutaNavegador }
    $candidatos = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidatos) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$rutaNavegador = Get-RutaNavegador
if (-not $rutaNavegador) { Write-Log 'ERROR: no se encontró el navegador (Microsoft Edge).' }
$procesoNavegador = if ($rutaNavegador) { [IO.Path]::GetFileNameWithoutExtension($rutaNavegador) } else { 'msedge' }
$script:inicioNavegador = [datetime]::MinValue

function Test-NavegadorActivo {
    # Recién lanzado: darle tiempo a que aparezca la ventana.
    if (((Get-Date) - $script:inicioNavegador).TotalSeconds -lt 20) { return $true }
    $conVentana = Get-ProcesoDeSesion $procesoNavegador | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
    return [bool]$conVentana
}

function Start-Navegador {
    if (-not $rutaNavegador) { return }
    # Procesos en segundo plano sin ventana impedirían abrir la ventana de kiosko.
    Stop-Navegador
    $argumentos = foreach ($a in $config.ArgumentosNavegador) {
        $a = ([string]$a).Replace('{URL}', [string]$config.Url)
        if ($a -match '\s') { '"' + $a + '"' } else { $a }
    }
    Write-Log 'Abriendo navegador.'
    Start-Process -FilePath $rutaNavegador -ArgumentList $argumentos
    $script:inicioNavegador = Get-Date
}

function Stop-Navegador {
    $procesos = Get-ProcesoDeSesion $procesoNavegador
    if ($procesos) {
        $procesos | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    $script:inicioNavegador = [datetime]::MinValue
}

# --------------------------------------------------------------------------------------
# Configuración de red de Windows
# --------------------------------------------------------------------------------------
$script:ultimaAperturaConfig = [datetime]::MinValue
$script:verificarConfigEn = $null   # momento para comprobar que la app Configuración abrió
$script:mostrarRedesEn = $null      # momento para abrir la lista de redes Wi-Fi
$script:explorerIniciado = $false

function Test-AdaptadorWifi {
    try {
        return [bool](Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.NdisPhysicalMedium -eq 9 })
    } catch {
        return $false
    }
}

function Test-ConfiguracionAbierta {
    if (Get-ProcesoDeSesion 'SystemSettings') { return $true }
    if ($script:explorerIniciado -and (Get-ProcesoDeSesion 'explorer')) { return $true }
    return $false
}

function Open-ConfiguracionRed {
    $pagina = [string]$config.PaginaConfiguracionRed
    if (-not $pagina -or $pagina -eq 'auto') {
        $pagina = if (Test-AdaptadorWifi) { 'ms-settings:network-wifi' } else { 'ms-settings:network-status' }
    }
    Write-Log "Abriendo configuración de red ($pagina)."
    $script:ultimaAperturaConfig = Get-Date
    try {
        Start-Process $pagina
        $script:verificarConfigEn = (Get-Date).AddSeconds(10)
    } catch {
        Write-Log "No se pudo abrir $pagina : $_"
        Open-ConexionesDeRedClasico
    }
}

# Alternativa si la app Configuración no abre: panel clásico "Conexiones de red".
function Open-ConexionesDeRedClasico {
    Write-Log 'Abriendo panel clásico de conexiones de red (ncpa.cpl).'
    $script:explorerIniciado = $true
    Start-Process -FilePath "$env:SystemRoot\System32\control.exe" -ArgumentList 'ncpa.cpl'
}

# La lista de redes Wi-Fi de Windows 10 es parte de la barra de tareas, que no existe en
# el kiosko. Se inicia el Explorador solo mientras no hay conexión y se cierra al volver.
function Show-RedesWifi {
    if (-not (Get-ProcesoDeSesion 'explorer')) {
        Write-Log 'Iniciando Explorador para mostrar redes Wi-Fi.'
        $script:explorerIniciado = $true
        Start-Process -FilePath "$env:SystemRoot\explorer.exe"
        $script:mostrarRedesEn = (Get-Date).AddSeconds(5)
    } else {
        Start-Process 'ms-availablenetworks:'
    }
}

function Close-ConfiguracionRed {
    Get-ProcesoDeSesion 'SystemSettings' | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($script:explorerIniciado) {
        Get-ProcesoDeSesion 'explorer' | Stop-Process -Force -ErrorAction SilentlyContinue
        $script:explorerIniciado = $false
    }
    $script:verificarConfigEn = $null
    $script:mostrarRedesEn = $null
}

# --------------------------------------------------------------------------------------
# Verificación de internet (asíncrona, para no congelar la pantalla)
# Cualquier respuesta HTTP cuenta como conectado (incluye portales cautivos, que
# luego se muestran en el navegador para iniciar sesión en la red).
# --------------------------------------------------------------------------------------
$manejador = New-Object System.Net.Http.HttpClientHandler
$manejador.AllowAutoRedirect = $false
$http = New-Object System.Net.Http.HttpClient($manejador)
$http.Timeout = [TimeSpan]::FromSeconds([double]$config.TimeoutVerificacionSeg)
$http.DefaultRequestHeaders.CacheControl = New-Object System.Net.Http.Headers.CacheControlHeaderValue -Property @{ NoCache = $true }

$script:tareas = $null
$script:proximaVerificacion = Get-Date
$script:fallos = 0
$script:sinConexion = $false

function Start-Verificacion {
    $script:tareas = @(foreach ($u in $config.UrlsVerificacion) {
            $http.GetAsync([string]$u, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        })
}

# Devuelve $null mientras la verificación sigue en curso; $true / $false al terminar.
function Get-ResultadoVerificacion {
    if (-not $script:tareas) { return $null }
    $conectado = $false
    $pendientes = $false
    foreach ($t in $script:tareas) {
        if (-not $t.IsCompleted) { $pendientes = $true; continue }
        if ($t.Status -eq 'RanToCompletion') { $conectado = $true }
    }
    if (-not $conectado -and $pendientes) { return $null }

    foreach ($t in $script:tareas) {
        if ($t.IsCompleted) {
            if ($t.Status -eq 'RanToCompletion') { $t.Result.Dispose() } else { $null = $t.Exception }
        }
    }
    $script:tareas = $null
    return $conectado
}

# --------------------------------------------------------------------------------------
# Pantalla de fondo del kiosko
# --------------------------------------------------------------------------------------
$colorFondo = [System.Drawing.Color]::FromArgb(24, 32, 48)
$colorBoton = [System.Drawing.Color]::FromArgb(0, 120, 212)

$form = New-Object System.Windows.Forms.Form
$form.Text = $config.Titulo
$form.FormBorderStyle = 'None'
$form.WindowState = 'Maximized'
$form.StartPosition = 'Manual'
$form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$form.BackColor = $colorFondo
$form.ForeColor = [System.Drawing.Color]::White
$form.ShowInTaskbar = $false

function New-Etiqueta([float]$Tamano, [System.Drawing.FontStyle]$Estilo = 'Regular') {
    $l = New-Object System.Windows.Forms.Label
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Tamano, $Estilo)
    $l.TextAlign = 'MiddleCenter'
    $l.AutoSize = $false
    $form.Controls.Add($l)
    return $l
}

function New-Boton([string]$Texto, [System.Drawing.Color]$Color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Size = New-Object System.Drawing.Size(460, 56)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b)
    return $b
}

$lblTitulo = New-Etiqueta 32 'Bold'
$lblTitulo.Text = $config.Titulo
$lblEstado = New-Etiqueta 18
$btnConfig = New-Boton 'Abrir configuración de internet' $colorBoton
$btnWifi = New-Boton 'Ver redes Wi-Fi disponibles' $colorBoton
$btnReintentar = New-Boton 'Reintentar ahora' ([System.Drawing.Color]::FromArgb(70, 80, 100))
$btnApagar = New-Boton 'Apagar equipo' ([System.Drawing.Color]::FromArgb(150, 40, 40))
$btnApagar.Size = New-Object System.Drawing.Size(220, 44)
$btnApagar.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$botonesSinConexion = @($btnConfig, $btnWifi, $btnReintentar)

function Update-Disposicion {
    $ancho = $form.ClientSize.Width
    $alto = $form.ClientSize.Height
    $y = [int]($alto * 0.22)
    $lblTitulo.SetBounds(0, $y, $ancho, 70)
    $lblEstado.SetBounds([int]($ancho * 0.1), $y + 90, [int]($ancho * 0.8), 120)
    $y += 240
    foreach ($b in $botonesSinConexion) {
        $b.Location = New-Object System.Drawing.Point([int](($ancho - $b.Width) / 2), $y)
        $y += $b.Height + 16
    }
    $btnApagar.Location = New-Object System.Drawing.Point([int](($ancho - $btnApagar.Width) / 2), $alto - $btnApagar.Height - 40)
}

function Show-Estado([string]$Estado) {
    switch ($Estado) {
        'verificando' {
            $lblEstado.Text = 'Verificando la conexión a internet...'
        }
        'cargando' {
            $lblEstado.Text = 'Abriendo telemonitoreo...'
        }
        'sinconexion' {
            $lblEstado.Text = "No hay conexión a internet.`nConéctese a una red Wi-Fi o por cable. Cuando vuelva la conexión, el telemonitoreo se abrirá solo."
        }
    }
    $visible = ($Estado -eq 'sinconexion')
    foreach ($b in $botonesSinConexion) { $b.Visible = $visible }
}

$btnConfig.Add_Click({ try { Open-ConfiguracionRed } catch { Write-Log "Error: $_" } })
$btnWifi.Add_Click({ try { Show-RedesWifi } catch { Write-Log "Error: $_" } })
$btnReintentar.Add_Click({
        $lblEstado.Text = 'Verificando la conexión a internet...'
        $script:proximaVerificacion = Get-Date
    })
$btnApagar.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show($form, '¿Apagar el equipo?', $config.Titulo, 'YesNo', 'Question')
        if ($r -eq 'Yes') {
            Write-Log 'Apagado solicitado desde el kiosko.'
            Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/s', '/t', '0'
        }
    })

# El shell del kiosko no se puede cerrar con Alt+F4; solo al apagar o cerrar sesión.
$form.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $e.Cancel = $true }
    })
$form.Add_Resize({ Update-Disposicion })

# --------------------------------------------------------------------------------------
# Ciclo principal
# --------------------------------------------------------------------------------------
function Update-Conexion([bool]$Conectado) {
    if ($Conectado) {
        $script:fallos = 0
        if ($script:sinConexion) {
            Write-Log 'Conexión a internet restablecida.'
            $script:sinConexion = $false
            Close-ConfiguracionRed
        }
        if (-not (Test-NavegadorActivo)) {
            Show-Estado 'cargando'
            Start-Navegador
        }
        return
    }

    $script:fallos++
    if ($script:fallos -lt [int]$config.FallosParaSinConexion) { return }

    if (-not $script:sinConexion) {
        Write-Log 'Sin conexión a internet.'
        $script:sinConexion = $true
        Stop-Navegador
        Show-Estado 'sinconexion'
        $form.Activate()
        Open-ConfiguracionRed
    } elseif (-not (Test-ConfiguracionAbierta) -and
        ((Get-Date) - $script:ultimaAperturaConfig).TotalSeconds -ge [double]$config.ReabrirConfiguracionSeg) {
        # Si cerraron la configuración y sigue sin internet, se vuelve a abrir.
        Open-ConfiguracionRed
    }
}

function Invoke-Ciclo {
    $ahora = Get-Date

    if ($script:verificarConfigEn -and $ahora -ge $script:verificarConfigEn) {
        $script:verificarConfigEn = $null
        if (-not (Get-ProcesoDeSesion 'SystemSettings')) {
            Write-Log 'La app Configuración no se abrió.'
            Open-ConexionesDeRedClasico
        }
    }

    if ($script:mostrarRedesEn -and $ahora -ge $script:mostrarRedesEn) {
        $script:mostrarRedesEn = $null
        Start-Process 'ms-availablenetworks:'
    }

    $resultado = Get-ResultadoVerificacion
    if ($null -ne $resultado) {
        Update-Conexion $resultado
        $script:proximaVerificacion = $ahora.AddSeconds([double]$config.IntervaloVerificacionSeg)
    } elseif (-not $script:tareas -and $ahora -ge $script:proximaVerificacion) {
        Start-Verificacion
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
        try { Invoke-Ciclo } catch { Write-Log "Error en el ciclo: $_" }
    })

Show-Estado 'verificando'
Update-Disposicion
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    Write-Log 'Fin del kiosko.'
    $timer.Stop()
    $http.Dispose()
    $mutex.ReleaseMutex()
}
