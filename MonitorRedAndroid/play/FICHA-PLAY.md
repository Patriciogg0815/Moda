# Publicar "Monitor de Red de Casa" en Google Play

Todo lo que pide Play Console, en el orden en que lo pide. Los textos están listos para copiar y pegar.

## El kit (descarga todo junto)

GitHub arma en cada cambio un `.zip` con todo: pestaña **Actions** → ejecución **"Monitor de Red Android"**
más reciente → sección **Artifacts** → **`GooglePlay-MonitorRed-1.0.N`**. Dentro vienen:

| En el kit | Dónde va en Play Console |
|---|---|
| `MonitorRed-1.0.N.aab` | **Prueba y lanzamiento → Producción** (o Prueba cerrada) → **Crear versión** → **Paquetes de apps** |
| `icono-512.png` | **Ficha de Play Store principal → Ícono de la app** (512 × 512) |
| `grafico-1024x500.png` | **Ficha de Play Store principal → Gráfico de funciones** (1024 × 500) |
| `capturas/1-equipos.png` … `4-alertas.png` | **Ficha de Play Store principal → Capturas de pantalla del teléfono** (1080 × 1920, en este orden) |
| `monitorred-privacidad.html` | Se publica en garridoitsolutions.lat (ver "Política de privacidad") |
| `FICHA-PLAY.md` | Esta guía |

> ⚠️ El `.aab` tiene que estar **firmado con la clave de subida**. Si GitHub no tiene los secretos de la
> clave (ver `MonitorRedAndroid/README.md`), el `.aab` del kit sale sin firmar y Claude de escritorio lo firma
> en la PC antes de subirlo.

Las capturas son de la app real con una casa de ejemplo (las genera la prueba `CapturasTest`), sin texto
encima: todo el texto de la ficha va en los campos de abajo.

## Paso 1 — Crear la app

Play Console → **Inicio** → **Crear app**:

- **Nombre de la app:** `Monitor de Red de Casa`
- **Idioma predeterminado:** Español (Latinoamérica) – es-419
- **App o juego:** App
- **Gratis o de pago:** Gratis
- Marca las 2 casillas de **Declaraciones** → **Crear app**.

## Paso 2 — Ficha de Play Store principal

**Nombre de la app** (máx. 30): `Monitor de Red de Casa`

**Descripción breve** (máx. 80):
> Mira quién usa tu Wi-Fi y recibe un aviso cuando se conecta un equipo nuevo.

**Descripción completa** (máx. 4000):
> ¿El internet está lento y no sabes quién lo está usando? ¿Hay un equipo conectado que no reconoces?
> Monitor de Red de Casa te muestra en segundos todo lo que está conectado a tu Wi-Fi: teléfonos,
> computadoras, televisores, consolas, parlantes, impresoras, cámaras y aparatos inteligentes.
>
> TODOS TUS EQUIPOS EN UNA LISTA
> Toca «Escanear» y la app busca los equipos de tu red. De cada uno ves su dirección IP, el nombre con el
> que se anuncia, qué tipo de equipo es y si está en línea. Los que aparecen por primera vez se marcan
> como «Nuevo».
>
> TE AVISA CUANDO ALGUIEN SE CONECTA
> La app revisa tu red cada pocos minutos y te manda una notificación cuando se conecta un equipo nuevo o
> cuando un equipo se apaga o sale de la red. Puedes elegir que te avise solo de los equipos a los que les
> pusiste nombre. Toca la notificación y se abre ese equipo.
>
> PONLE NOMBRE A CADA EQUIPO
> Cambia «Equipo sin nombre» por «TV de la sala» o «Teléfono de Ana». La app lo recuerda.
>
> CUÁNTO INTERNET SE ESTÁ USANDO
> • Toda la casa: la velocidad de descarga y subida total, si tu router lo informa (UPnP).
> • Este teléfono: cuánto descarga y sube en este momento.
>
> PRIVADA Y SIN CONFIGURAR NADA
> • No necesitas cambiar nada en el router ni crear una cuenta.
> • La información de tu red se queda en tu teléfono: la app no la envía a ningún servidor.
> • No lee lo que navegan los demás equipos.
>
> Importante: por privacidad, Android no deja que las apps vean la dirección MAC de los otros equipos ni el
> consumo de cada uno. Por eso los equipos se reconocen por su nombre o su IP. Para ver la MAC, el
> fabricante y el consumo de cada equipo existe la versión para Windows en la Microsoft Store.

**Ícono de la app:** `icono-512.png` · **Gráfico de funciones:** `grafico-1024x500.png`

**Capturas de pantalla del teléfono** (en este orden):
1. `1-equipos.png` — Resumen de la red, consumo y el aviso de un equipo nuevo
2. `2-lista.png` — Lista de equipos con la insignia «Nuevo»
3. `3-detalle.png` — Ponerle nombre y tipo a un equipo
4. `4-alertas.png` — Ajustes de las alertas

**Guardar.**

## Paso 3 — Configuración de la tienda

**Crecimiento → Presencia en Play Store → Configuración de la tienda**:

- **Categoría de la app:** Herramientas
- **Etiquetas:** elige las que aparezcan parecidas a «Herramientas de red», «Wi-Fi» y «Seguridad».
- **Detalles de contacto → Correo electrónico:** patricio.garrido@garridoitsolutions.lat
- **Sitio web:** https://garridoitsolutions.lat

## Paso 4 — Contenido de la app

**Política → Contenido de la app**. Una por una:

| Sección | Qué responder |
|---|---|
| **Política de privacidad** | `https://garridoitsolutions.lat/monitorred-privacidad` (primero hay que publicarla, ver abajo) |
| **Acceso a la app** | «Todas las funciones están disponibles sin restricciones especiales» (no hay cuenta ni clave) |
| **Anuncios** | «No, mi app no contiene anuncios» |
| **Clasificación del contenido** | Ver más abajo |
| **Público objetivo** | Solo **18 años o más** (así no se aplican las reglas de apps para niños) |
| **Seguridad de los datos** | Ver más abajo |
| **Apps gubernamentales** | No |
| **Funciones financieras** | Mi app no ofrece ninguna función financiera |
| **Salud** | Mi app no tiene funciones de salud |
| **Apps de noticias** | No |

### Clasificación del contenido (cuestionario de IARC)

- **Correo electrónico:** patricio.garrido@garridoitsolutions.lat
- **Categoría:** «Todos los demás tipos de apps» (utilidades / herramientas; no es juego ni red social)
- Responde **No** a todo: violencia, contenido sexual, lenguaje vulgar, sustancias, apuestas, interacción
  entre usuarios, compartir la ubicación del usuario y compras digitales.
- Resultado esperado: apta para todo público (PEGI 3 / Everyone).

### Seguridad de los datos

- **¿Tu app recopila o comparte alguno de los tipos de datos del usuario requeridos?** → **No**.
  La app procesa la información de la red solo en el teléfono y no la envía a ningún lado; Google no lo
  cuenta como «recopilar».
- **¿Todos los datos del usuario que recopila tu app están encriptados en tránsito?** → no se pregunta si
  respondiste «No» arriba.
- **¿Ofreces una forma para que los usuarios soliciten que se borren sus datos?** → no se pregunta (no hay
  datos en servidores). Si aparece, explica: «Los datos están solo en el teléfono; se borran al
  desinstalar la app o desde Ajustes de Android → Apps → Monitor de Red → Borrar datos».

### Permisos que usa la app (por si los preguntan)

Ninguno es «sensible» ni pide declaración especial. No usa ubicación ni servicios en primer plano.

| Permiso | Para qué |
|---|---|
| Internet, estado de la red y del Wi-Fi | Buscar los equipos de la red local |
| Multicast Wi-Fi | Encontrar televisores, consolas y el router por UPnP |
| Notificaciones | Las alertas de equipo nuevo o desconectado |
| Mantener activo y ejecutar al iniciar | Los agrega WorkManager (la revisión en segundo plano): sigue funcionando después de reiniciar el teléfono |

## Paso 5 — Política de privacidad

El archivo `monitorred-privacidad.html` ya tiene el diseño del sitio. **Claude de escritorio** lo copia a la
carpeta de garridoitsolutions.lat, agrega «Monitor de Red» a los enlaces de privacidad del pie de página y
publica (primero un borrador para revisarlo). Tiene que quedar en
`https://garridoitsolutions.lat/monitorred-privacidad`.

## Paso 6 — Enviar la versión

**Prueba y lanzamiento → Producción → Crear versión**:

1. **Firma de apps de Google Play:** acepta que Google administre la clave de firma (es lo normal).
2. **Paquetes de apps:** sube `MonitorRed-1.0.N.aab` (el firmado con la clave de subida).
3. **Nombre de la versión:** lo pone solo (`1.0.N`).
4. **Notas de la versión:**
   ```
   <es-419>
   Primera versión: lista de equipos conectados a tu Wi-Fi y alertas cuando se conecta un equipo nuevo o uno se desconecta.
   </es-419>
   ```
5. **Siguiente** → revisa los avisos → **Guardar** → **Enviar a revisión**.

> Si Play Console pide antes una **prueba cerrada** (12 personas durante 14 días), es la misma regla que
> se cumplió con las otras apps: crea la prueba cerrada con el mismo `.aab` y la lista de correos de
> siempre.

La revisión de Google suele tardar de 1 a 7 días.

## Nuevas versiones

Cada cambio genera un `.aab` con un número de versión mayor (`1.0.N`). Crea una versión nueva en
Producción y sube el `.aab` más reciente del kit.
