# Publicar "Diagnóstico PC" en la Microsoft Store

## Descarga todo junto (el "kit")

GitHub arma en cada cambio un `.zip` con todo lo que pide Partner Center: pestaña **Actions** → ejecución
**"Diagnóstico PC"** más reciente → sección **Artifacts** → **`MicrosoftStore-DiagnosticoPC-1.0.N`**.
Dentro vienen:

| En el kit | Dónde va en Partner Center |
|---|---|
| `DiagnosticoPC.msix` | **Paquetes** |
| `capturas/1-resumen.png` … `7-arreglado.png` | **Ficha → Capturas de pantalla** (capturas reales de la edición Store) |
| `LogoTienda-300x300.png`, `-150x150`, `-71x71` | **Ficha → Imágenes para mostrar en Store (1:1)** |
| `ArteSuperheroe-3840x2160.png` / `-1920x1080.png` | **Ficha → Arte de superhéroe (16:9)** |
| `FICHA-TIENDA.md` | Esta guía, con todos los textos para copiar |

> ⚠️ Usa el kit generado **después** de completar `IdentityName` (Paso 1). El de antes sirve para probar,
> pero Partner Center lo rechaza con un error de identidad.

## Archivos de esta carpeta

Misma estructura que `store/` de RespaldoDrivers y del Monitor de Red:

| Archivo | Para qué sirve |
|---|---|
| `identidad.json` | Datos de Partner Center (**falta `IdentityName`**, aparece al reservar el nombre) |
| `AppxManifest.xml` | Plantilla del manifiesto del paquete MSIX |
| `Assets/` | Íconos de la app en todos los tamaños |
| `LogoTienda-300x300.png`, `-150x150`, `-71x71` | Logos para la ficha de la tienda (1:1) |
| `ArteSuperheroe-3840x2160.png` / `-1920x1080.png` | Arte de superhéroe (16:9), sin texto |
| `privacidad.html` | Política de privacidad (se publica sola con GitHub Pages al unir la rama a `main`) |
| `Crear-MSIX.ps1` / `Probar-MSIX.ps1` | Arman y prueban el paquete (GitHub Actions los ejecuta solo) |

---

## Antes de empezar

- La edición de la Store es igual al `.exe`, salvo la opción **"Iniciar con Windows"**, que no aparece
  (la Store no permite que una app se programe sola para arrancar). Los avisos funcionan mientras la app
  está abierta o junto al reloj.
- La app pide **permisos de administrador** (como RespaldoDrivers): Windows los exige para leer la
  configuración de energía, reparar archivos de Windows y crear puntos de restauración.

---

## Paso 1 — Reservar el nombre y completar la identidad

1. Entra a [Partner Center](https://partner.microsoft.com/dashboard/apps-and-games/overview) →
   **Aplicaciones y juegos** → **Nueva aplicación** → **Aplicación MSIX o PWA**.
2. Escribe el nombre **Diagnóstico PC** y presiona **Comprobar disponibilidad** → **Reservar nombre del producto**.
   Si ya está usado, prueba en este orden: **Diagnóstico PC Fácil**, **Diagnóstico de PC: Semáforo**,
   **Doctor de PC Windows**. Avísale a Claude el nombre que quedó (cambia `DisplayName` en `identidad.json`).
3. En la app → **Administración de productos** → **Identidad del producto**, copia
   **Package/Identity/Name** (algo como `GarridoitSolutions.DiagnosticoPC`) y pégalo en `identidad.json`
   → `IdentityName`, en lugar de `GarridoitSolutions.DiagnosticoPC-PENDIENTE`.
   `Publisher` y `PublisherDisplayName` ya están completos porque son los mismos de tus otras apps.
4. Guarda el cambio en GitHub (o envía el valor a Claude). GitHub volverá a generar el `.msix`.

## Paso 2 — Crear el envío

En la app → **Envíos** → **Iniciar el envío**:

### Precios y disponibilidad
- **Precio:** Gratis.
- **Mercados:** todos, o solo los países de habla hispana.

### Propiedades
- **Categoría:** Utilidades y herramientas (subcategoría: Copia de seguridad y administración, o la más
  parecida a "mantenimiento del sistema").
- **URL de la política de privacidad:** https://patriciogg0815.github.io/Moda/DiagnosticoPC/store/privacidad.html
  (queda publicada cuando esta rama se une a `main`; ábrela en el navegador antes de enviar).
- **Sitio web:** https://garridoitsolutions.lat
- **Contacto de soporte:** patricio.garrido@garridoitsolutions.lat
- **Requisitos del sistema:** teclado y mouse. Windows 10 versión 2004 o superior, u 11.
- **Declaraciones del producto:** no marques "contiene compras desde la aplicación" ni "acceso a ubicación".

### Clasificación por edad
Responde el cuestionario IARC: categoría **"Herramienta o utilidad"** (no es un juego ni una red social).
- ¿Violencia, sexo, drogas, apuestas, lenguaje? **No.**
- ¿Los usuarios pueden comunicarse o compartir contenido entre sí? **No.**
- ¿Comparte la ubicación del usuario? **No.**
- ¿Comparte información personal con terceros? **No.**
- ¿Compras digitales? **No.**
- ¿Navegador web sin restricciones? **No.**

Resultado esperado: **3+ / Para todos (E)**.

### Publicidad
La app **no** tiene publicidad. Si Partner Center pregunta si el producto contiene anuncios, responde **No**.

### Donaciones (Ko-fi)
La app es gratis y tiene un botón opcional "Apoyar a la app" que abre la página de donaciones de Ko-fi en el
navegador. No desbloquea funciones ni vende contenido, así que no necesita las compras de la Store.

### Paquetes
Sube **`DiagnosticoPC.msix`** del kit, generado **después** de completar `identidad.json`.
- Familia de dispositivos: solo **Escritorio** (Windows 10 versión 2004 o superior).

### Opciones de envío → Funcionalidades restringidas
Partner Center pedirá justificar `runFullTrust` y `allowElevation`. Texto sugerido:

> **runFullTrust:** Diagnóstico PC es una aplicación de escritorio (WPF) que revisa el estado de Windows
> de forma local: lee la configuración de energía (suspensión, hibernación, temporizadores de
> reactivación), los registros de eventos del sistema (pantallas azules, apagones, reactivaciones), el
> estado de los dispositivos y drivers, los discos, la batería y los programas que arrancan con Windows.
> Muestra cada resultado en rojo, amarillo o verde, con el paso a paso para arreglarlo. Estas funciones
> requieren una aplicación de escritorio de plena confianza. No envía datos a internet.
>
> **allowElevation:** Windows exige permisos de administrador para leer los pedidos de energía
> (`powercfg /requests`), revisar y reparar los archivos de Windows (DISM y SFC), cambiar la configuración
> de energía y crear puntos de restauración. La app nunca cambia nada sin que el usuario lo pida con un
> botón y lo confirme; antes de cada cambio crea un punto de restauración y guarda el valor anterior para
> poder deshacerlo desde la misma app.

### Notas para la certificación
> La aplicación no requiere cuenta. Para probarla: abrir la app → presionar «Analizar mi PC» (tarda
> alrededor de un minuto). Aparece la lista de revisiones en rojo (grave), amarillo (revisar) y verde
> (bien). Elegir una revisión muestra qué pasa y los botones «Arreglar» (pide confirmación, crea un punto
> de restauración y se puede deshacer en «Herramientas y cambios») y «Ver el paso a paso» (abre una
> ventana con los pasos para hacerlo a mano). La pestaña «Avisos» configura las notificaciones junto al
> reloj («Probar un aviso» muestra una de ejemplo). La app no tiene publicidad; el botón «Apoyar a la
> app» abre la página de donaciones (Ko-fi) en el navegador.

## Paso 3 — Política de privacidad

GitHub Pages publica el repositorio desde `main`. Cuando esta rama se una a `main`, quedará en:

https://patriciogg0815.github.io/Moda/DiagnosticoPC/store/privacidad.html

## Paso 4 — Ficha de la tienda (Español - México)

**Nombre:** Diagnóstico PC (el nombre reservado en Partner Center)

**Descripción breve**
> Revisa tu PC en un minuto: lo que la calienta, la frena o causa pantallas azules, en rojo, amarillo y verde, con el paso a paso para arreglarlo.

**Descripción**
> ¿Tu laptop se calienta en la mochila? ¿La PC está lenta, el ventilador no para o aparecen pantallas
> azules? Diagnóstico PC revisa Windows en un minuto y te muestra cada cosa con un color:
> 🔴 rojo si es grave, 🟡 amarillo si conviene revisarla y 🟢 verde si está bien.
>
> **Encuentra la causa de verdad**
> - **Energía e hibernación:** detecta si la PC no hiberna, si «Hibernar tras» está en «Nunca», qué
>   programas no la dejan suspenderse y qué la despierta de madrugada. Es la causa más común de que una
>   laptop se caliente guardada.
> - **Temperatura:** avisa si el equipo está caliente o si el procesador tuvo que frenar por calor.
> - **Programas:** los que más procesador y memoria usan, y los que arrancan con Windows (incluso los
>   que ya no existen).
> - **Drivers:** dispositivos sin driver o con fallas, y el driver de video antiguo o genérico.
> - **Pantallas azules:** confirma si hubo, cuándo, el código del error y su causa probable.
> - **Registro de Windows:** cambios peligrosos (como los que dejan los virus) y ajustes importantes.
> - **Archivos de Windows:** archivos dañados o que faltan.
> - **Disco, batería y antivirus:** espacio libre, salud del disco, desgaste de la batería y protección.
>
> **Arréglalo con un botón o paso a paso**
> Cada problema trae el botón «Arreglar» y una ventana con el paso a paso, con los nombres de los menús
> tal como se ven en Windows, para hacerlo tú mismo. Antes de cambiar algo, la app te pregunta, crea un
> punto de restauración y guarda el valor anterior: puedes deshacer cualquier cambio con un clic.
>
> **Avisos junto al reloj**
> Te avisa con una notificación si aparece una pantalla azul, si la PC se calienta, si un programa usa
> mucho el procesador, si la memoria o el disco se llenan, o si la PC se despertó sola de madrugada.
>
> **Privada y gratis**
> Todo se revisa dentro de tu PC: no se envía nada a internet y no necesitas cuenta. No tiene publicidad;
> si te sirve, puedes apoyarla con el botón «Apoyar a la app». Guarda el diagnóstico en un informe para
> enviárselo a un técnico.

**Novedades de esta versión**
> Primera versión en la Microsoft Store.

**Características del producto** (una por línea)
- Diagnóstico completo en un minuto, en rojo, amarillo y verde
- Detecta por qué la laptop se calienta en la mochila (hibernación y suspensión)
- Programas que consumen procesador y memoria, y los que arrancan con Windows
- Drivers faltantes o con fallas
- Confirma las pantallas azules y explica su causa
- Revisa el registro y los archivos de Windows
- Arreglos con un botón y paso a paso para hacerlo tú mismo
- Punto de restauración y deshacer para cada cambio
- Avisos junto al reloj cuando aparece un problema
- Gratis, sin publicidad, sin cuenta y sin enviar tus datos

**Términos de búsqueda** (máximo 7)
`diagnóstico pc` · `pc lenta` · `laptop se calienta` · `pantalla azul` · `hibernación` · `drivers` · `optimizar windows`

**Capturas de pantalla:** las de la carpeta `capturas/` del kit, en este orden. Son capturas reales de
la edición Store con una laptop de ejemplo (1384×821, más que el mínimo de 1366×768).
1. `1-resumen.png` — El diagnóstico en rojo, amarillo y verde
2. `2-paso-a-paso.png` — La ventana del paso a paso
3. `3-programas.png` — Programas que usan el procesador, con el botón «Cerrar»
4. `4-pantallas-azules.png` — Pantallas azules confirmadas, con su causa
5. `5-avisos.png` — Avisos junto al reloj
6. `6-herramientas.png` — Herramientas de Windows y cambios que se pueden deshacer
7. `7-arreglado.png` — Un arreglo terminado

**Texto de cada captura** (campo opcional "Leyenda")
1. Todo tu PC revisado en rojo, amarillo y verde
2. Arréglalo tú mismo con el paso a paso
3. Descubre qué programa calienta tu PC
4. Confirma las pantallas azules y su causa
5. Te avisa cuando aparece un problema
6. Cada cambio se puede deshacer
7. Arreglos con un botón, seguros

**Imágenes para mostrar en Store (1:1):** `LogoTienda-300x300.png`, `LogoTienda-150x150.png` y
`LogoTienda-71x71.png` del kit, cada una en su recuadro.

**Arte de superhéroe (16:9):** `ArteSuperheroe-3840x2160.png` (o `ArteSuperheroe-1920x1080.png`). No lleva
texto porque la Store muestra el nombre de la app encima.

**Desarrollado por:** Garrido IT Solutions · **Correo de soporte:** patricio.garrido@garridoitsolutions.lat

## Paso 5 — Enviar

Presiona **Enviar a la Store**. La certificación suele tardar de 1 a 3 días hábiles. Si la rechazan,
Partner Center indica el motivo; envía el informe a Claude para corregirlo.

---

### Nuevas versiones
Cada cambio genera un `.msix` con un número de versión mayor (`1.0.N.0`). Para actualizar la app en la
Store: crea un nuevo envío y sube el `.msix` más reciente.
