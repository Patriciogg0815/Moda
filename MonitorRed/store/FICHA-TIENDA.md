# Publicar "Monitor de Red" en la Microsoft Store

Esta carpeta contiene todo lo necesario para la Store (misma estructura que `store/` de RespaldoDrivers):

| Archivo | Para qué sirve |
|---|---|
| `identidad.json` | Datos de Partner Center (**falta `IdentityName`**, aparece al reservar el nombre) |
| `AppxManifest.xml` | Plantilla del manifiesto del paquete MSIX |
| `Assets/` | Íconos de la app en todos los tamaños |
| `LogoTienda-300x300.png`, `-150x150`, `-71x71` | Logos para la ficha de la tienda (1:1) |
| `ArteSuperheroe-3840x2160.png` / `-1920x1080.png` | Arte de superhéroe (16:9), sin texto |
| `capturas-maqueta/` | **Maquetas** de las 3 pantallas (ver la advertencia del Paso 4) |
| `privacidad.html` | Política de privacidad (hay que publicarla en una dirección web) |
| `Crear-MSIX.ps1` / `Probar-MSIX.ps1` | Arman y prueban el paquete |

---

## Antes de empezar

- La versión de la Store mide el consumo de **toda la casa** (por UPnP, si el router lo tiene activado) y el
  de **este equipo** (contadores de red de Windows). La descripción y las capturas solo deben mostrar eso.
- **Firewall:** si al escanear Windows muestra "Firewall de Windows bloqueó algunas características", hay
  que agregar reglas de firewall al manifiesto (`desktop2:FirewallRules`). Avísale a Claude con una captura.

---

## Paso 1 — Reservar el nombre y completar la identidad

1. Entra a [Partner Center](https://partner.microsoft.com/dashboard/apps-and-games/overview) →
   **Aplicaciones y juegos** → **Nueva aplicación** → **Aplicación MSIX o PWA**.
2. Reserva el nombre **Monitor de Red**. Si no está disponible (es un nombre genérico), prueba en este orden:
   **Monitor de Red Doméstica**, **Monitor de Red de Casa**, **Mi Red de Casa**. El nombre que reserves va
   en `identidad.json` → `DisplayName`.
3. Ve a **Administración de productos → Identidad del producto** y copia **Package/Identity/Name**
   en `identidad.json` → `IdentityName` (será algo como `GarridoitSolutions.MonitordeRed`).
   `Publisher` y `PublisherDisplayName` ya están completos porque son los mismos de RespaldoDrivers.
4. Guarda el cambio en GitHub (o envía el valor a Claude). GitHub volverá a generar el `.msix`.

## Paso 2 — Crear el envío

En la app → **Envíos** → **Iniciar el envío**:

### Precios y disponibilidad
- **Precio:** Gratis.
- **Mercados:** todos, o solo los países de habla hispana.

### Propiedades
- **Categoría:** Utilidades y herramientas (subcategoría de red o conectividad, si la ofrece).
- **URL de la política de privacidad:** https://patriciogg0815.github.io/Moda/MonitorRed/store/privacidad.html
  (funciona cuando esta carpeta esté en `main`).
- **Sitio web:** https://github.com/Patriciogg0815/Moda (o tu sitio).
- **Contacto de soporte:** patricio.garrido@garridoitsolutions.lat
- **Requisitos del sistema:** teclado y mouse. Recomendado: conexión a una red Wi-Fi o cableada.
- **Declaraciones del producto:** no marques "contiene compras desde la aplicación" ni "acceso a
  ubicación".

### Clasificación por edad
Responde el cuestionario IARC: categoría **"Herramienta o utilidad"** (no es un juego ni una red social).
- ¿Violencia, sexo, drogas, apuestas, lenguaje? **No.**
- ¿Los usuarios pueden comunicarse o compartir contenido entre sí? **No.**
- ¿Comparte la ubicación del usuario? **No.**
- ¿Comparte información personal con terceros? **No** (el banner de publicidad no recibe datos de la
  app; lo que recibe Adsterra al mostrar un anuncio está explicado en la política de privacidad).
- ¿Compras digitales? **No.**
- ¿Navegador web sin restricciones? **No.**

Resultado esperado: **3+ / Para todos (E)**.

### Publicidad
La app muestra un banner de Adsterra abajo de la ventana. Si Partner Center pregunta si el producto
contiene anuncios, responde **Sí**. La descripción y la política de privacidad ya lo mencionan.

### Paquetes
Sube **`MonitorRed.msix`** (pestaña **Actions** → ejecución "Monitor de Red" → **Artifacts** →
`MicrosoftStore-MonitorRed-1.0.N`), generado **después** de completar `identidad.json` (si no, Partner Center lo
rechaza con un error de identidad).
- Familia de dispositivos: solo **Escritorio** (Windows 10 versión 1809 o superior).

### Opciones de envío → Funcionalidades restringidas
Partner Center pedirá justificar `runFullTrust`. Texto sugerido:

> **runFullTrust:** Monitor de Red es una aplicación de escritorio (WPF) que descubre los equipos de la
> red local del usuario con los métodos estándar de Windows (ping, tabla ARP, NetBIOS, mDNS y UPnP/SSDP),
> lee el consumo total de internet que informa el router por UPnP y el consumo del propio equipo. Estas funciones requieren una aplicación de
> escritorio de plena confianza. No pide permisos de administrador y no instala drivers ni servicios. Para
> escanear solo se comunica con el router y los equipos de la red del usuario; el único contenido de
> internet es un banner de publicidad (WebView2) en la parte inferior de la ventana.

### Notas para la certificación
> La aplicación no requiere cuenta. Para probarla: conectar el equipo a una red Wi-Fi o cableada → abrir
> la app → la pantalla "Equipos" escanea la red automáticamente y lista los equipos con su nombre, IP,
> MAC y fabricante. Hacer clic en un equipo para ver el detalle y cambiarle el nombre ("Guardar nombre").
> El consumo de este equipo se muestra siempre. El consumo total de la casa aparece si el router de la red
> tiene UPnP activado; si no, la app lo indica y sigue funcionando. La app no lee el contenido del tráfico.
> La parte inferior muestra un banner de publicidad (Adsterra); sin internet no aparece. El botón
> "Apoyar a la app" abre la página de donaciones (Ko-fi) en el navegador.

## Paso 3 — Política de privacidad

Igual que con RespaldoDrivers, GitHub Pages ya publica el repositorio desde `main`, así que cuando esta
carpeta esté en `main` la dirección será:

https://patriciogg0815.github.io/Moda/MonitorRed/store/privacidad.html

## Paso 4 — Ficha de la tienda (Español - México)

**Nombre:** Monitor de Red (el nombre reservado en Partner Center)

**Descripción breve**
> Mira todos los equipos conectados a tu red de casa, con su nombre, IP, MAC y fabricante, y cuánto internet se está usando.

**Descripción**
> ¿El internet está lento y no sabes quién lo está usando? ¿Hay un equipo conectado que no reconoces?
> Monitor de Red te muestra en segundos todo lo que está conectado a tu red: computadoras, teléfonos,
> televisores, consolas, parlantes, cámaras, focos inteligentes y hasta el refrigerador.
>
> **Todos tus equipos en una lista**
> Al abrir la app se escanea la red automáticamente. De cada equipo ves la dirección IP, la dirección MAC,
> el fabricante (Samsung, Apple, LG, Xiaomi, TP-Link y miles más) y si está en línea. Los equipos que
> aparecen por primera vez se marcan como "Nuevo" para que detectes intrusos.
>
> **Ponle nombre a cada equipo**
> Cambia "Samsung Electronics" por "Smart TV sala" o "Xiaomi" por "Teléfono de Ana". La app recuerda los
> nombres para la próxima vez.
>
> **Cuánto internet se está usando**
> - **Toda la casa:** la velocidad de descarga y subida total de tu red, leída del router por UPnP,
>   sin pedir claves.
> - **Esta PC:** cuánto descarga y sube tu computadora en este momento, de forma automática.
>
> **Privado y sin configuraciones**
> - No necesitas cambiar nada en el router ni crear una cuenta.
> - La información de tu red no sale de tu casa: la app no la envía a ningún servidor.
> - No lee lo que navegan los demás equipos.
> - Es gratis: se mantiene con un banner de publicidad en la parte de abajo y con el botón "Apoyar a la app".
>
> Exporta la lista de equipos a Excel (CSV) cuando la necesites.

_Nota (no copiar): la medición de consumo y "Exportar a Excel" deben existir en la versión final; si
no, quita esas frases (la Store rechaza descripciones que prometen funciones que no están)._

**Novedades de esta versión**
> Primera versión en la Microsoft Store.

**Características del producto** (una por línea)
- Lista todos los equipos conectados a tu red Wi-Fi o cableada
- Muestra IP, MAC, fabricante y nombre de cada equipo
- Detecta televisores, consolas, cámaras y electrodomésticos inteligentes
- Marca los equipos nuevos para detectar intrusos
- Nombres personalizados para cada equipo
- Consumo total de internet de la casa por UPnP, sin claves
- Consumo de internet de esta PC en tiempo real, automático
- Gratis, sin cuenta y sin enviar los datos de tu red a internet

**Términos de búsqueda** (máximo 7)
`red wifi` · `quién usa mi wifi` · `escáner de red` · `dispositivos conectados` · `consumo de internet` · `monitor de red` · `ancho de banda`

**Capturas de pantalla** (mínimo 1366×768; se usan en este orden):
1. `1-equipos` — Lista de equipos conectados
2. `2-detalle` — Detalle de un equipo con su nombre editable
3. `3-ajustes` — Ajustes del escaneo y de la medición

> **Importante:** las imágenes de `capturas-maqueta/` son **maquetas** hechas mientras la app se termina.
> La Store exige que las capturas muestren la app real (política 10.1), así que antes de enviar descarga
> el artifact `capturas-monitor-red` del workflow del monitor y usa las de la carpeta `capturas/store/`
> (edición Store, mismos nombres, 1400×860). Las maquetas sirven como guía de cómo deberían verse.

**Texto de cada captura** (campo opcional "Leyenda")
1. Todos los equipos conectados a tu red, con su fabricante
2. Ponle nombre a cada equipo para reconocerlo
3. Mira cuánto internet usa tu casa y tu PC

**Imágenes para mostrar en Store (1:1):** `LogoTienda-300x300.png`, `LogoTienda-150x150.png` y
`LogoTienda-71x71.png`, cada una en su recuadro.

**Arte de superhéroe (16:9):** `ArteSuperheroe-3840x2160.png` (o `ArteSuperheroe-1920x1080.png`). No lleva
texto porque la Store muestra el nombre de la app encima.

**Desarrollado por:** Garrido IT Solutions · **Correo de soporte:** patricio.garrido@garridoitsolutions.lat

## Paso 5 — Enviar

Presiona **Enviar a la Store**. La certificación suele tardar de 1 a 3 días hábiles. Si la rechazan,
Partner Center indica el motivo; envía el informe a Claude para corregirlo.

---

## Paquete automático

El workflow `.github/workflows/monitor-red.yml` arma y prueba el `.msix` en cada cambio a partir de la
edición Store (`dist\store\MonitorRed.exe`) y lo deja en el artifact `MicrosoftStore-MonitorRed-1.0.N`.

### Nuevas versiones
Cada cambio en `main` genera un `.msix` con un número de versión mayor (`1.0.N.0`). Para actualizar la
app en la Store: crea un nuevo envío y sube el `.msix` más reciente.
