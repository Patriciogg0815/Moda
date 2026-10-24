# Monitor de Red de Casa para Android

Versión para teléfonos del [Monitor de Red de Windows](../MonitorRed/README.md): muestra los equipos
conectados al Wi-Fi de la casa y **avisa con una notificación cuando se conecta un equipo nuevo o cuando uno
se desconecta**. Kotlin + Jetpack Compose, Android 8 o más nuevo. Paquete: `lat.garridoitsolutions.monitorred`.

## Qué hace

- **Lista de equipos**: IP, nombre que anuncia en la red (mDNS, NetBIOS, DNS del router o UPnP), tipo
  estimado (las mismas reglas que Windows), en línea o desconectado y cuándo se vio. Insignias **Nuevo**,
  **Router** y **Este teléfono**. Se le puede poner nombre y tipo a cada equipo.
- **Alertas** (Ajustes → Alertas): equipo nuevo, equipo desconectado y "solo los que tienen nombre". Mismas
  reglas que Windows: la desconexión se avisa cuando el equipo falta en **2 revisiones seguidas**, y nunca
  si cambió la red o el router no respondió. Al tocar la notificación se abre ese equipo.
- **Cada cuánto revisa**: con la app abierta cada 1, 2 o 5 minutos; con la app cerrada, con WorkManager
  cada 15 minutos (el mínimo que permite Android) y solo con Wi-Fi.
- **Consumo**: el total de la casa por UPnP (si el router lo informa) y el de este teléfono.

## Lo que Android no permite (y la versión de Windows sí)

Desde Android 10 las apps no pueden leer la **dirección MAC** de los otros equipos. Por eso:

- No hay fabricante por MAC. Cada equipo se reconoce por su identificador UPnP o su nombre en la red, y
  si no anuncia nada, por su IP (`Round.strongId` y `Round.resolveKey`). Si un día no dice su nombre pero
  sigue en la misma IP, se reconoce igual. Si antes se conocía solo por la IP y luego dice su nombre, se
  conserva el nombre que le puso el usuario.
- No hay consumo por equipo: interceptar el tráfico requiere root y Google Play no lo aceptaría.

## Cómo escanea (`net/Scanner.kt`)

1. Red Wi-Fi actual con `ConnectivityManager` (sin permiso de ubicación). Las redes más grandes que /22
   se escanean solo en la /24 del teléfono, como en Windows.
2. Barrido en paralelo: ping (`isReachable`) y, si no contesta, conexión TCP a puertos comunes. Un
   "conexión rechazada" también prueba que el equipo existe.
3. Tabla ARP (solo funciona en Android 9 o anterior; da la MAC).
4. UPnP/SSDP (con `MulticastLock`) para TVs, consolas, parlantes y el router, con su nombre y modelo.
5. Nombres: DNS inverso del router (máx. 2,5 s), NetBIOS y mDNS directo al equipo.

## Compilar y probar

GitHub Actions (`.github/workflows/monitor-red-android.yml`) en cada cambio:

1. Pruebas (`app/src/test`): reglas de alertas, reconocimiento de equipos, lectura de NetBIOS/mDNS/UPnP,
   guardado, y las **capturas para Google Play** (`CapturasTest`, con Robolectric + Roborazzi, 1080 × 1920).
2. Compila el **APK de prueba** (artifact `MonitorRed-Android-1.0.N`) y el **.aab** para Play.
3. Arma el **kit para Google Play** (artifact `GooglePlay-MonitorRed-1.0.N`): `.aab`, capturas, ícono de
   512, gráfico de 1024 × 500, la ficha (`play/FICHA-PLAY.md`) y la política de privacidad.
4. Instala el APK en un **emulador** de Android 15, lo abre, espera el escaneo y revisa que no se cierre
   (`prueba-emulador.sh`; captura y registro en el artifact `emulador-monitor-red`).

En una PC: `./gradlew testDebugUnitTest -Proborazzi.test.record=true assembleDebug` (necesita JDK 17 y el
SDK de Android 36). Las capturas quedan en `app/build/capturas-play/`.

### Instalar el APK de prueba en el teléfono

Descarga el artifact `MonitorRed-Android-1.0.N`, pasa el `.apk` al teléfono y ábrelo. Android pide permitir
"Instalar apps desconocidas" para el administrador de archivos: **Configuración → Permitir de esta fuente**.
Está firmado con una clave de prueba (`app/prueba.keystore`, pública a propósito), así que cada APK nuevo
se instala encima del anterior. No sirve para Google Play.

## Firma para Google Play (clave de subida)

Google Play exige que el `.aab` esté firmado con la **clave de subida** de la cuenta. Esa clave es secreta:
**no se sube al repositorio** (es público). Hay 2 formas (las hace Claude de escritorio en la PC):

- **A. En la PC:** firmar el `.aab` del kit con la clave de subida que ya se usa para las otras apps:
  ```
  jarsigner -keystore <clave-de-subida.jks> -signedjar MonitorRed-firmado.aab MonitorRed-1.0.N.aab <alias>
  ```
- **B. En GitHub (automático):** en el repo **Settings → Secrets and variables → Actions → New repository
  secret**, crear: `MONITORRED_KEYSTORE_BASE64` (el `.jks` en base64), `MONITORRED_KEYSTORE_PASSWORD`,
  `MONITORRED_KEY_ALIAS` y `MONITORRED_KEY_PASSWORD`. Desde ahí el `.aab` del kit sale firmado.

La primera vez, Play Console ofrece **Firma de apps de Google Play**: Google guarda la clave de firma y la
clave de subida sirve solo para subir versiones.

## Publicar

Los pasos de Play Console, con los textos para copiar, están en [`play/FICHA-PLAY.md`](play/FICHA-PLAY.md).
La política de privacidad (`play/monitorred-privacidad.html`) se publica en
`https://garridoitsolutions.lat/monitorred-privacidad` desde la PC (Claude de escritorio).

## Pendiente

- Publicidad con AdMob (como QuéVeo): hace falta crear la app y los bloques en AdMob, y el formulario de
  consentimiento (UMP).
- Conectores de routers (como el modo 1 de Windows) para ver el consumo por equipo con la clave del router.
