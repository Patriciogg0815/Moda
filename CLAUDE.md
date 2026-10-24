# Memoria del proyecto (para Claude)

Este archivo resume todo lo diseñado en las conversaciones con Claude. Léelo antes de empezar y
**actualízalo al final de cada sesión** con lo nuevo: apps, ramas, decisiones y pendientes.

## Antes de responder

- El trabajo está repartido en varias ramas `claude/*` que no siempre están unidas a `main`. Antes de
  decir que algo no existe, revisa todas: `git fetch origin && git log --oneline main..origin/<rama>`.
- El usuario escribe en español (Ecuador). Responde, escribe los commits y el texto de las apps en español.
- El usuario no es programador: los pasos deben ser concretos, con los nombres de los botones tal como se ven.

## Dueño y cuentas

- Patricio Garrido, empresa **GarridoitSolutions**. Correo de contacto: patricio.garrido@garridoitsolutions.lat
- Microsoft Partner Center (misma cuenta para todas las apps de Windows):
  - `Publisher`: `CN=97E71BB8-34DD-4461-A440-AFE4AC83ADB3`
  - `PublisherDisplayName`: `GarridoitSolutions`
- Ko-fi (botón "Apoyar a la app"): https://ko-fi.com/garridoitsolutions
- AdMob: cuenta `ca-app-pub-6398797687169342` (se usa en QuéVeo y en la app de Convertir.ec).
- Adsterra: se usa en la web Convertir.ec (ver abajo).

## Proyectos

### 1. RespaldoDrivers (Windows) — en `main`

Respalda los drivers del equipo por categoría y los reinstala después de formatear (usa `DISM` y `pnputil`).

- Código: `RespaldoDrivers/RespaldoDrivers.ps1` (PowerShell 5.1 + WPF), compilado a `.exe` con ps2exe
  (`RespaldoDrivers/Crear-EXE.ps1`). Pide permisos de administrador.
- CI: `.github/workflows/compilar-exe.yml` prueba la ventana (con capturas), compila el `.exe` y el MSIX, y
  en `main` publica en Releases.
- Microsoft Store: carpeta `store/` (manifiesto, íconos, logos de 300/150/71, arte de superhéroe 16:9,
  `privacidad.html`, `FICHA-TIENDA.md`). Identidad: `GarridoitSolutions.RespaldoDrivers`.
- Tiene el botón "Apoyar a la app" (Ko-fi). Se quitó el `.bat`: el `.exe` es la única forma de usarla.
- Historia: rama `claude/ecstatic-sagan-19fwe0`, unida a `main` en el PR #1.

### 2. Monitor de Red (Windows) — rama `claude/busy-turing-ngdllw` (PR #4 hacia `main`)

Muestra los equipos de la red de la casa (nombre, IP, MAC, fabricante, tipo, en línea / nuevo) y cuánto
consume cada uno. Mismo estilo que RespaldoDrivers: PowerShell + WPF, con el escáner en C# dentro del `.ps1`.

- Las dos ramas siguientes ya están unidas en `claude/busy-turing-ngdllw`, junto con la publicidad y el botón de donar.
- **Rama `claude/project-thread-hfo1sm`**: la app (`MonitorRed/`, documentada en `MonitorRed/README.md`),
  el workflow `.github/workflows/monitor-red.yml` y las pruebas en `.github/scripts/Probar-MonitorRed.ps1`.
  - Escaneo: ping + ARP en paralelo, tabla ARP, nombres por DNS inverso, NetBIOS, mDNS y UPnP/SSDP.
    Base de fabricantes de la IEEE incrustada en el `.exe`. Descarta las IPs fantasma de proxy ARP.
  - Nombres puestos por el usuario, recordados por MAC. Exporta a Excel.
    Datos guardados en `%APPDATA%\MonitorRed\`.
  - Consumo, en 4 modos (`$script:MeasurementModes`):
    1. API del router (por equipo): detecta la marca, pero **todavía no hay conectores**.
    2. Total por UPnP (`GetTotalBytes`): **hecho**, se ve siempre en la cabecera.
    3. Interceptar (ARP MITM + Npcap, por equipo): **hecho**. Apagado por defecto, pide consentimiento,
       administrador y Npcap, y restaura la tabla ARP al salir. **No va en la edición Store** (`-EdicionStore`).
    4. Agente en cada equipo: pendiente.
    - El consumo de la propia PC se mide siempre con sus contadores de red.
- **Rama `claude/project-thread-uf9bcg`**: solo `MonitorRed/store/` (ficha de la Store, manifiesto,
  logos, arte, maquetas de capturas, privacidad). Salió de `main` **sin** el código de la app: hay que
  unirla con la rama anterior. En `identidad.json`, `IdentityName` sigue en `PENDIENTE` hasta que se
  reserve el nombre ("Monitor de Red"; alternativas en la ficha).
- **Publicidad y donaciones (hecho):**
  - Banner Adsterra 728x90 abajo de la ventana, en un WebView2 que carga
    `https://convertir-ec.netlify.app/app-banner.html`. El archivo está en `MonitorRed/web/app-banner.html` y
    también está en el repo `convertir-ec` y ya está publicado.
  - Las DLL de WebView2 las prepara `MonitorRed/Preparar-WebView2.ps1` (con huella SHA-256 fijada) y
    `Crear-EXE.ps1` las incrusta.
  - `MONITORRED_PRUEBA=1` evita anuncios reales en CI.
  - Botón "Apoyar a la app" (Ko-fi).
  - Política de privacidad y ficha actualizadas.
- PR #4 unido a `main` (versión publicada `monitor-red-v1.0.16`).
- Microsoft Store: `monitor-red.yml` genera y prueba `MonitorRed.msix`, y arma el artifact
  `MicrosoftStore-MonitorRed-1.0.N` (msix, logos, arte, capturas reales de la edición Store y la ficha).
  Nombre reservado en Partner Center: **Monitor de Red de Casa**, identidad
  `GarridoitSolutions.MonitordeReddeCasa` (PFN `GarridoitSolutions.MonitordeReddeCasa_qketwn0rzx7t0`).
  Ya completa en `MonitorRed/store/identidad.json`: el `.msix` del kit sirve para enviar.
- Pendiente: conectores de routers (modo 1).

### 3. QuéVeo (Android) — **no está en `main`**

Recomienda películas y series y muestra en qué plataforma verlas (TMDB + JustWatch). Antes se llamaba "Moda".

- **Rama `claude/lucid-wozniak-0g599n`** (la más completa; `claude/movie-series-recommender-app-unh84n`
  es una versión anterior).
- HTML/CSS/JS sin dependencias en `www/`, empaquetado con Capacitor (`android/`), appId `app.moda.queveo`.
  APK compilado en `apk/QueVeo.apk`, firmado con `android/app/moda-debug.keystore` para que se instale
  encima de la versión anterior.
- La API key de TMDB está en `www/js/storage.js` (`TMDB_KEY`). No la copies a otros archivos.
- AdMob (`www/js/ads.js`): banner abajo + intersticial al tocar, como máximo uno cada 45 s (no aparece en
  Configuración). App `~5987566028`, banner `/2056059870`, intersticial `/2048321010`.

### 4. Convertir.ec (web + app) — repo privado `Patriciogg0815/convertir-ec`

Sitio de herramientas PDF/imagen: https://convertir-ec.netlify.app/ (proyecto de Netlify `convertir-ec`).
Antes se publicaba con la Netlify CLI desde `C:\convertir` en la PC del usuario. El 24/10/2026 el usuario
subió los archivos a GitHub: son iguales a los publicados.

- `netlify.toml` traía `publish = "C:\\convertir"`, que hacía fallar los deploys en Netlify. Se corrigió a
  `publish = "."` y se agregó `app-banner.html` en el PR #1 de convertir-ec.
- **Netlify ya está conectado al repo** (rama `main`): cada push a `main` se publica solo. La configuración
  sale de `netlify.toml`. `app-banner.html` está publicado y funcionando.
- `setup/convertir-api.sh` instala el backend Office↔PDF (Docker, `convertir-api.duckdns.org:8443`). Hoy
  también se publica en la web (no tiene claves; el token de DuckDNS se pide al ejecutarlo).
- Web: **Adsterra**, con dominios `highrevenueformat.com` y `profitableratecpmnetwork.com`, en `/js/common.js`:
  - Banners en iframe: arriba de 728x90 (computadora) / 320x50 (móvil), abajo de 300x250.
  - Social Bar (`pl31407294.profitableratecpmnetwork.com`).
  - Direct Link: al hacer clic en una herramienta abre una pestaña, como máximo una vez cada 60 s.
- App: Google AdMob, con el mismo esquema que QuéVeo.

### 5. ConsultaEC (web) — repo `Patriciogg0815/consultaec`

Otro sitio: https://consultaec.netlify.app/ (validador de cédula/RUC y calculadoras laborales de Ecuador).
Usa Google AdSense (`pub-6398797687169342`, en `ads.txt`). Es HTML/CSS/JS puro.

## Publicidad: decisiones

- Para poner Adsterra en una app de Windows: crear una página que tenga solo el banner, en el dominio de
  Netlify ya aprobado (por ejemplo `/banner-app.html`), y mostrarla en un WebView2 abajo de la ventana.
- En apps de escritorio, **solo banners**: nada de Direct Link ni Social Bar, porque la Microsoft Store
  rechaza los anuncios que abren ventanas solos o tapan el contenido. Hay que confirmar con Adsterra que
  permite mostrar sus anuncios dentro de una app.
- En AdMob, el usuario no debe tocar sus propios anuncios (clics inválidos). Para probar, usar los IDs de
  prueba de Google.

## Convenciones del repositorio

- Apps de Windows: un `.ps1` (PowerShell 5.1 + WPF) → `.exe` con ps2exe → GitHub Actions lo compila,
  prueba la interfaz con capturas y publica. Cada app tiene su `store/` con el MSIX para la Microsoft Store.
- La versión es `1.0.<número de ejecución de Actions>`.
- Los `.exe` no están firmados: en el README se explica "Más información → Ejecutar de todas formas".
