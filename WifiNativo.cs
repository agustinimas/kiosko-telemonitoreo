// Acceso a la API nativa de Wi-Fi de Windows (wlanapi.dll) para que el kiosko pueda
// listar redes y conectarse sin abrir el Explorador ni la barra de tareas.
// Compatible con el compilador de C# de Windows PowerShell 5.1.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

public class RedWifi
{
    public string Ssid;
    public byte[] SsidBytes;
    public int Senal;
    public bool Segura;
    public bool Conectada;
    public string Perfil;
    public int Autenticacion;
    public int Cifrado;

    public bool TienePerfil { get { return !String.IsNullOrEmpty(Perfil); } }

    public override string ToString()
    {
        string texto = Ssid + "   (" + Senal + "%)";
        if (Conectada) texto += "   - conectada";
        else if (Segura) texto += "   - protegida";
        return texto;
    }
}

public static class WifiNativo
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WLAN_CONNECTION_PARAMETERS
    {
        public int wlanConnectionMode;
        [MarshalAs(UnmanagedType.LPWStr)] public string strProfile;
        public IntPtr pDot11Ssid;
        public IntPtr pDesiredBssidList;
        public int dot11BssType;
        public uint dwFlags;
    }

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr clientHandle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr clientHandle, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(IntPtr clientHandle, IntPtr reserved, out IntPtr interfaceList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanScan(IntPtr clientHandle, ref Guid interfaceGuid, IntPtr ssid, IntPtr ieData, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanGetAvailableNetworkList(IntPtr clientHandle, ref Guid interfaceGuid, uint flags, IntPtr reserved, out IntPtr networkList);

    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
    private static extern uint WlanSetProfile(IntPtr clientHandle, ref Guid interfaceGuid, uint flags, string profileXml, string allUserProfileSecurity, bool overwrite, IntPtr reserved, out uint reasonCode);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanConnect(IntPtr clientHandle, ref Guid interfaceGuid, ref WLAN_CONNECTION_PARAMETERS parameters, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr memory);

    // Tamaños y desplazamientos de las estructuras de wlanapi.h
    private const int TAM_INTERFAZ = 532;     // WLAN_INTERFACE_INFO
    private const int TAM_RED = 628;          // WLAN_AVAILABLE_NETWORK
    private const int ERROR_ACCESS_DENIED = 5;
    private const uint WLAN_PROFILE_USER = 2;
    private const uint FLAG_CONECTADA = 1;

    // DOT11_AUTH_ALGORITHM
    private const int AUTH_OPEN = 1;
    private const int AUTH_WPA_PSK = 4;
    private const int AUTH_RSNA_PSK = 7;      // WPA2-Personal
    private const int AUTH_WPA3_SAE = 9;      // WPA3-Personal

    private static IntPtr Abrir()
    {
        uint version;
        IntPtr cliente;
        uint r = WlanOpenHandle(2, IntPtr.Zero, out version, out cliente);
        if (r != 0) throw new System.ComponentModel.Win32Exception((int)r);
        return cliente;
    }

    private static List<Guid> Interfaces(IntPtr cliente)
    {
        List<Guid> resultado = new List<Guid>();
        IntPtr lista;
        if (WlanEnumInterfaces(cliente, IntPtr.Zero, out lista) != 0) return resultado;
        try
        {
            int n = Marshal.ReadInt32(lista);
            for (int i = 0; i < n; i++)
            {
                IntPtr item = new IntPtr(lista.ToInt64() + 8 + (long)i * TAM_INTERFAZ);
                resultado.Add((Guid)Marshal.PtrToStructure(item, typeof(Guid)));
            }
        }
        finally { WlanFreeMemory(lista); }
        return resultado;
    }

    public static bool HayAdaptador()
    {
        try
        {
            IntPtr cliente = Abrir();
            try { return Interfaces(cliente).Count > 0; }
            finally { WlanCloseHandle(cliente, IntPtr.Zero); }
        }
        catch { return false; }
    }

    // Pide al adaptador que busque redes. El resultado aparece unos segundos después.
    public static void Buscar()
    {
        IntPtr cliente = Abrir();
        try
        {
            foreach (Guid g in Interfaces(cliente))
            {
                Guid copia = g;
                WlanScan(cliente, ref copia, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }
        finally { WlanCloseHandle(cliente, IntPtr.Zero); }
    }

    public static List<RedWifi> Listar()
    {
        Dictionary<string, RedWifi> porSsid = new Dictionary<string, RedWifi>();
        IntPtr cliente = Abrir();
        try
        {
            foreach (Guid g in Interfaces(cliente))
            {
                Guid copia = g;
                IntPtr lista;
                if (WlanGetAvailableNetworkList(cliente, ref copia, 0, IntPtr.Zero, out lista) != 0) continue;
                try
                {
                    int n = Marshal.ReadInt32(lista);
                    for (int i = 0; i < n; i++)
                    {
                        IntPtr p = new IntPtr(lista.ToInt64() + 8 + (long)i * TAM_RED);
                        RedWifi red = LeerRed(p);
                        if (red.Ssid.Length == 0) continue; // redes ocultas

                        RedWifi existente;
                        if (!porSsid.TryGetValue(red.Ssid, out existente))
                        {
                            porSsid[red.Ssid] = red;
                            continue;
                        }
                        existente.Senal = Math.Max(existente.Senal, red.Senal);
                        existente.Conectada |= red.Conectada;
                        if (!existente.TienePerfil && red.TienePerfil) existente.Perfil = red.Perfil;
                    }
                }
                finally { WlanFreeMemory(lista); }
            }
        }
        finally { WlanCloseHandle(cliente, IntPtr.Zero); }

        List<RedWifi> redes = new List<RedWifi>(porSsid.Values);
        redes.Sort(delegate (RedWifi a, RedWifi b)
        {
            if (a.Conectada != b.Conectada) return a.Conectada ? -1 : 1;
            return b.Senal.CompareTo(a.Senal);
        });
        return redes;
    }

    private static RedWifi LeerRed(IntPtr p)
    {
        RedWifi red = new RedWifi();
        red.Perfil = Marshal.PtrToStringUni(p);
        int largo = Math.Min(Marshal.ReadInt32(p, 512), 32);
        red.SsidBytes = new byte[largo];
        Marshal.Copy(new IntPtr(p.ToInt64() + 516), red.SsidBytes, 0, largo);
        red.Ssid = Encoding.UTF8.GetString(red.SsidBytes);
        red.Senal = Marshal.ReadInt32(p, 604);
        red.Segura = Marshal.ReadInt32(p, 608) != 0;
        red.Autenticacion = Marshal.ReadInt32(p, 612);
        red.Cifrado = Marshal.ReadInt32(p, 616);
        red.Conectada = (Marshal.ReadInt32(p, 620) & FLAG_CONECTADA) != 0;
        return red;
    }

    // Conecta a la red. Si se indica contraseña (o la red no tiene perfil guardado),
    // se crea/actualiza el perfil. Devuelve null si el pedido se envió, o un mensaje de error.
    public static string Conectar(RedWifi red, string contrasena)
    {
        IntPtr cliente = Abrir();
        try
        {
            List<Guid> interfaces = Interfaces(cliente);
            if (interfaces.Count == 0) return "No se encontró un adaptador Wi-Fi.";
            Guid iface = interfaces[0];

            string perfil = red.Perfil;
            if (!red.TienePerfil || !String.IsNullOrEmpty(contrasena))
            {
                string xml;
                string error = CrearXmlPerfil(red, contrasena, out xml);
                if (error != null) return error;

                uint motivo;
                uint r = WlanSetProfile(cliente, ref iface, 0, xml, null, true, IntPtr.Zero, out motivo);
                if (r == ERROR_ACCESS_DENIED)
                    r = WlanSetProfile(cliente, ref iface, WLAN_PROFILE_USER, xml, null, true, IntPtr.Zero, out motivo);
                if (r != 0)
                    return "No se pudo guardar la red (código " + r + ", motivo " + motivo + ").";
                perfil = red.Ssid;
            }

            WLAN_CONNECTION_PARAMETERS parametros = new WLAN_CONNECTION_PARAMETERS();
            parametros.wlanConnectionMode = 0;  // wlan_connection_mode_profile
            parametros.strProfile = perfil;
            parametros.dot11BssType = 1;        // infraestructura
            uint resultado = WlanConnect(cliente, ref iface, ref parametros, IntPtr.Zero);
            if (resultado != 0) return "No se pudo conectar (código " + resultado + ").";
            return null;
        }
        finally { WlanCloseHandle(cliente, IntPtr.Zero); }
    }

    private static string CrearXmlPerfil(RedWifi red, string contrasena, out string xml)
    {
        xml = null;
        string autenticacion;
        string cifrado = (red.Cifrado == 2) ? "TKIP" : "AES";
        switch (red.Autenticacion)
        {
            case AUTH_OPEN:
                if (red.Segura) return "Este tipo de red (WEP) no es compatible. Use la configuración de internet.";
                autenticacion = "open";
                cifrado = "none";
                break;
            case AUTH_WPA_PSK: autenticacion = "WPAPSK"; break;
            case AUTH_RSNA_PSK: autenticacion = "WPA2PSK"; break;
            case AUTH_WPA3_SAE: autenticacion = "WPA3SAE"; cifrado = "AES"; break;
            default:
                return "Esta red requiere usuario y contraseña empresarial. Use la configuración de internet.";
        }

        bool abierta = autenticacion == "open";
        if (!abierta && String.IsNullOrEmpty(contrasena)) return "Escriba la contraseña de la red.";

        StringBuilder hex = new StringBuilder();
        foreach (byte b in red.SsidBytes) hex.Append(b.ToString("X2"));
        string nombre = SecurityElement.Escape(red.Ssid);

        StringBuilder sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\"?>");
        sb.Append("<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\">");
        sb.Append("<name>").Append(nombre).Append("</name>");
        sb.Append("<SSIDConfig><SSID><hex>").Append(hex).Append("</hex><name>").Append(nombre).Append("</name></SSID></SSIDConfig>");
        sb.Append("<connectionType>ESS</connectionType><connectionMode>auto</connectionMode>");
        sb.Append("<MSM><security><authEncryption>");
        sb.Append("<authentication>").Append(autenticacion).Append("</authentication>");
        sb.Append("<encryption>").Append(cifrado).Append("</encryption>");
        sb.Append("<useOneX>false</useOneX></authEncryption>");
        if (!abierta)
        {
            sb.Append("<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>");
            sb.Append(SecurityElement.Escape(contrasena));
            sb.Append("</keyMaterial></sharedKey>");
        }
        sb.Append("</security></MSM></WLANProfile>");
        xml = sb.ToString();
        return null;
    }
}
