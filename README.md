# Kiosko de telemonitoreo para Windows 10

Convierte un equipo con Windows 10 en un kiosko que muestra solo la página de
telemonitoreo en Microsoft Edge, a pantalla completa.

- **No toca el antivirus.** No desactiva Microsoft Defender (ni otro antivirus), no
  agrega exclusiones y no modifica Windows Update, el firewall ni SmartScreen. El
  instalador solo *muestra* el estado del antivirus.
- **Sin internet → configuración de red.** Si se pierde la conexión, el kiosko cierra el
  navegador, muestra un aviso y abre la configuración de red de Windows. Cuando vuelve
  la conexión, cierra la configuración y vuelve a abrir el telemonitoreo solo.
- Funciona en **Windows 10 Pro**, Enterprise y Education (no necesita Shell Launcher ni
  Acceso asignado).

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `instalar-kiosko.ps1` | Configura el equipo como kiosko (ejecutar como administrador). |
| `desinstalar-kiosko.ps1` | Quita el modo kiosko. |
| `kiosko.ps1` | El programa del kiosko; reemplaza al Escritorio para el usuario kiosko. |
| `comun.ps1` | Funciones compartidas por el instalador y el desinstalador. |
| `config.ejemplo.json` | Configuración por defecto. |

## Instalación

1. Copie la carpeta al equipo (por ejemplo a `C:\Instalador-Kiosko`).
2. Abra **PowerShell como administrador** y ejecute:

   ```powershell
   cd C:\Instalador-Kiosko
   Set-ExecutionPolicy -Scope Process Bypass
   .\instalar-kiosko.ps1 -Url "https://su-servidor-de-telemonitoreo"
   ```

3. Reinicie el equipo.

Opciones del instalador:

| Parámetro | Descripción |
|---|---|
| `-Url` | Página que muestra el kiosko (obligatorio). |
| `-Usuario` | Nombre del usuario local del kiosko (por defecto `kiosko`). |
| `-Titulo` | Texto que se muestra en la pantalla de aviso. |
| `-RutaNavegador` | Ruta de otro navegador (por defecto se usa Microsoft Edge). |
| `-SinInicioAutomatico` | No iniciar sesión automáticamente con el usuario kiosko. |
| `-PermitirSuspension` | No desactivar la suspensión ni el apagado de pantalla. |
| `-RestringirConfiguracion` | En la app Configuración mostrar solo las páginas de red. **Afecta a todos los usuarios del equipo.** |

## Qué hace el instalador

1. Muestra el estado del antivirus (solo lectura).
2. Copia el kiosko a `C:\Program Files\KioskoTelemonitoreo` (el usuario kiosko solo puede leerlo).
3. Crea un usuario local **estándar** (nunca administrador) con una contraseña aleatoria.
4. Solo para ese usuario:
   - reemplaza el Escritorio (`explorer.exe`) por `kiosko.ps1`;
   - desactiva el Administrador de tareas, el bloqueo de pantalla y el cambio de contraseña.
5. Políticas de Edge: oculta el asistente de primer inicio y desactiva los procesos en
   segundo plano (no se toca SmartScreen).
6. Desactiva la suspensión con el equipo enchufado.
7. Configura el inicio de sesión automático. La contraseña se guarda como secreto LSA
   (igual que la herramienta Autologon de Sysinternals), no en texto plano en el registro.

Los administradores siguen teniendo el escritorio normal.

## Cómo funciona el kiosko

- Abre Edge con `--kiosk <URL> --edge-kiosk-type=fullscreen`. Si alguien lo cierra, se
  vuelve a abrir en unos segundos.
- Cada 5 segundos comprueba la conexión a internet (pide
  `http://www.msftconnecttest.com/connecttest.txt`, la misma URL que usa Windows).
- Tras 3 fallos seguidos (~15 s, para no reaccionar a cortes breves):
  - cierra el navegador;
  - muestra *"No hay conexión a internet"* con los botones **Abrir configuración de
    internet**, **Ver redes Wi-Fi disponibles** y **Reintentar ahora**;
  - abre automáticamente la configuración de red de Windows (página Wi-Fi si el equipo
    tiene Wi-Fi; si no, Estado de red). Si la app Configuración no abre, usa el panel
    clásico *Conexiones de red*. Si la cierran y sigue sin internet, se vuelve a abrir
    al minuto.
- Al volver la conexión cierra la configuración y vuelve a abrir el telemonitoreo.
- Un portal cautivo (wifi de hotel/hospital con inicio de sesión) cuenta como conectado:
  se abre el navegador para que puedan iniciar sesión en la red.

> **Wi-Fi:** en Windows 10 la lista de redes Wi-Fi es parte de la barra de tareas, que no
> existe en el kiosko. El botón **Ver redes Wi-Fi disponibles** inicia el Explorador solo
> mientras no hay conexión para mostrar esa lista, y lo cierra cuando vuelve internet.

Registro de eventos: `C:\Users\kiosko\AppData\Local\Kiosko\kiosko.log`.

## Configuración

`C:\Program Files\KioskoTelemonitoreo\config.json` (se puede editar como administrador;
los cambios se aplican al próximo inicio de sesión):

| Clave | Por defecto | Descripción |
|---|---|---|
| `Url` | — | Página del telemonitoreo. |
| `Titulo` | `Telemonitoreo` | Título de la pantalla de aviso. |
| `RutaNavegador` | *(Edge)* | Ruta de otro navegador. |
| `ArgumentosNavegador` | modo kiosko de Edge | `{URL}` se reemplaza por la URL. |
| `UrlsVerificacion` | Microsoft y Google | Se considera conectado si responde cualquiera. |
| `IntervaloVerificacionSeg` | `5` | Cada cuánto se comprueba la conexión. |
| `TimeoutVerificacionSeg` | `4` | Tiempo máximo de cada comprobación. |
| `FallosParaSinConexion` | `3` | Fallos seguidos para considerar que no hay internet. |
| `PaginaConfiguracionRed` | `auto` | Página a abrir, p. ej. `ms-settings:network-wifi`. |
| `ReabrirConfiguracionSeg` | `60` | Reabrir la configuración si la cierran sin conectarse. |

**Sesión del navegador:** el modo `--kiosk` de Edge siempre usa una ventana InPrivate
(no guarda cookies ni sesión al reiniciar). Si el telemonitoreo necesita recordar el
inicio de sesión, use por ejemplo:

```json
"ArgumentosNavegador": ["--app={URL}", "--start-fullscreen", "--no-first-run"]
```

## Administrar el equipo / salir del kiosko

1. Presione **Ctrl+Alt+Supr** → **Cerrar sesión**.
2. Mantenga presionada **Shift** mientras vuelve la pantalla de inicio de sesión para
   que no entre de nuevo automáticamente.
3. Inicie sesión con una cuenta de **administrador**.

La pantalla del kiosko también tiene un botón **Apagar equipo**.

## Desinstalar

En PowerShell como administrador:

```powershell
.\desinstalar-kiosko.ps1                  # quita el kiosko, conserva el usuario
.\desinstalar-kiosko.ps1 -EliminarUsuario # también borra el usuario y su perfil
```

## Antivirus: detalles

- Defender (u otro antivirus) sigue funcionando como servicio en todo momento.
- El ícono de *Seguridad de Windows* no aparece en la sesión del kiosko porque no hay
  barra de tareas, pero la protección sigue activa (el instalador y el log del kiosko
  muestran su estado).
- `-ExecutionPolicy Bypass` solo evita la *política de ejecución* de PowerShell; el
  antivirus analiza igual el script (AMSI). Si una directiva de grupo de su organización
  fija la política de ejecución, firme `kiosko.ps1` con un certificado de firma de código.

## Solución de problemas

- **Pantalla negra al iniciar sesión:** PowerShell no pudo ejecutar `kiosko.ps1`. Revise
  el log y que exista `C:\Program Files\KioskoTelemonitoreo\kiosko.ps1`.
- **Edge no abre:** verifique que Microsoft Edge (Chromium) esté instalado o indique
  `RutaNavegador`.
- **El equipo no inicia sesión solo:** vuelva a ejecutar el instalador (regenera la
  contraseña y el inicio automático).
