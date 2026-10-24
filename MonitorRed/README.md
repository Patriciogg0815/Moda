# Monitor de Red para Windows

Aplicación para **ver todos los equipos conectados a la red de la casa**: computadoras, teléfonos, TVs,
consolas, parlantes, impresoras, cámaras y electrodomésticos inteligentes. Al abrirla escanea la red sola,
sin configurar el router ni instalar nada, y funciona con cualquier marca de router.

> Estado: prototipo. El escáner de equipos funciona; la medición de consumo por equipo está preparada
> como 4 modos intercambiables, que por ahora solo detectan si están disponibles (ver más abajo).

## Qué muestra

Por cada equipo:

- **Nombre**: el que tú le pongas (se recuerda por su MAC) o uno automático: el nombre que anuncia por
  UPnP (por ejemplo "[TV] Samsung Q60 Series"), por mDNS ("iPhone-de-Ana"), NetBIOS ("LAPTOP-JUAN") o DNS.
- **Tipo e ícono estimados**: router, computadora, laptop, teléfono, tablet, TV, consola, parlante,
  impresora, cámara, hogar inteligente, electrodoméstico, NAS o equipo de red. El detalle explica en qué se
  basó la estimación y puedes corregirla a mano.
- **IP, MAC y fabricante** de la tarjeta de red (base del registro público de la IEEE incluida en el .exe,
  funciona sin internet). Si el equipo usa una **MAC privada** (aleatoria, típico de teléfonos), se avisa.
- **Estado**: en línea con el tiempo de respuesta, o desconectado y cuándo se vio por última vez.
- Insignias **Router**, **Este equipo** y **Nuevo** (equipo que nunca se había visto en la red).

También permite buscar, filtrar por tipo, mostrar los equipos desconectados y **exportar la lista a Excel**.

## Descargar y usar

- **Versión de prueba de una rama:** pestaña **Actions** → ejecución "Monitor de Red" → sección
  **Artifacts** → `MonitorRed-1.0.N`.
- **Versión publicada:** al actualizar `main` se publica en **Releases** con el tag `monitor-red-v1.0.N`.

Ábrelo con doble clic. No necesita permisos de administrador. Como el `.exe` no está firmado,
Windows puede mostrar "Windows protegió su PC": elige **Más información → Ejecutar de todas formas**.
La primera vez Windows puede preguntar si la app puede usar la red: acepta para **redes privadas**.

Requisitos: Windows 10 u 11, conectado al Wi-Fi o al cable de la casa.

## Cómo escanea

Todo ocurre dentro de la red local; los datos de la red no se envían a internet.

1. Elige la red del equipo (la que tiene router; descarta adaptadores virtuales y VPN). Redes de hasta
   1022 equipos (/22) se escanean completas; las más grandes, solo la /24 del propio equipo.
2. **Barrido en paralelo** (96 hilos): ping y una consulta **ARP** (`SendARP`) a cada IP. ARP encuentra
   también los equipos que no responden al ping, como muchos teléfonos. Luego lee la tabla ARP de Windows.
3. **Nombres**: DNS inverso (el router suele conocer los nombres), consulta **NetBIOS** (Windows, NAS,
   impresoras) y **mDNS** unicast (Apple, Android, Chromecast, dispositivos inteligentes).
4. **UPnP/SSDP**: TVs, consolas, parlantes y el router se describen solos (nombre, fabricante, modelo).
   El router además dice si informa el tráfico total por UPnP (modo de medición 2).

Un escaneo de una red /24 suele tardar menos de medio minuto; la lista se va llenando mientras tanto.

## Modos de medición de consumo

En **Ajustes** se elige el modo, o **Automático** (recomendado), que al abrir usa el mejor disponible:

| # | Modo | Mide | Necesita | Estado |
|---|---|---|---|---|
| 1 | API del router | Por equipo | Marca compatible, usuario y clave del router | Detecta la marca del router; aún no hay conectores |
| 2 | Total por UPnP | Solo el total | Router con UPnP activado | Detecta si el router lo ofrece |
| 3 | Interceptar el tráfico (avanzado) | Por equipo | Permiso explícito, administrador y Npcap | Detecta los requisitos; no intercepta nada aún |
| 4 | Agente en cada equipo | Por equipo | Instalar el agente en cada PC/teléfono | Pendiente (el agente no existe todavía) |

Orden de Automático: 1 → 4 → 3 (solo si lo permitiste) → 2.

La clave del router se guarda cifrada con DPAPI (solo tu usuario de Windows puede leerla).
La **edición para la Microsoft Store** (`Crear-EXE.ps1 -EdicionStore`) no incluye el modo 3.

### Agregar o completar un modo

Cada modo es una entrada de `$script:MeasurementModes` en `MonitorRed.ps1` con la misma forma:

```powershell
@{
    Id = 'Upnp'; Number = 2; Priority = 4; Name = 'Total por UPnP'; Scope = 'Solo total'
    Description = '...'; Warning = ''; RequiresConsent = $false; Implemented = $false
    Test = { param($Ctx) @{ Available = $true; Reason = 'texto para el usuario' } }
    Read = { param($Ctx) @(@{ Key = 'AA:BB:CC:DD:EE:FF'; DownBps = 0; UpBps = 0 }) }   # Key = MAC o 'TOTAL'
}
```

`$Ctx` trae la red, el escaneo (`Session.InternetGateways` tiene la URL de control UPnP del router),
los ajustes, la lista de equipos y si la app corre como administrador. Para el modo 1, cada marca es un
conector en `$script:RouterConnectors` (`Brand`, `Match`, `Login`, `ReadUsage`).

## Publicidad y donaciones

La app es gratis y se mantiene con dos cosas:

- **Banner de publicidad** de 728x90 en la parte de abajo de la ventana. Es la página
  [`web/app-banner.html`](web/app-banner.html) con un banner de **Adsterra**, mostrada con **WebView2** (el
  navegador Edge incrustado de Windows). La página debe estar publicada en el sitio aprobado en Adsterra:
  `https://convertir-ec.netlify.app/app-banner.html` (`$script:AdPageUrl`).
  - Si la página no carga (sin internet, página no publicada, falta WebView2), la franja se oculta y la app
    funciona igual. Si ya había cargado WebView2, lo vuelve a intentar cada 5 minutos.
  - Un clic en el anuncio se abre en el navegador del usuario. Las ventanas que el anuncio abra solo (sin
    clic) se bloquean, y no se usan Direct Link ni Social Bar (la Microsoft Store rechaza anuncios que abren
    ventanas solos).
  - El banner no recibe ningún dato de la app. Sus cookies quedan en `%LOCALAPPDATA%\MonitorRed\Navegador`.
  - Las DLL de WebView2 (paquete oficial de Microsoft en NuGet, versión `$script:WebView2Version`) las prepara
    [`Preparar-WebView2.ps1`](Preparar-WebView2.ps1), que comprueba su huella SHA-256. `Crear-EXE.ps1` las
    incrusta en el `.exe`, y la app las extrae una vez en `%LOCALAPPDATA%\MonitorRed\WebView2\<versión>`.
  - Con la variable de entorno `MONITORRED_PRUEBA=1` (la usa GitHub Actions) no se cargan anuncios reales,
    para no generar impresiones inválidas.
  - ⚠️ No hagas clic en tus propios anuncios: Adsterra lo cuenta como fraude y puede cerrar la cuenta.
- **Botón "Apoyar a la app"** arriba a la derecha: abre https://ko-fi.com/garridoitsolutions
  (`$script:SupportUrl`).

## Datos que guarda

En `%APPDATA%\MonitorRed\`:

- `dispositivos.json`: equipos vistos (por MAC), nombres y tipos que elegiste, primera y última vez vistos.
- `ajustes.json`: modo de medición, datos del router (clave cifrada) y preferencias.

## Para desarrolladores

- Código: [`MonitorRed.ps1`](MonitorRed.ps1) (PowerShell 5.1 + WPF; el escáner está en C# dentro del mismo
  archivo para que sea rápido y en paralelo). Para probarlo sin compilar: clic derecho → **Ejecutar con PowerShell**.
- Compilar: `powershell -ExecutionPolicy Bypass -File .\MonitorRed\Crear-EXE.ps1` (descarga la base de
  fabricantes y WebView2, los incrusta y genera `MonitorRed.exe` con [ps2exe](https://github.com/MScholtes/PS2EXE)).
- Para ver el banner sin compilar: `.\MonitorRed\Preparar-WebView2.ps1 -Destino $env:TEMP\wv2.zip -Carpeta .\MonitorRed\webview2`
  (la carpeta `webview2` junto al script no se sube a GitHub).
- Pruebas: [`.github/scripts/Probar-MonitorRed.ps1`](../.github/scripts/Probar-MonitorRed.ps1) prueba la
  lógica en cualquier sistema y la ventana en Windows (con capturas). El workflow
  [`monitor-red.yml`](../.github/workflows/monitor-red.yml) la ejecuta, hace un escaneo real y compila.

Línea de comandos:

```powershell
# Escanear y mostrar la tabla (o -Json para JSON)
powershell -ExecutionPolicy Bypass -File .\MonitorRed\MonitorRed.ps1 -Escanear

# Generar la base de fabricantes por MAC
powershell -ExecutionPolicy Bypass -File .\MonitorRed\MonitorRed.ps1 -GenerarFabricantes .\fabricantes.gz
```

## Limitaciones

- Los teléfonos con **MAC privada** pueden aparecer como equipo nuevo si cambian de MAC (por ejemplo, al
  "olvidar" la red). El nombre que les pongas se asocia a la MAC.
- Equipos dormidos (TVs en espera, teléfonos con la pantalla apagada) a veces no responden; aparecen al
  escanear de nuevo.
- Algunos routers responden ARP por todas las IPs con su propia MAC (proxy ARP), y los repetidores Wi-Fi
  pueden mostrar su MAC en lugar de la de los equipos conectados a ellos. Cuando una MAC aparece en varias
  IPs, la app descarta las que no responden al ping y recuerda las demás por su IP.
- El tipo es una estimación: se basa en el nombre, UPnP y el fabricante de la tarjeta de red.
