# 🍿 Moda · ¿Qué veo hoy?

Una app para **Android** que te **recomienda qué película o serie ver** cuando tienes tantas plataformas que no sabes por dónde empezar. Al estilo de [JustWatch](https://www.justwatch.com/), cada título muestra:

- 🖼️ **Póster** e imagen de fondo
- 📝 **Resumen** breve
- ⭐ **Calificación** (TMDB, con color según qué tan buena es)
- 📺 **En qué plataforma verla** en tu país (Netflix, Prime Video, Disney+, Max…), destacando las que tú tienes
- 🎬 **"En cines"** si es una película reciente que todavía no llega a ninguna plataforma

## Funciones

| Sección | Qué hace |
| --- | --- |
| 🎲 **Recomiéndame** | Eliges película o serie, tu estado de ánimo (reír, adrenalina, intriga, miedo…), la calificación mínima y si quieres **solo títulos de tus plataformas**. Te propone uno destacado y otras 8 opciones; con **"Otra"** pasas a la siguiente. |
| 🔥 **Tendencias** | Lo más visto de la semana. |
| 🎬 **En cines** | Lo que está en cartelera en tu país. |
| 🔎 **Buscar** | Busca cualquier película o serie y mira dónde verla. |
| ♥ **Mi lista** | Lo que guardaste para ver después. |

Con **✓ Ya la vi** y **✕ No me interesa** el título deja de aparecer en las recomendaciones. Al tocar un póster se abre el detalle: duración o temporadas, géneros, tráiler, y dónde verla, separado en suscripción, alquiler y compra.

## 📱 Instalar en Android

La app para Android ya viene compilada en **[`apk/Moda.apk`](apk/Moda.apk)**.

### 1. Guardarla en tu PC (C:\Moda)

Abre **PowerShell** en Windows (tecla Windows → escribe `PowerShell` → Enter) y pega:

```powershell
$u="https://github.com/Patriciogg0815/Moda/archive/refs/heads/claude/movie-series-recommender-app-unh84n.zip"; $z="$env:TEMP\moda.zip"; $t="$env:TEMP\moda-descarga"; Invoke-WebRequest $u -OutFile $z -UseBasicParsing; Expand-Archive $z $t -Force; New-Item -ItemType Directory -Force C:\Moda | Out-Null; Copy-Item "$t\*\*" C:\Moda -Recurse -Force; Remove-Item $z,$t -Recurse -Force; explorer C:\Moda\apk
```

Se crea la carpeta **`C:\Moda`** con todo el proyecto y se abre `C:\Moda\apk`, donde está `Moda.apk`.
Para **actualizar** más adelante: clic derecho en `C:\Moda\scripts\descargar-en-pc.ps1` → *Ejecutar con PowerShell*.

### 2. Pasarla al celular e instalarla

1. Conecta el celular a la PC con el cable USB (modo *Transferencia de archivos*) y copia `C:\Moda\apk\Moda.apk` a la carpeta **Descargas** del celular.
   *(También puedes abrir directamente en el celular: <https://github.com/Patriciogg0815/Moda/raw/claude/movie-series-recommender-app-unh84n/apk/Moda.apk>)*
2. En el celular abre **Archivos → Descargas → Moda.apk**.
3. Android pedirá permiso para **instalar apps desconocidas** de esa aplicación: actívalo.
4. Si aparece *Google Play Protect* ("app no reconocida"), toca **Más detalles → Instalar de todas formas**. Es normal en apps que no vienen de Play Store.
5. Abre **Moda**, entra a **⚙️ Configuración**, pega tu **API Key de TMDB**, elige tu país y tus plataformas.

> La API key, tus plataformas y tus listas se guardan solo en el celular.

Requisitos: Android 7.0 o superior, con conexión a internet.

### ¿Dónde consigo la API key?

Crea una cuenta gratis en [themoviedb.org](https://www.themoviedb.org/signup) y entra a [Ajustes → API](https://www.themoviedb.org/settings/api). Copia la **API Key** (la de 32 caracteres).

## 🛠️ Para desarrolladores

La interfaz es HTML, CSS y JavaScript sin dependencias (carpeta `www/`). [Capacitor](https://capacitorjs.com/) la empaqueta como app nativa de Android (carpeta `android/`). Los datos vienen de la API de [TMDB](https://www.themoviedb.org/), y la disponibilidad en plataformas, de JustWatch.

```bash
npm install
npm test               # tests de la lógica
npm start              # probarla en el navegador: http://localhost:5173
npm run android:build  # compilar apk/Moda.apk (requiere JDK 21 y Android SDK)
npm run android:open   # abrir el proyecto en Android Studio
```

En Windows, la forma más simple de compilar es abrir la carpeta `android/` con **Android Studio** y usar *Build → Build APK(s)*. Antes, ejecuta `npx cap sync android` para copiar los cambios de `www/`.

Las versiones nuevas se firman con la llave del proyecto (`android/app/moda-debug.keystore`). Así se instalan encima de la anterior sin perder tus datos. Esa llave sirve para instalar la app a mano, no para publicarla en Google Play.

## Cómo decide "plataforma" o "cine"

La lógica está en [`www/js/availability.js`](www/js/availability.js):

1. Si está incluida en una **suscripción** (o gratis/con anuncios) en tu país → muestra los logos de las plataformas, con las tuyas primero y marcadas con ✓.
2. Si solo se puede **alquilar o comprar** → "Alquiler / compra".
3. Si es una **película** sin plataformas y está en cartelera, o se estrenó hace menos de 120 días → **🎬 En cines**.
4. Si no hay ninguna de las anteriores → "Sin plataforma en tu país". Así no aparece como "en cines" una película antigua.

## Estructura

```
apk/Moda.apk              App lista para instalar en Android
www/index.html            Interfaz
www/css/styles.css        Estilos (tema oscuro, adaptado a celular)
www/js/app.js             Lógica de la interfaz (incluye el botón "atrás" de Android)
www/js/tmdb.js            Cliente de la API de TMDB
www/js/availability.js    Reglas de disponibilidad (plataforma / alquiler / cine)
www/js/storage.js         Preferencias y listas guardadas en el dispositivo
android/                  Proyecto Android (Capacitor)
scripts/descargar-en-pc.ps1  Descarga/actualiza el proyecto en C:\Moda
test/                     Tests (node --test)
```

## Tests

```bash
npm test
```

## Ideas para seguir

- Calificaciones de IMDb o Rotten Tomatoes (por ejemplo con la API de OMDb)
- Recomendaciones basadas en lo que marcaste como visto ("porque viste…")
- Filtros por año, duración o idioma

---

Datos e imágenes de [TMDB](https://www.themoviedb.org/). Disponibilidad en plataformas por [JustWatch](https://www.justwatch.com/). Este producto usa la API de TMDB pero no está avalado ni certificado por TMDB.
