<#
.SYNOPSIS
    Shell del modo kiosko de telemonitoreo.

.DESCRIPTION
    Se ejecuta en lugar del Escritorio de Windows (explorer.exe) para el usuario kiosko,
    por lo que nunca se ven el menú Inicio, la barra de tareas ni el escritorio.

    - Abre Microsoft Edge en modo kiosko con la URL configurada y lo vuelve a abrir si se cierra.
      Las políticas de Edge que aplica el instalador solo permiten navegar el sitio configurado.
    - Verifica la conexión a internet cada pocos segundos.
    - Si no hay internet: cierra el navegador y muestra la pantalla de configuración de
      internet del kiosko (lista de redes Wi-Fi para conectarse). Si el equipo no tiene
      Wi-Fi, abre la configuración de red de Windows. Cuando vuelve la conexión, cierra
      la configuración y vuelve a abrir el navegador.
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

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -Path (Join-Path $base 'WifiNativo.cs')

# --------------------------------------------------------------------------------------
# Configuración
# --------------------------------------------------------------------------------------
if (-not $RutaConfig) { $RutaConfig = Join-Path $base 'config.json' }

$config = @{
    Url                      = 'https://www.telemonitoreo.uy'
    Titulo                   = 'Telemonitoreo'
    RutaNavegador            = ''
    ArgumentosNavegador      = @('--kiosk', '{URL}', '--edge-kiosk-type=fullscreen', '--no-first-run')
    UrlsVerificacion         = @('http://www.msftconnecttest.com/connecttest.txt', 'http://clients3.google.com/generate_204')
    IntervaloVerificacionSeg = 5
    TimeoutVerificacionSeg   = 4
    FallosParaSinConexion    = 3
    AbrirConfiguracionWindows = 'auto'
    PaginaConfiguracionRed   = 'ms-settings:network-status'
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
# Configuración de red
# El Explorador de Windows nunca se inicia (mostraría el menú Inicio y la barra de
# tareas). Para Wi-Fi se usa la lista propia del kiosko; la app Configuración de
# Windows se abre en ventana sin menú Inicio.
# --------------------------------------------------------------------------------------
$hayWifi = [WifiNativo]::HayAdaptador()
Write-Log "Adaptador Wi-Fi: $hayWifi"

function Open-ConfiguracionWindows {
    $pagina = [string]$config.PaginaConfiguracionRed
    if (-not $pagina.StartsWith('ms-settings:')) { $pagina = 'ms-settings:network-status' }
    Write-Log "Abriendo configuración de red de Windows ($pagina)."
    try {
        Start-Process $pagina
    } catch {
        Write-Log "No se pudo abrir $pagina : $_"
        Show-Mensaje 'No se pudo abrir la configuración de internet de Windows.'
    }
}

function Close-ConfiguracionWindows {
    Get-ProcesoDeSesion 'SystemSettings' | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ProcesoDeSesion 'osk' | Stop-Process -Force -ErrorAction SilentlyContinue
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
# Pantalla del kiosko
# --------------------------------------------------------------------------------------
$colorFondo = [System.Drawing.Color]::FromArgb(24, 32, 48)
$colorBoton = [System.Drawing.Color]::FromArgb(0, 120, 212)
$colorSecundario = [System.Drawing.Color]::FromArgb(70, 80, 100)

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

function New-Boton([string]$Texto, [System.Drawing.Color]$Color, [int]$Ancho = 540) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 13)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Size = New-Object System.Drawing.Size($Ancho, 48)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b)
    return $b
}

$lblTitulo = New-Etiqueta 28 'Bold'
$lblTitulo.Text = $config.Titulo
$lblEstado = New-Etiqueta 15

# Lista de redes Wi-Fi
$lblRedes = New-Etiqueta 12
$lblRedes.Text = 'Redes Wi-Fi disponibles:'
$lblRedes.TextAlign = 'BottomLeft'

$lstRedes = New-Object System.Windows.Forms.ListBox
$lstRedes.Font = New-Object System.Drawing.Font('Segoe UI', 14)
$lstRedes.Size = New-Object System.Drawing.Size(540, 200)
$lstRedes.IntegralHeight = $false
$form.Controls.Add($lstRedes)

$txtContrasena = New-Object System.Windows.Forms.TextBox
$txtContrasena.Font = New-Object System.Drawing.Font('Segoe UI', 14)
$txtContrasena.Size = New-Object System.Drawing.Size(540, 36)
$txtContrasena.UseSystemPasswordChar = $true
$form.Controls.Add($txtContrasena)
$lblContrasena = New-Etiqueta 12
$lblContrasena.Text = 'Contraseña de la red:'
$lblContrasena.TextAlign = 'BottomLeft'

$btnConectar = New-Boton 'Conectar' $colorBoton 265
$btnTeclado = New-Boton 'Teclado en pantalla' $colorSecundario 265
$btnConfig = New-Boton 'Más opciones de internet' $colorSecundario 265
$btnReintentar = New-Boton 'Reintentar ahora' $colorSecundario 265
$btnApagar = New-Boton 'Apagar equipo' ([System.Drawing.Color]::FromArgb(150, 40, 40)) 220
$btnApagar.Font = New-Object System.Drawing.Font('Segoe UI', 11)

$controlesWifi = @($lblRedes, $lstRedes, $lblContrasena, $txtContrasena, $btnConectar, $btnTeclado)
$controlesSinConexion = @($btnConfig, $btnReintentar)

function Update-Disposicion {
    $ancho = $form.ClientSize.Width
    $alto = $form.ClientSize.Height
    $x = [int](($ancho - 540) / 2)
    $y = [int]($alto * 0.05)

    $lblTitulo.SetBounds(0, $y, $ancho, 56); $y += 60
    $lblEstado.SetBounds([int]($ancho * 0.1), $y, [int]($ancho * 0.8), 70); $y += 80

    if ($lstRedes.Visible) {
        $lblRedes.SetBounds($x, $y, 540, 26); $y += 28
        $alturaLista = [Math]::Max(120, [Math]::Min(260, $alto - $y - 300))
        $lstRedes.SetBounds($x, $y, 540, $alturaLista); $y += $alturaLista + 8
        $lblContrasena.SetBounds($x, $y, 540, 26); $y += 28
        $txtContrasena.Location = New-Object System.Drawing.Point($x, $y); $y += $txtContrasena.Height + 10
        $btnConectar.Location = New-Object System.Drawing.Point($x, $y)
        $btnTeclado.Location = New-Object System.Drawing.Point(($x + 275), $y); $y += 58
    }
    $btnConfig.Location = New-Object System.Drawing.Point($x, $y)
    $btnReintentar.Location = New-Object System.Drawing.Point(($x + 275), $y)

    $btnApagar.Location = New-Object System.Drawing.Point([int](($ancho - $btnApagar.Width) / 2), $alto - $btnApagar.Height - 30)
}

function Show-Mensaje([string]$Texto) { $lblEstado.Text = $Texto }

function Show-Estado([string]$Estado) {
    switch ($Estado) {
        'verificando' { Show-Mensaje 'Verificando la conexión a internet...' }
        'cargando' { Show-Mensaje 'Abriendo telemonitoreo...' }
        'sinconexion' {
            if ($hayWifi) {
                Show-Mensaje "No hay conexión a internet.`nElija una red Wi-Fi para conectarse. El telemonitoreo se abrirá solo al volver la conexión."
            } else {
                Show-Mensaje "No hay conexión a internet.`nRevise el cable de red. El telemonitoreo se abrirá solo al volver la conexión."
            }
        }
    }
    $sinConexion = ($Estado -eq 'sinconexion')
    foreach ($c in $controlesSinConexion) { $c.Visible = $sinConexion }
    foreach ($c in $controlesWifi) { $c.Visible = ($sinConexion -and $hayWifi) }
    Update-Disposicion
}

# ---- Wi-Fi ----
$script:proximaListaRedes = [datetime]::MinValue
$script:ssidSeleccionado = $null

function Update-ListaRedes {
    if (-not $hayWifi) { return }
    # No refrescar mientras se escribe la contraseña.
    if ($txtContrasena.Text.Length -gt 0) { return }
    try {
        $seleccion = if ($lstRedes.SelectedItem) { $lstRedes.SelectedItem.Ssid } else { $null }
        $redes = [WifiNativo]::Listar()
        $lstRedes.BeginUpdate()
        $lstRedes.Items.Clear()
        foreach ($r in $redes) {
            $i = $lstRedes.Items.Add($r)
            if ($r.Ssid -eq $seleccion) { $lstRedes.SelectedIndex = $i }
        }
        $lstRedes.EndUpdate()
    } catch {
        Write-Log "Error al listar redes Wi-Fi: $_"
    }
}

function Start-BusquedaRedes {
    if (-not $hayWifi) { return }
    try { [WifiNativo]::Buscar() } catch { Write-Log "Error al buscar redes Wi-Fi: $_" }
    # Los resultados de la búsqueda tardan unos segundos.
    $script:proximaListaRedes = (Get-Date).AddSeconds(4)
}

$lstRedes.Add_SelectedIndexChanged({
        $red = $lstRedes.SelectedItem
        if (-not $red -or $red.Ssid -eq $script:ssidSeleccionado) { return }
        $script:ssidSeleccionado = $red.Ssid
        $txtContrasena.Text = ''
        $necesitaContrasena = $red.Segura -and -not $red.TienePerfil
        $lblContrasena.Text = if (-not $red.Segura) { 'Red abierta (sin contraseña):' }
        elseif ($red.TienePerfil) { 'Contraseña (déjela vacía para usar la guardada):' }
        else { 'Contraseña de la red:' }
        if ($necesitaContrasena) { $txtContrasena.Focus() }
    })

function Connect-RedSeleccionada {
    $red = $lstRedes.SelectedItem
    if (-not $red) { Show-Mensaje 'Elija una red Wi-Fi de la lista.'; return }
    Write-Log "Conectando a la red Wi-Fi '$($red.Ssid)'."
    $mensajeError = [WifiNativo]::Conectar($red, $txtContrasena.Text)
    $txtContrasena.Text = ''
    if ($mensajeError) {
        Write-Log "Wi-Fi: $mensajeError"
        Show-Mensaje $mensajeError
        return
    }
    Show-Mensaje "Conectando a '$($red.Ssid)'... Si no conecta en unos segundos, revise la contraseña."
    $script:proximaVerificacion = (Get-Date).AddSeconds(3)
    $script:proximaListaRedes = (Get-Date).AddSeconds(6)
}

$btnConectar.Add_Click({ try { Connect-RedSeleccionada } catch { Write-Log "Error: $_" } })
$txtContrasena.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; try { Connect-RedSeleccionada } catch { Write-Log "Error: $_" } }
    })
$lstRedes.Add_DoubleClick({ try { Connect-RedSeleccionada } catch { Write-Log "Error: $_" } })
$btnTeclado.Add_Click({
        try { Start-Process -FilePath "$env:SystemRoot\System32\osk.exe" } catch { Write-Log "Error al abrir el teclado: $_" }
    })
$btnConfig.Add_Click({ try { Open-ConfiguracionWindows } catch { Write-Log "Error: $_" } })
$btnReintentar.Add_Click({
        Show-Mensaje 'Verificando la conexión a internet...'
        $script:proximaVerificacion = Get-Date
        Start-BusquedaRedes
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
            Close-ConfiguracionWindows
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
        Start-BusquedaRedes
        $abrir = [string]$config.AbrirConfiguracionWindows
        if ($abrir -eq 'siempre' -or ($abrir -eq 'auto' -and -not $hayWifi)) {
            Open-ConfiguracionWindows
        }
    }
}

function Invoke-Ciclo {
    $ahora = Get-Date

    if ($script:sinConexion -and $hayWifi -and $ahora -ge $script:proximaListaRedes) {
        Update-ListaRedes
        $script:proximaListaRedes = $ahora.AddSeconds(10)
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
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    Write-Log 'Fin del kiosko.'
    $timer.Stop()
    $http.Dispose()
    $mutex.ReleaseMutex()
}
