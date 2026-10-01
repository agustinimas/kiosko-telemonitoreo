<#
.SYNOPSIS
    Configura un equipo Windows 10 como kiosko de telemonitoreo.

.DESCRIPTION
    - Crea un usuario local estándar (sin permisos de administrador) para el kiosko.
    - Reemplaza el Escritorio de Windows SOLO para ese usuario por kiosko.ps1, que abre
      Microsoft Edge en modo kiosko y, si no hay internet, abre la configuración de red.
      No se ven el menú Inicio, la barra de tareas ni el escritorio.
    - Políticas de Edge para ese usuario: solo se puede navegar el sitio de telemonitoreo
      (y sus páginas internas); cualquier otra dirección queda bloqueada.
    - Configura el inicio de sesión automático (contraseña guardada como secreto LSA,
      no en texto plano).
    - NO desactiva, desinstala ni agrega exclusiones al antivirus (Microsoft Defender
      u otro), ni toca Windows Update, el firewall o SmartScreen.

    Funciona en Windows 10 Pro, Enterprise y Education (no requiere Shell Launcher).

.EXAMPLE
    .\instalar-kiosko.ps1

.EXAMPLE
    .\instalar-kiosko.ps1 -SitiosPermitidos telemonitoreo.uy, otro-dominio-necesario.com
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
param(
    [string]$Url = 'https://www.telemonitoreo.uy',
    # Dominios que se pueden navegar (incluye subdominios y todas sus páginas). Todo lo demás se bloquea.
    [string[]]$SitiosPermitidos = @('telemonitoreo.uy'),
    [string]$Usuario = 'kiosko',
    [string]$NombreCompleto = 'Kiosko Telemonitoreo',
    [string]$Titulo = 'Telemonitoreo',
    [string]$RutaInstalacion = (Join-Path $env:ProgramFiles 'KioskoTelemonitoreo'),
    [string]$RutaNavegador = '',
    # No configurar el inicio de sesión automático.
    [switch]$SinInicioAutomatico,
    # Mantener la suspensión / apagado de pantalla configurados en el equipo.
    [switch]$PermitirSuspension,
    # Forzar también a nivel de equipo que la app Configuración muestre solo las páginas de red,
    # para versiones de Windows 10 que no respetan la política por usuario (afecta a TODOS los usuarios).
    [switch]$RestringirConfiguracion
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'comun.ps1')

$PaginasConfiguracionRed = 'showonly:network-status;network-wifi;network-ethernet;network-wifisettings;network-airplanemode;network-proxy;network-cellular'

if ($Usuario -eq $env:USERNAME) {
    throw "El usuario del kiosko no puede ser el usuario actual ($env:USERNAME). Use otro nombre."
}

# ----------------------------------------------------------------------------------------
Write-Paso 'Estado del antivirus (solo lectura, no se modifica)'
Show-EstadoAntivirus

# ----------------------------------------------------------------------------------------
Write-Paso "Copiando archivos a $RutaInstalacion"
# Program Files ya está protegido: el usuario kiosko solo puede leer, no modificar.
New-Item -ItemType Directory -Force -Path $RutaInstalacion | Out-Null
foreach ($archivo in 'kiosko.ps1', 'WifiNativo.cs') {
    Copy-Item (Join-Path $PSScriptRoot $archivo) $RutaInstalacion -Force
}

$archivoConfig = Join-Path $RutaInstalacion 'config.json'
$origenConfig = if (Test-Path $archivoConfig) { $archivoConfig } else { Join-Path $PSScriptRoot 'config.ejemplo.json' }
$configuracion = Get-Content $origenConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$configuracion | Add-Member -NotePropertyName Url -NotePropertyValue $Url -Force
$configuracion | Add-Member -NotePropertyName Titulo -NotePropertyValue $Titulo -Force
$configuracion | Add-Member -NotePropertyName RutaNavegador -NotePropertyValue $RutaNavegador -Force
$configuracion | ConvertTo-Json -Depth 5 | Set-Content -Path $archivoConfig -Encoding UTF8
Write-Host "    Configuración: $archivoConfig"

$rutaEdge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $RutaNavegador -and -not $rutaEdge) {
    Write-Warning 'No se encontró Microsoft Edge (Chromium). Instálelo o indique -RutaNavegador.'
}

# ----------------------------------------------------------------------------------------
Write-Paso "Usuario local '$Usuario'"
$caracteres = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
# Nadie necesita conocer esta contraseña: solo la usa el inicio de sesión automático.
$contrasena = 'Kk7!' + -join ($bytes | ForEach-Object { $caracteres[$_ % $caracteres.Length] })
$contrasenaSegura = ConvertTo-SecureString $contrasena -AsPlainText -Force

$cuenta = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
if ($cuenta) {
    Set-LocalUser -Name $Usuario -Password $contrasenaSegura -PasswordNeverExpires $true
    Enable-LocalUser -Name $Usuario
    Write-Host '    El usuario ya existía: se actualizó su contraseña.'
} else {
    $cuenta = New-LocalUser -Name $Usuario -Password $contrasenaSegura -FullName $NombreCompleto `
        -Description 'Usuario del kiosko de telemonitoreo' -PasswordNeverExpires -UserMayNotChangePassword
    Write-Host '    Usuario creado.'
}

# Grupo "Usuarios" (S-1-5-32-545) por SID para que funcione en Windows en cualquier idioma.
try { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $Usuario -ErrorAction Stop } catch { }
# El kiosko nunca debe ser administrador (S-1-5-32-544).
$administradores = Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $cuenta.SID }
if ($administradores) {
    Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $Usuario
    Write-Host '    Se quitó al usuario del grupo Administradores.'
}

$sid = $cuenta.SID.Value
[KioskoNativo]::CrearPerfil($sid, $Usuario)

# ----------------------------------------------------------------------------------------
Write-Paso 'Shell del kiosko y restricciones (solo para el usuario kiosko)'
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$scriptKiosko = Join-Path $RutaInstalacion 'kiosko.ps1'
# -ExecutionPolicy Bypass solo evita la política de ejecución de scripts; el antivirus
# sigue analizando el script (AMSI) como cualquier otro.
$comandoShell = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptKiosko`""

Invoke-ConRegistroDeUsuario -Sid $sid -Accion {
    param($raiz)
    Set-ValorRegistro "$raiz\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" 'Shell' $comandoShell

    $sistema = "$raiz\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ValorRegistro $sistema 'DisableTaskMgr' 1 'DWord'
    Set-ValorRegistro $sistema 'DisableLockWorkstation' 1 'DWord'
    Set-ValorRegistro $sistema 'DisableChangePassword' 1 'DWord'

    $explorer = "$raiz\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    Set-ValorRegistro $explorer 'NoRun' 1 'DWord'
    Set-ValorRegistro $explorer 'NoWinKeys' 1 'DWord'
    # En la app Configuración, solo las páginas de red (Windows 10 versiones recientes).
    Set-ValorRegistro $explorer 'SettingsPageVisibility' $PaginasConfiguracionRed

    # Sin atajos de accesibilidad (p. ej. Shift 5 veces) que abren otras ventanas.
    $accesibilidad = "$raiz\Control Panel\Accessibility"
    Set-ValorRegistro "$accesibilidad\StickyKeys" 'Flags' '506'
    Set-ValorRegistro "$accesibilidad\ToggleKeys" 'Flags' '58'
    Set-ValorRegistro "$accesibilidad\Keyboard Response" 'Flags' '122'

    # Políticas de Edge solo para el usuario kiosko.
    $politicas = "$raiz\Software\Policies"
    $edge = "$politicas\Microsoft\Edge"
    if (Test-Path $edge) { Remove-Item $edge -Recurse -Force }
    Set-ValorRegistro "$edge\URLBlocklist" '1' '*'
    $i = 1
    foreach ($sitio in $SitiosPermitidos) { Set-ValorRegistro "$edge\URLAllowlist" ([string]$i) $sitio; $i++ }
    Set-ValorRegistro "$edge\ExtensionInstallBlocklist" '1' '*'
    Set-ValorRegistro $edge 'DeveloperToolsAvailability' 2 'DWord'   # sin herramientas de desarrollo
    Set-ValorRegistro $edge 'BrowserAddProfileEnabled' 0 'DWord'
    Set-ValorRegistro $edge 'BrowserGuestModeEnabled' 0 'DWord'
    Set-ValorRegistro $edge 'HubsSidebarEnabled' 0 'DWord'           # sin barra lateral
    Set-ValorRegistro $edge 'EdgeShoppingAssistantEnabled' 0 'DWord'
    Set-ValorRegistro $edge 'PasswordManagerEnabled' 0 'DWord'
    Set-ValorRegistro $edge 'AutofillCreditCardEnabled' 0 'DWord'

    # Como en HKCU\Software\Policies estándar: el usuario solo puede leer sus políticas.
    $acl = Get-Acl $politicas
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    $herencia = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit'
    $propagacion = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($regla in @(
            @('S-1-5-18', 'FullControl'),
            @('S-1-5-32-544', 'FullControl'),
            @($sid, 'ReadKey'))) {
        $identidad = New-Object System.Security.Principal.SecurityIdentifier($regla[0])
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                    $identidad, $regla[1], $herencia, $propagacion, 'Allow')))
    }
    Set-Acl -Path $politicas -AclObject $acl
}
Write-Host "    Sitios permitidos en Edge: $($SitiosPermitidos -join ', ')" 
Write-Host "    Shell: $comandoShell"

# ----------------------------------------------------------------------------------------
Write-Paso 'Microsoft Edge'
# Sin asistente de primer inicio y sin procesos en segundo plano que interfieran con el kiosko.
Set-ValorRegistro $RutaPoliticasEdge 'HideFirstRunExperience' 1 'DWord'
Set-ValorRegistro $RutaPoliticasEdge 'StartupBoostEnabled' 0 'DWord'
Set-ValorRegistro $RutaPoliticasEdge 'BackgroundModeEnabled' 0 'DWord'
Write-Host '    Políticas aplicadas (SmartScreen y demás protecciones de Edge no se modifican).'

# ----------------------------------------------------------------------------------------
if ($RestringirConfiguracion) {
    Write-Paso 'Restringiendo la app Configuración a las páginas de red'
    Set-ValorRegistro $RutaPoliticasExplorerMaquina 'SettingsPageVisibility' $PaginasConfiguracionRed
    Write-Host '    ATENCIÓN: esta restricción aplica a todos los usuarios del equipo.' -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------------------
if (-not $PermitirSuspension) {
    Write-Paso 'Desactivando suspensión y apagado de pantalla (con corriente)'
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change monitor-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-ac 0
}

# ----------------------------------------------------------------------------------------
if (-not $SinInicioAutomatico) {
    Write-Paso 'Inicio de sesión automático'
    Set-ValorRegistro $RutaWinlogon 'AutoAdminLogon' '1'
    Set-ValorRegistro $RutaWinlogon 'DefaultUserName' $Usuario
    Set-ValorRegistro $RutaWinlogon 'DefaultDomainName' $env:COMPUTERNAME
    Remove-ValorRegistro $RutaWinlogon 'DefaultPassword'
    Remove-ValorRegistro $RutaWinlogon 'AutoLogonCount'
    [KioskoNativo]::GuardarSecretoLsa('DefaultPassword', $contrasena)
    Write-Host "    Al encender, el equipo iniciará sesión como '$Usuario'."
}

# ----------------------------------------------------------------------------------------
Write-Paso 'Listo'
Write-Host @"
    Reinicie el equipo para entrar en modo kiosko.

    Para administrar el equipo:
      - Ctrl+Alt+Supr > Cerrar sesión, y mantenga presionada la tecla Shift mientras
        Windows vuelve a la pantalla de inicio de sesión para evitar el inicio automático.
      - Inicie sesión con una cuenta de administrador: tendrá el escritorio normal.

    Para quitar el modo kiosko: .\desinstalar-kiosko.ps1
"@
