<#
    Funciones compartidas por instalar-kiosko.ps1 y desinstalar-kiosko.ps1.
    No se ejecuta por sí solo: se carga con ". .\comun.ps1".
#>

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class KioskoNativo
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_UNICODE_STRING
    {
        public UInt16 Length;
        public UInt16 MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public int Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr policy);

    [DllImport("advapi32.dll")]
    private static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING keyName, IntPtr privateData);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policy);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    private static extern int CreateProfile(string sid, string userName, StringBuilder profilePath, uint size);

    private const uint POLICY_ALL_ACCESS = 0x000F0FFF;
    private const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

    // Guarda (o borra, si valor es null) un secreto LSA. Winlogon lee la
    // contraseña del inicio de sesión automático del secreto "DefaultPassword",
    // así no queda en texto plano en el registro.
    public static void GuardarSecretoLsa(string nombre, string valor)
    {
        LSA_OBJECT_ATTRIBUTES atributos = new LSA_OBJECT_ATTRIBUTES();
        atributos.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));

        IntPtr politica;
        uint estado = LsaOpenPolicy(IntPtr.Zero, ref atributos, POLICY_ALL_ACCESS, out politica);
        if (estado != 0)
            throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(estado));

        LSA_UNICODE_STRING clave = new LSA_UNICODE_STRING();
        IntPtr datos = IntPtr.Zero;
        try
        {
            clave.Buffer = Marshal.StringToHGlobalUni(nombre);
            clave.Length = (UInt16)(nombre.Length * 2);
            clave.MaximumLength = (UInt16)(clave.Length + 2);

            if (valor != null)
            {
                LSA_UNICODE_STRING secreto = new LSA_UNICODE_STRING();
                secreto.Buffer = Marshal.StringToHGlobalUni(valor);
                secreto.Length = (UInt16)(valor.Length * 2);
                secreto.MaximumLength = (UInt16)(secreto.Length + 2);
                datos = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
                Marshal.StructureToPtr(secreto, datos, false);
            }

            estado = LsaStorePrivateData(politica, ref clave, datos);
            if (estado != 0 && !(valor == null && estado == STATUS_OBJECT_NAME_NOT_FOUND))
                throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(estado));
        }
        finally
        {
            if (datos != IntPtr.Zero)
            {
                LSA_UNICODE_STRING secreto = (LSA_UNICODE_STRING)Marshal.PtrToStructure(datos, typeof(LSA_UNICODE_STRING));
                Marshal.FreeHGlobal(secreto.Buffer);
                Marshal.FreeHGlobal(datos);
            }
            Marshal.FreeHGlobal(clave.Buffer);
            LsaClose(politica);
        }
    }

    // Crea el perfil del usuario (carpeta y NTUSER.DAT) sin tener que iniciar sesión.
    public static void CrearPerfil(string sid, string usuario)
    {
        StringBuilder ruta = new StringBuilder(260);
        int hr = CreateProfile(sid, usuario, ruta, (uint)ruta.Capacity);
        // 0x800700B7 = ERROR_ALREADY_EXISTS
        if (hr != 0 && hr != unchecked((int)0x800700B7))
            Marshal.ThrowExceptionForHR(hr);
    }
}
"@

$script:RutaWinlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$script:RutaPoliticasEdge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$script:RutaPoliticasExplorerMaquina = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'

function Write-Paso([string]$Mensaje) {
    Write-Host ''
    Write-Host "==> $Mensaje" -ForegroundColor Cyan
}

function Set-ValorRegistro {
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)]$Valor,
        [ValidateSet('String', 'ExpandString', 'DWord')][string]$Tipo = 'String'
    )
    if (-not (Test-Path $Ruta)) { New-Item -Path $Ruta -Force | Out-Null }
    New-ItemProperty -Path $Ruta -Name $Nombre -Value $Valor -PropertyType $Tipo -Force | Out-Null
}

function Remove-ValorRegistro([string]$Ruta, [string]$Nombre) {
    if (Test-Path $Ruta) {
        Remove-ItemProperty -Path $Ruta -Name $Nombre -ErrorAction SilentlyContinue
    }
}

# Muestra el estado del antivirus SIN modificar nada. El kiosko nunca desactiva
# ni agrega exclusiones al antivirus.
function Show-EstadoAntivirus {
    try {
        $productos = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
        foreach ($p in $productos) {
            Write-Host "    Antivirus registrado: $($p.displayName)"
        }
    } catch {
        Write-Host '    No se pudo consultar el Centro de seguridad de Windows.' -ForegroundColor Yellow
    }

    try {
        $estado = Get-MpComputerStatus -ErrorAction Stop
        Write-Host "    Microsoft Defender - antivirus activo: $($estado.AntivirusEnabled)"
        Write-Host "    Microsoft Defender - protección en tiempo real: $($estado.RealTimeProtectionEnabled)"
        if ($estado.AntivirusEnabled -and -not $estado.RealTimeProtectionEnabled) {
            Write-Host '    ATENCIÓN: la protección en tiempo real está apagada. El kiosko no la toca;' -ForegroundColor Yellow
            Write-Host '    revísela en "Seguridad de Windows" antes de dejar el equipo en producción.' -ForegroundColor Yellow
        }
    } catch {
        # Normal si hay otro antivirus instalado (Defender queda en modo pasivo).
        Write-Host '    Microsoft Defender no está activo (puede haber otro antivirus instalado).'
    }
}

# Ejecuta $Accion con el registro del usuario (HKEY_USERS\<SID>) cargado.
# Si el usuario tiene la sesión iniciada, su registro ya está cargado y se usa tal cual.
function Invoke-ConRegistroDeUsuario {
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][scriptblock]$Accion
    )
    $raiz = "Registry::HKEY_USERS\$Sid"
    $cargadoAqui = $false

    if (-not (Test-Path $raiz)) {
        $perfil = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -ErrorAction SilentlyContinue
        if (-not $perfil) { throw "El usuario con SID $Sid no tiene perfil creado." }
        $ntuser = Join-Path ([Environment]::ExpandEnvironmentVariables($perfil.ProfileImagePath)) 'NTUSER.DAT'
        & reg.exe load "HKU\$Sid" "$ntuser" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo cargar el registro del usuario ($ntuser)." }
        $cargadoAqui = $true
    }

    try {
        & $Accion $raiz
    } finally {
        if ($cargadoAqui) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            for ($i = 0; $i -lt 5; $i++) {
                & reg.exe unload "HKU\$Sid" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Seconds 1
                [GC]::Collect()
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "No se pudo descargar HKU\$Sid. Reinicie el equipo para liberarlo."
            }
        }
    }
}
