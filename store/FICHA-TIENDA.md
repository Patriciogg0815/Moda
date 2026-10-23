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
> **allowElevation:** Exportar los drivers instalados (`pnputil /export-driver`, `Get-WindowsDriver -Online`)
> e instalar drivers (`pnputil /add-driver /install`) requiere permisos de administrador por diseño de
> Windows. La aplicación solo pide elevación cuando el usuario la abre, muestra el aviso de Control de
> cuentas de usuario y no realiza ninguna acción sin que el usuario la inicie. No descarga ni instala
> nada de internet: solo trabaja con los drivers que ya están en el equipo o en la carpeta que el
> usuario elige.

### Donaciones (Ko-fi)
La app es gratis y tiene un botón opcional "Apoyar en Ko-fi" que abre la página de donaciones en el
navegador. No desbloquea funciones ni vende contenido, así que no necesita las compras de la Store.
En **Propiedades** no marques "contiene compras desde la aplicación".

### Notas para la certificación
> La aplicación no requiere cuenta ni conexión a internet. Para probarla: abrir la app y aceptar el aviso
> de administrador → "Respaldar drivers" → elegir una carpeta (por ejemplo, el escritorio) →
> "Respaldar N drivers". Luego en la pantalla de inicio → "Restaurar drivers" → "Buscar respaldo..." →
> elegir la carpeta creada → "Instalar N drivers". Los drivers que ya están instalados aparecen como
> "Sin cambios".

## Paso 3 — Política de privacidad

La Store exige una dirección web pública con la política. Opciones:
- **GitHub Pages** (si el repositorio es público): *Settings → Pages → Branch `main`, carpeta `/ (root)`*.
  La dirección será `https://<usuario>.github.io/<repositorio>/store/privacidad.html`.
- **Tu propio sitio web:** sube `privacidad.html` tal cual.

Antes de publicarla, reemplaza en el archivo `[NOMBRE DEL PUBLICADOR]` y `[CORREO DE CONTACTO]`.

## Paso 4 — Ficha de la tienda (Español - México)

**Nombre:** Respaldo de Drivers

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
- Firmware y BIOS desmarcados por seguridad

**Términos de búsqueda** (máximo 7)
`drivers` · `controladores` · `respaldo drivers` · `formatear` · `backup drivers` · `restaurar drivers` · `copia de seguridad`

**Capturas de pantalla:** descarga el artifact `capturas-de-pantalla` de la última ejecución de
"Compilar .exe" (están en el tamaño que pide la Store, 1366×768 o más). Usa en este orden:
`1-inicio`, `2-respaldar`, `4-restaurar`, `6-resultado`.

**Logo de la tienda (1:1, 300×300):** `LogoTienda-300x300.png`

**Desarrollado por / Correo de soporte:** tus datos de contacto.

## Paso 5 — Enviar

Presiona **Enviar a la Store**. La certificación suele tardar de 1 a 3 días hábiles. Si la rechazan,
Partner Center indica el motivo; envía el informe a Claude para corregirlo.

### Nuevas versiones
Cada cambio en `main` genera un `.msix` con un número de versión mayor (`1.0.N.0`). Para actualizar
la app en la Store: crea un nuevo envío y sube el `.msix` más reciente.
