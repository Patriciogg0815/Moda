# Publicar "Respaldo de Drivers" en la Microsoft Store

Esta carpeta contiene todo lo necesario para la Store:

| Archivo | Para qué sirve |
|---|---|
| `identidad.json` | Datos de tu cuenta de Partner Center (**hay que completarlos**) |
| `AppxManifest.xml` | Plantilla del manifiesto del paquete MSIX |
| `Assets/` | Íconos de la app en todos los tamaños |
| `LogoTienda-300x300.png` | Logo para la ficha de la tienda |
| `privacidad.html` | Política de privacidad (hay que publicarla en una dirección web) |
| `Crear-MSIX.ps1` / `Probar-MSIX.ps1` | Arman y prueban el paquete (GitHub Actions los ejecuta solo) |

GitHub Actions genera el paquete **`RespaldoDrivers.msix`** en cada cambio: pestaña **Actions** →
ejecución "Compilar .exe" → **Artifacts** → `MicrosoftStore-RespaldoDrivers-1.0.N`.

---

## Paso 1 — Reservar el nombre y copiar la identidad

1. Entra a [Partner Center](https://partner.microsoft.com/dashboard/apps-and-games/overview) →
   **Aplicaciones y juegos** → **Nueva aplicación** → **Aplicación MSIX o PWA**.
2. Reserva el nombre **Respaldo de Drivers** (si no está disponible, elige otro y cámbialo también en
   `identidad.json` → `DisplayName`).
3. Ve a **Administración de productos → Identidad del producto** y copia estos tres valores:

   | En Partner Center | En `identidad.json` |
   |---|---|
   | Package/Identity/Name | `IdentityName` |
   | Package/Identity/Publisher (empieza con `CN=`) | `Publisher` |
   | Package/Properties/PublisherDisplayName | `PublisherDisplayName` |

4. Edita `store/identidad.json` en GitHub con esos valores (o envíaselos a Claude) y guarda el cambio.
   GitHub volverá a generar el `.msix` ya con tu identidad.

## Paso 2 — Crear el envío

En la app → **Envíos** → **Iniciar el envío**:

### Precios y disponibilidad
- **Precio:** Gratis (o el que prefieras).
- **Mercados:** todos, o solo los países de habla hispana.

### Propiedades
- **Categoría:** Utilidades y herramientas → subcategoría *Copia de seguridad y administración*.
- **URL de la política de privacidad:** la dirección donde publiques `privacidad.html` (ver Paso 3).
- **Requisitos del sistema:** teclado y mouse.

### Clasificación por edad
Responde el cuestionario IARC: categoría **"Herramienta o utilidad"**, sin violencia, sin compras,
sin comunicación entre usuarios, no comparte la ubicación ni datos personales → resultado esperado **3+ / Para todos**.

### Paquetes
Sube **`RespaldoDrivers.msix`** (del artifact `MicrosoftStore-RespaldoDrivers-1.0.N`).
- Debe estar generado **después** de completar `identidad.json`; si no, Partner Center lo rechaza
  con un error de identidad.
- Familia de dispositivos: solo **Escritorio** (Windows 10 versión 2004 o superior).

### Opciones de envío → Funcionalidades restringidas
Partner Center pedirá justificar los dos permisos especiales. Texto sugerido:

> **runFullTrust:** Respaldo de Drivers es una aplicación de escritorio que usa las herramientas
> integradas de Windows (DISM y pnputil) para listar, exportar e instalar los drivers del equipo.
> Estas herramientas solo están disponibles para aplicaciones de escritorio de plena confianza.
>
> **allowElevation** (el campo admite **500 caracteres como máximo**; el detalle va en las notas para la certificación):
> Backing up and reinstalling drivers (pnputil /export-driver, /add-driver /install, DISM /Online) is only allowed by Windows for administrators; no non-elevated API exists. Elevation uses the standard UAC prompt, approved by the user. The app only calls signed Windows tools, downloads nothing, sends no data, checks each backed-up file's SHA-256 before installing, and writes only to the user-chosen folder, %TEMP% (log) and the Driver Store. Details in Notes.

El 29/10/2026 Microsoft rechazó `allowElevation` porque la justificación anterior era muy corta. Pide
responder: por qué se necesita, qué alternativas se probaron, cómo se limita el acceso, qué protecciones
hay y en qué carpetas escribe la app. Eso está cubierto en las notas para la certificación (abajo).

### Donaciones (Ko-fi)
La app es gratis y tiene un botón opcional "Apoyar a la app" que abre la página de donaciones de Ko-fi en el
navegador. No desbloquea funciones ni vende contenido, así que no necesita las compras de la Store.
En **Propiedades** no marques "contiene compras desde la aplicación".

### Notas para la certificación
Pegar tal cual (en inglés, 1.599 caracteres):

```
allowElevation details: Exporting and installing third-party drivers requires an elevated process (enforced by Windows). Tried: running unelevated (pnputil/DISM return Access denied); packaged APIs (none export/install driver packages); Windows Update (many OEM drivers are no longer published).
Least privilege: standard UAC prompt; if declined the app closes doing nothing. No services, scheduled tasks, startup entries or direct registry edits. Only Microsoft-signed tools (pnputil, DISM). Nothing downloaded or run from the internet.
Safeguards: the SHA-256 of every backed-up file is saved in respaldo.json; before installing, the app re-checks it and refuses any driver whose files were changed, removed or added (shown as "Alterado"). Windows also enforces driver signatures. User picks every driver; firmware/BIOS unchecked by default; warning if the backup is from another PC model; safe install order (chipset first); per-driver result shown. No telemetry; only network action is an optional Ko-fi button that opens the browser.
Assurance: elevation is used only for the pnputil/DISM operations above. Files are written only to the user-selected backup folder (drivers, LEEME.txt, JSON manifest, inventario.csv, log), %TEMP% (log fallback) and the Windows Driver Store via pnputil.
How to test (no account or internet needed): open the app and accept UAC > "Respaldar drivers" > choose a folder (e.g. Desktop) > "Respaldar N drivers". Then Home > "Restaurar drivers" > "Buscar respaldo..." > pick the created folder > "Instalar N drivers". Drivers already installed show as "Sin cambios".
```

## Paso 3 — Política de privacidad

La Store exige una dirección web pública con la política. Opciones:
- **GitHub Pages** (si el repositorio es público): *Settings → Pages → Branch `main`, carpeta `/ (root)`*.
  La dirección será `https://<usuario>.github.io/<repositorio>/store/privacidad.html`.
- **Tu propio sitio web:** sube `privacidad.html` tal cual.

Dirección publicada: https://patriciogg0815.github.io/Moda/store/privacidad.html

## Paso 4 — Ficha de la tienda (Español - México)

**Nombre:** RespaldoDrivers (el nombre reservado en Partner Center)

**Descripción breve**
> Guarda todos los drivers de tu PC organizados por categoría y vuelve a instalarlos después de formatear, sin buscarlos en internet.

**Descripción**
> ¿Formateaste la PC y ahora no encuentras los drivers del WiFi, del audio o del video? Muchas veces el
> fabricante ya no los publica. Respaldo de Drivers los guarda **antes** de formatear y los reinstala
> **después** en pocos clics.
>
> **1. Respaldar (antes de formatear)**
> La aplicación analiza el equipo y muestra todos los drivers instalados organizados por categoría:
> chipset, almacenamiento, USB, video, audio, red y WiFi, Bluetooth, touchpad, cámara, lector de huella
> y más. Elige cuáles guardar y en qué USB o disco. Junto a los drivers se guarda un inventario para
> Excel con los datos del equipo (modelo y número de serie).
>
> **2. Restaurar (después de formatear)**
> Abre la carpeta del respaldo y la aplicación instala los drivers en el orden correcto, empezando por
> el chipset. Puedes ver el estado de cada driver (Instalado, Sin cambios o Error) y cuántos
> dispositivos quedaban sin driver antes y después.
>
> **Seguro y sin internet**
> - Usa las herramientas oficiales de Windows (DISM y pnputil).
> - No descarga nada de internet ni envía información a ningún servidor.
> - Comprueba la huella SHA-256 de cada archivo antes de instalar: no instala drivers dañados o modificados.
> - Las actualizaciones de firmware y BIOS vienen desmarcadas por seguridad.
> - Avisa si el respaldo es de otro modelo de equipo.
>
> También puedes cargar una carpeta con drivers descargados del sitio del fabricante.

**Novedades de esta versión**
> Primera versión en la Microsoft Store.

**Características del producto** (una por línea)
- Respalda todos los drivers instalados en el equipo
- Organiza los drivers en 19 categorías
- Instala los drivers en el orden correcto después de formatear
- Muestra qué dispositivos no tienen driver
- Inventario de drivers para Excel con modelo y número de serie del equipo
- Funciona sin internet y no envía datos
- Verifica cada archivo con SHA-256 antes de instalar
- Firmware y BIOS desmarcados por seguridad

**Términos de búsqueda** (máximo 7)
`drivers` · `controladores` · `respaldo drivers` · `formatear` · `backup drivers` · `restaurar drivers` · `copia de seguridad`

**Capturas de pantalla:** descarga el artifact `capturas-de-pantalla` de la última ejecución de
"Compilar .exe" (están en el tamaño que pide la Store, 1366×768 o más). Usa en este orden:
`1-inicio`, `2-respaldar`, `4-restaurar`, `6-resultado`.

**Imágenes para mostrar en Store (1:1):** `LogoTienda-300x300.png`, `LogoTienda-150x150.png` y
`LogoTienda-71x71.png`, cada una en su recuadro.

**Arte de superhéroe (16:9):** `ArteSuperheroe-3840x2160.png` (o `ArteSuperheroe-1920x1080.png`). No lleva texto
porque la Store muestra el nombre de la app encima.

**Desarrollado por / Correo de soporte:** tus datos de contacto.

## Paso 5 — Enviar

Presiona **Enviar a la Store**. La certificación suele tardar de 1 a 3 días hábiles. Si la rechazan,
Partner Center indica el motivo; envía el informe a Claude para corregirlo.

### Nuevas versiones
Cada cambio en `main` genera un `.msix` con un número de versión mayor (`1.0.N.0`). Para actualizar
la app en la Store: crea un nuevo envío y sube el `.msix` más reciente.
