<#
.SYNOPSIS
    Quita el modo kiosko de telemonitoreo y deja el equipo como estaba.

.EXAMPLE
    .\desinstalar-kiosko.ps1

.EXAMPLE
    .\desinstalar-kiosko.ps1 -EliminarUsuario
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
param(
    [string]$Usuario = 'kiosko',
    [string]$RutaInstalacion = (Join-Path $env:ProgramFiles 'KioskoTelemonitoreo'),
    # Eliminar también la cuenta del kiosko y su perfil.
    [switch]$EliminarUsuario
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'comun.ps1')

Write-Paso 'Inicio de sesión automático'
$actual = Get-ItemProperty $RutaWinlogon -ErrorAction SilentlyContinue
if ($actual.DefaultUserName -eq $Usuario) {
    Set-ValorRegistro $RutaWinlogon 'AutoAdminLogon' '0'
    Remove-ValorRegistro $RutaWinlogon 'DefaultPassword'
    [KioskoNativo]::GuardarSecretoLsa('DefaultPassword', $null)
    Write-Host '    Desactivado.'
} else {
    Write-Host "    No estaba configurado para '$Usuario'; no se modifica."
}

$cuenta = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
if ($cuenta) {
    $sid = $cuenta.SID.Value
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid") {
        Write-Paso "Restaurando el escritorio de '$Usuario'"
        Invoke-ConRegistroDeUsuario -Sid $sid -Accion {
            param($raiz)
            Remove-ValorRegistro "$raiz\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" 'Shell'
            $sistema = "$raiz\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            foreach ($v in 'DisableTaskMgr', 'DisableLockWorkstation', 'DisableChangePassword') { Remove-ValorRegistro $sistema $v }
            $explorer = "$raiz\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
            foreach ($v in 'NoRun', 'NoWinKeys') { Remove-ValorRegistro $explorer $v }
        }
    }

    if ($EliminarUsuario) {
        Write-Paso "Eliminando usuario '$Usuario' y su perfil"
        Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Remove-CimInstance
        Remove-LocalUser -Name $Usuario
    }
}

Write-Paso 'Políticas'
foreach ($v in 'HideFirstRunExperience', 'StartupBoostEnabled', 'BackgroundModeEnabled') { Remove-ValorRegistro $RutaPoliticasEdge $v }
Remove-ValorRegistro $RutaPoliticasExplorerMaquina 'SettingsPageVisibility'

Write-Paso "Eliminando $RutaInstalacion"
if (Test-Path $RutaInstalacion) { Remove-Item $RutaInstalacion -Recurse -Force }

Write-Paso 'Listo'
Write-Host '    El antivirus no fue modificado en ningún momento. Reinicie el equipo.'
Write-Host '    La configuración de energía no se restauró; ajústela en Configuración > Sistema > Energía.'
