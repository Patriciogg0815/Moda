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
  **Ya enviada a la Store** (en certificación al 24/10/2026, según el usuario).
- Tiene el botón "Apoyar a la app" (Ko-fi). Se quitó el `.bat`: el `.exe` es la única forma de usarla.
- Historia: rama `claude/ecstatic-sagan-19fwe0`, unida a `main` en el PR #1.

### 2. Monitor de Red (Windows) — en `main` · en la Microsoft Store como "Monitor de Red de Casa"

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
  **Enviado a la Store el 24/10/2026** con el kit 1.0.29 (en certificación, 1 a 3 días hábiles). Si la
  rechazan, el usuario trae el informe de Partner Center para corregirlo. Para actualizar: nuevo envío con
  el `.msix` más reciente del artifact `MicrosoftStore-MonitorRed-1.0.N`.
- **Alertas (24/10/2026, en `main` por el PR #9, versión `monitor-red-v1.0.37`):** mientras la app está abierta (aunque esté
  minimizada) revisa la red cada 1-15 min (por defecto 2) en un escaneo aparte (`Start-WatchScan`, no reinicia
  la medición) y avisa con una notificación de Windows (ícono junto al reloj, `NotifyIcon`): equipo nuevo y
  equipo desconectado. La desconexión se avisa si falta en **2 revisiones seguidas** y nunca si cambió la red
  o el router no respondió (`Get-NetworkAlerts`). Opción "solo los que tienen nombre". Ajustes → Alertas.
  Probado en CI (ventana real). Va en el **próximo** envío a la Store: usar el kit `MicrosoftStore-MonitorRed-1.0.37`
  o uno más nuevo, cuando la Store apruebe el envío en certificación (la ficha ya tiene el texto de novedades).
- Pendiente: conectores de routers (modo 1); seguir vigilando con la ventana cerrada / iniciar con Windows.

### 2b. Monitor de Red para Android — carpeta `MonitorRedAndroid/` (en `main`, PR #9)

Kotlin + Jetpack Compose, minSdk 26, targetSdk 36, paquete `lat.garridoitsolutions.monitorred`. Mismas reglas
de tipos y alertas que Windows. Detalles en `MonitorRedAndroid/README.md`.

- Android no deja leer la MAC: cada equipo se reconoce por UPnP UDN, su nombre (mDNS/NetBIOS/DNS) o su IP
  (`Round.strongId`/`resolveKey`). No hay fabricante por MAC ni consumo por equipo; sí el total de la casa
  (UPnP) y el del teléfono.
- Revisa con la app abierta (1/2/5 min) y en segundo plano con WorkManager (15 min, solo Wi-Fi).
- Sin publicidad todavía (pendiente AdMob + UMP).
- CI `.github/workflows/monitor-red-android.yml`: pruebas, capturas para Play (Robolectric + Roborazzi,
  1080×1920), APK de prueba (firmado con `app/prueba.keystore`, pública a propósito), `.aab`, kit
  `GooglePlay-MonitorRed-1.0.N` y prueba en emulador Android 15.
- Google Play: guía con todos los textos en `MonitorRedAndroid/play/FICHA-PLAY.md`. El `.aab` debe firmarse
  con la **clave de subida** (en la PC, o con los secretos `MONITORRED_KEYSTORE_*` en GitHub). **El repo es
  público: nunca subir claves.** Política: `https://garridoitsolutions.lat/monitorred-privacidad` (la publica
  Claude de escritorio, tanda 2).
- Para compilar en la nube de Claude: Maven Central responde 429; se usa el espejo de Google en
  `~/.gradle/init.d` (solo local) y `-ProbolectricRepo`.

### 2c. Diagnóstico PC (Windows) — en `main` (PR #12, 27/10/2026)

Autodiagnóstico de Windows (idea del usuario: su laptop se calentaba en la mochila porque no hibernaba bien
y tenía programas que no la dejaban suspender). Muestra cada revisión en rojo/amarillo/verde, con botón
"Arreglar" y una **ventana aparte de paso a paso**, y **avisos** junto al reloj.

- Código: `DiagnosticoPC/DiagnosticoPC.ps1` (PowerShell 5.1 + WPF, pide administrador), documentado en
  `DiagnosticoPC/README.md`. Compila con `DiagnosticoPC/Crear-EXE.ps1` (`-EdicionStore` quita "Iniciar con
  Windows", que usa una tarea programada `DiagnosticoPC-Avisos`).
- Revisiones (`$script:Checks`): hibernación/"Hibernar tras" (lee `GetPwrCapabilities` y el plan con
  `PowerReadACValueIndex`), tapa, `powercfg /requests`, reactivaciones de madrugada, plan, inicio rápido,
  temperatura + evento 37, CPU/memoria por programa, arranque (StartupApproved, detecta archivos que
  faltan), dispositivos con error, driver de video, pantallas azules (eventos 1001, Kernel-Power 41 y
  cabecera de minidumps; las **confirma** y da la causa por código), volcados, registro (Shell/Userinit,
  bloqueos, IFEO), `Repair-WindowsImage -CheckHealth`, disco, SMART, batería, antivirus, reinicio.
- Arreglos (`Invoke-Fix`): piden confirmación, crean punto de restauración y guardan cómo deshacer en
  `%APPDATA%\DiagnosticoPC\cambios.json` ("Herramientas y cambios" → Deshacer).
- CI: `.github/workflows/diagnostico-pc.yml` + `.github/scripts/Probar-DiagnosticoPC.ps1` (lógica, análisis
  real del runner, capturas con una laptop HP de ejemplo usando la lógica real con datos simulados).
  `DIAGNOSTICOPC_PRUEBA=1` = modo prueba. En `main` publica el tag `diagnostico-pc-v1.0.N`.
- Store: `DiagnosticoPC/store/` con ícono/logos/arte **propios** (índigo, laptop con pulso y 3 puntos de
  colores; el usuario pidió que no se repitan imágenes de otras apps), privacidad y `FICHA-TIENDA.md` con
  todos los textos. Kit: artifact `MicrosoftStore-DiagnosticoPC-1.0.N`. Nombre **reservado** el 27/10/2026:
  "Diagnóstico PC", identidad `GarridoitSolutions.DiagnsticoPC` (sin la «ó», así la generó Partner Center; PFN
  `GarridoitSolutions.DiagnsticoPC_qketwn0rzx7t0`), ya en `store/identidad.json`: sirve el kit 1.0.15 o más nuevo.
  Política de privacidad ya publicada en GitHub Pages. El usuario está haciendo el envío en Partner Center
  (27/10/2026).
- Limitación conocida: no identifica el driver exacto de una pantalla azul (necesitaría WinDbg); da la
  causa por el código del error.
- **Prueba del usuario en su PC (24/10/2026, v1.0.9, HP ZBook Power 15.6 G10, Windows 11 Pro 26H2)**: resultado
  real: 6 pantallas azules en 30 días, archivos de Windows dañados (reparables), 21 programas en el arranque,
  2 apagones de golpe. Encontró 4 problemas, **corregidos el 27/10/2026** (rama, ejecución 12 de
  `diagnostico-pc.yml` en verde; falta que el usuario vuelva a probar):
  1. "Reparar archivos de Windows" no mostraba si avanzaba: ahora `Invoke-LongExternal` + la clase C#
     `LiveProcess` leen la salida de DISM/SFC mientras corren y la ventana muestra porcentaje, tiempo
     ("Lleva 9 min 24 s · sigue trabajando"), un aviso si el porcentaje no cambia en 3 min (es normal) y el
     botón **Cancelar** (`Request-Cancel`, mata también los subprocesos con `taskkill /T`). Los códigos de
     error de DISM/wusa se explican (`Get-ExitCodeText`). Vale para todo arreglo con `Long = $true`.
  5. (27/10/2026, ejecución 13) El paso «Creando un punto de restauración» también se quedaba sin señales:
     ahora muestra «Lleva X · sigue trabajando», a los 45 s explica que Windows puede tardar, y tiene el botón
     **Saltar este paso** («Dejar de esperar» en Herramientas). `Invoke-Background -Cancelable` deja de
     esperar al instante (abandona el runspace); lo usan también los arreglos largos.
  2. "596523 horas" para hibernar: valores ≥ 30 días (`$script:NeverSeconds`) se tratan como "Nunca".
  3. Driver de video: solo se revisan adaptadores `PCI\` (se ignora "MS Idd Device"); en VM, todos.
  4. "HP HP ZBook": `Remove-BrandPrefix` quita la marca del modelo.
- **Desinstalar actualizaciones de Windows (hecho el 27/10/2026)**: revisión `Test-WindowsUpdates` (id
  `actualizaciones`, área Sistema).
  - Lista: `Get-HotFix` + historial de Windows Update (COM `Microsoft.Update.Session`). Cada una con
    "Desinstalar" y "Ver en Microsoft"; la pila de servicio no se ofrece desinstalar.
  - Desinstalar (`desinstalar-actualizacion`, largo, con punto de restauración): `wusa /uninstall`; si falla
    (acumulativa de Windows 11), `Find-UpdatePackage` + `DISM /Remove-Package`. Pide reiniciar. No se puede
    "deshacer" desde la app (se reinstala con Windows Update).
  - `pausar-actualizaciones`: pausa Windows Update 2 semanas (`HKLM\...\WindowsUpdate\UX\Settings`,
    lo mismo que hace Configuración); se puede deshacer.
  - Qué dice Microsoft: `Get-KbStatus` lee `https://support.microsoft.com/en-us/help/<KB>` (sección "Known
    issues in this update") de las 3 más recientes y de la sospechosa: sin problemas / reconoce problemas /
    menciona desinstalarla. Si la página cambia de formato devuelve `$null` y no avisa nada. **No** se lee
    Windows release health (pendiente si hiciera falta).
  - `Find-SuspectUpdate`: la actualización instalada hasta 7 días antes de la primera pantalla azul o
    apagón de los últimos 60 días (con al menos 2 fallas). Rojo si además Microsoft reconoce problemas o
    pide desinstalarla; amarillo si solo una de las dos. Siempre aclara que es una sugerencia.
  - La app ahora se conecta a internet (solo a support.microsoft.com): privacidad, ficha y manifiesto
    (`internetClient`) actualizados. Captura nueva `8-actualizaciones.png` en el kit de la Store.

### 3. QuéVeo (Android) — **no está en `main`**

Recomienda películas y series y muestra en qué plataforma verlas (TMDB + JustWatch). Antes se llamaba "Moda".

> **Versión vigente: la de la PC del usuario** (Claude de escritorio), en `C:\pelis`: applicationId `com.queveo`,
> v1.7 (versionCode 9), con AdMob, tutorial y el `.aab` para Play. Lo que hay en estas ramas es una versión
> anterior. El usuario **no quiere el nombre "Moda"** en la app, la ficha ni los textos.

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

## Trabajo hecho en Claude de escritorio (PC del usuario)

El usuario también usa **Claude de escritorio** en su PC (Windows). Esa versión tiene su propia memoria en la PC
y publica con la Netlify CLI desde carpetas locales (sin GitHub). Este resumen es del **24/10/2026**; los
detalles (rutas exactas, versiones, cuentas) están en la PC. **No publiques desde aquí los sitios que se
publican desde la PC** (por ejemplo Occultarium): se pisaría lo que está en producción.

### Webs
- **Occultarium** — https://www.occultarium.org (sitio de esoterismo con suscripciones). Carpeta `C:\ocultismo`,
  Netlify `ocultismo`, se publica **solo desde la PC**. Rediseño v2 en producción en todas las secciones
  (Armarium = biblioteca de libros, Tarot, Oráculo con IA, Calendario lunar, Sueños, Alquimia, Numerología,
  Sonidos místicos, Artículos, Símbolos), velas animadas, botón "Escuchar" (voz), modo liviano para equipos
  lentos, español/inglés. Backend: Supabase + n8n; pagos web con PayPal.
  - Apps: Android (Capacitor, cobra con Google Play vía RevenueCat), **Android TV nativa** (Kotlin + Compose)
    e iPhone/iPad (Capacitor; sin Mac: el `.ipa` se compila con GitHub Actions y se instala con Sideloadly).
- **garridoitsolutions.lat** — sitio de la empresa (Netlify CLI desde la PC). Tiene las **políticas de
  privacidad de las apps de Play** y el `app-ads.txt` de AdMob: no romperlos.
  - Desde la web no se puede publicar este sitio: lo que no se pueda hacer aquí se deja a Claude de
    escritorio con instrucciones en `web-garridoitsolutions/INSTRUCCIONES-CLAUDE-ESCRITORIO.md` (en `main`),
    por tandas.
  - Tanda 1 (**publicada** el 24/10/2026): en `/proyectos`, insignias "Coming Soon" de Google Play, App Store
    y Microsoft Store (`/img/badges/`), tarjetas de Monitor de Red de Casa y RespaldoDrivers, marco blanco en
    todas las insignias (`style.css?v=37`).
  - Tanda 2 (pendiente): página `/monitorred-privacidad` y la tarjeta del Monitor con Android + Google Play.
- **ConsultaEC** y **Convertir.ec** — ver arriba. El backend Office↔PDF de Convertir.ec corre en Docker en
  el VPS del usuario (lo instala `setup/convertir-api.sh`).
- **Buzón de sugerencias** (colegio, login con Google del dominio del colegio), **SpeakCoach** (tutor de
  idiomas por voz con IA), **simulador de entrevista de visa de EE. UU.**, **POS / tienda online "Tienda
  Mary"** (VPS, con facturación electrónica SRI).

### Apps Android (Google Play)
- QuéVeo (ver arriba), **CoinID** (identifica monedas con IA; aprobada en producción), **Reloj Mundial**
  (reemplazo de TimeZo, Flutter), **VisaPrep** (simulador de entrevista de visa), **Convertir.ec** (Capacitor
  + AdMob), chat familiar (Flutter + Firebase), Tienda Mary.
- Para Play el entregable es **siempre el `.aab`**. En la PC, **Avast** intercepta TLS y rompe las descargas de
  Gradle: se compila con un truststore que incluye el certificado de Avast.

### Apps Windows
- **AppRescate** — respalda programas instalados + su configuración y genera un paquete restaurable.
  C#/.NET 10, **ya publicada en la Microsoft Store** (misma cuenta de Partner Center), 30 idiomas.
  Se parece a RespaldoDrivers, pero es otra app.

### Cómo trabajar con el usuario (aprendido en escritorio)
- Mostrar primero un borrador (deploy de prueba en Netlify) y publicar en producción solo cuando él lo
  confirma; anotar el deploy anterior para poder volver atrás.
- En diseño le gustan los elementos grandes, sin espacios vacíos, y el texto oscuro, grande y
  fácil de leer. Nada de texto dibujado dentro de las imágenes (todo en HTML para poder traducirlo).

## Mapa de GitHub: dónde está cada cosa

Repositorio principal (público): https://github.com/Patriciogg0815/Moda — para descargar algo hay que tener la
sesión de GitHub iniciada. Los `.exe` y kits de cada compilación están en **Actions → (flujo) → ejecución
más reciente → Artifacts** (duran 90 días); los de `main` también quedan en **Releases**.

| Proyecto | Código | Compilaciones (Actions) | Descargas / estado |
|---|---|---|---|
| RespaldoDrivers (Windows) | [`RespaldoDrivers/`](https://github.com/Patriciogg0815/Moda/tree/main/RespaldoDrivers) + [`store/`](https://github.com/Patriciogg0815/Moda/tree/main/store) | [compilar-exe.yml](https://github.com/Patriciogg0815/Moda/actions/workflows/compilar-exe.yml) | [Releases](https://github.com/Patriciogg0815/Moda/releases) tags `v1.0.N` · enviada a la Store (en certificación) |
| Monitor de Red (Windows) | [`MonitorRed/`](https://github.com/Patriciogg0815/Moda/tree/main/MonitorRed) | [monitor-red.yml](https://github.com/Patriciogg0815/Moda/actions/workflows/monitor-red.yml) | Releases tags `monitor-red-v1.0.N` (última `monitor-red-v1.0.37`) · enviada a la Store |
| Monitor de Red (Android) | [`MonitorRedAndroid/`](https://github.com/Patriciogg0815/Moda/tree/main/MonitorRedAndroid) | [monitor-red-android.yml](https://github.com/Patriciogg0815/Moda/actions/workflows/monitor-red-android.yml) | Artifact `GooglePlay-MonitorRed-1.0.N` · falta firmar y subir a Play |
| **Diagnóstico PC** (Windows) | [`DiagnosticoPC/`](https://github.com/Patriciogg0815/Moda/tree/main/DiagnosticoPC) | [diagnostico-pc.yml](https://github.com/Patriciogg0815/Moda/actions/workflows/diagnostico-pc.yml) | Releases tags `diagnostico-pc-v1.0.N` (primera en `main`: `diagnostico-pc-v1.0.17`) · artifact `MicrosoftStore-DiagnosticoPC-1.0.N` (kit con msix, 8 capturas, logos, arte y ficha; 1.0.15 o más nuevo para la Store) · en envío a la Store |
| Web garridoitsolutions.lat | [`web-garridoitsolutions/`](https://github.com/Patriciogg0815/Moda/tree/main/web-garridoitsolutions) (instrucciones para Claude de escritorio) | — (se publica desde la PC) | Tanda 1 publicada, tanda 2 pendiente |
| QuéVeo (Android, versión vieja) | rama [`claude/lucid-wozniak-0g599n`](https://github.com/Patriciogg0815/Moda/tree/claude/lucid-wozniak-0g599n) | — | La versión vigente está en la PC (`C:\pelis`) |
| Convertir.ec (web) | repo privado https://github.com/Patriciogg0815/convertir-ec | Netlify publica `main` solo | https://convertir-ec.netlify.app/ |
| ConsultaEC (web) | https://github.com/Patriciogg0815/consultaec | Netlify | https://consultaec.netlify.app/ |

Políticas de privacidad publicadas con GitHub Pages desde `main`:
- RespaldoDrivers: https://patriciogg0815.github.io/Moda/store/privacidad.html
- Monitor de Red: https://patriciogg0815.github.io/Moda/MonitorRed/store/privacidad.html
- Diagnóstico PC: https://patriciogg0815.github.io/Moda/DiagnosticoPC/store/privacidad.html

Ramas (al 27/10/2026): `main` tiene todo lo terminado (Diagnóstico PC incluido, PR #12); `claude/lucid-wozniak-0g599n` y `claude/movie-series-recommender-app-unh84n` = QuéVeo viejo;
`claude/project-thread-hfo1sm` y `claude/project-thread-uf9bcg` = versiones viejas del Monitor sin publicidad
(no unir: se decidió mantener la publicidad). Las demás ramas ya están unidas a `main`.

## Pendientes (al 24/10/2026)

1. **Claude de escritorio, tanda 2** de `web-garridoitsolutions/INSTRUCCIONES-CLAUDE-ESCRITORIO.md`: publicar
   `/monitorred-privacidad` y la tarjeta del Monitor con Android (borrador primero).
2. **Google Play – Monitor de Red Android:** firmar el `.aab` del kit `GooglePlay-MonitorRed-1.0.N` con la clave
   de subida (en la PC) y seguir `MonitorRedAndroid/play/FICHA-PLAY.md` en Play Console.
3. **Microsoft Store:** esperar la certificación de Monitor de Red de Casa y RespaldoDrivers; cuando aprueben,
   cambiar sus insignias "Coming Soon" en garridoitsolutions.lat por las de "Disponible" con su enlace, y
   enviar la actualización del Monitor con alertas (kit 1.0.37 o más nuevo).
4. **Diagnóstico PC:** los 4 problemas y la desinstalación de actualizaciones ya están hechos (27/10/2026).
   Nombre reservado, identidad puesta y rama unida a `main` (PR #12, 27/10/2026). Falta: que el usuario pruebe
   la versión nueva en su PC, terminar el envío a la Store (kit 1.0.15 o más nuevo; si la rechazan, traer el
   informe de Partner Center) y agregar la tarjeta de Diagnóstico PC en garridoitsolutions.lat cuando esté en la Store.
5. Ideas para después: AdMob en la app de Android; en Windows, seguir vigilando con la ventana cerrada e
   iniciar con Windows; conectores de routers.

## Publicidad: decisiones

- Para poner Adsterra en una app de Windows: crear una página que tenga solo el banner, en el dominio de
  Netlify ya aprobado (por ejemplo `/banner-app.html`), y mostrarla en un WebView2 abajo de la ventana.
- En apps de escritorio, **solo banners**: nada de Direct Link ni Social Bar, porque la Microsoft Store
  rechaza los anuncios que abren ventanas solos o tapan el contenido. Hay que confirmar con Adsterra que
  permite mostrar sus anuncios dentro de una app.
- **La edición Store del Monitor de Red mantiene el banner de Adsterra** (decisión del usuario, 24/10/2026).
  Se envió así a la Store, y la política y la ficha lo declaran. Por eso se cerraron los PR #5 y #6, que
  quitaban la publicidad. No volver a quitarla salvo que el usuario lo pida o que la certificación lo objete.
- En AdMob, el usuario no debe tocar sus propios anuncios (clics inválidos). Para probar, usar los IDs de
  prueba de Google.

## Convenciones del repositorio

- Apps de Windows: un `.ps1` (PowerShell 5.1 + WPF) → `.exe` con ps2exe → GitHub Actions lo compila,
  prueba la interfaz con capturas y publica. Cada app tiene su `store/` con el MSIX para la Microsoft Store.
- La versión es `1.0.<número de ejecución de Actions>`.
- ps2exe se instala de PowerShell Gallery, que a veces falla (27/10/2026: la 1.0.18 daba 404 y otra vez
  «No repository with the name 'PSGallery'»). Si `Install-Module` falla, los workflows descargan el paquete
  directamente (`api/v2/package/ps2exe`, y si no la 1.0.17) y lo copian a la carpeta de módulos.
- Los `.exe` no están firmados: en el README se explica "Más información → Ejecutar de todas formas".
