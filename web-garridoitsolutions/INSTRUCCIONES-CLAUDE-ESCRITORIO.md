# Para Claude de escritorio: cambios en garridoitsolutions.lat

## Tanda 2 — YA PUBLICADA el 27/10/2026: Monitor de Red para Android

> Hecho por Claude de escritorio (deploy 6ae104a1): `/monitorred-privacidad` publicada y enlazada en el pie de
> todas las páginas y en `sitemap.xml`; tarjeta del Monitor con Windows · Android e insignias de Microsoft Store
> y Google Play; además, tarjeta de **Diagnóstico PC** con "Coming Soon" de Microsoft Store. Los cambios se
> integraron en el generador `build_site.py` de la PC. Quedan pendientes los pasos 4 y 5 (firmar el `.aab` y
> enviarlo a Play Console con Patricio).

Hay una app nueva para Android: **Monitor de Red de Casa** (carpeta `MonitorRedAndroid/` de este repo). Para
enviarla a Google Play hace falta su política de privacidad publicada en el sitio. Archivos en `tanda-2/`:

| Archivo | Va en el sitio como | Qué es |
|---|---|---|
| `monitorred-privacidad.html` | `/monitorred-privacidad.html` (nuevo) | Política de privacidad de la app de Android, con la plantilla de `coinid-privacidad` |
| `proyectos.html` | `/proyectos.html` | La tarjeta "Monitor de Red de Casa" ahora dice Windows · Android, menciona las alertas y lleva las insignias "Coming Soon" de Microsoft Store **y** de Google Play |
| `cambios-proyectos.patch` | — | La diferencia con el `proyectos.html` publicado hoy, por si la copia local cambió |

Pasos:

1. Igual que en la tanda 1: si tu `proyectos.html` local es igual al publicado, copia el nuevo encima; si no,
   aplica `cambios-proyectos.patch`.
2. Copia `monitorred-privacidad.html` a la carpeta del sitio. En el pie de página de **todas** las páginas
   ("Privacidad: CoinID · QuéVeo") agrega `· <a href="/monitorred-privacidad">Monitor de Red</a>`, y súmala
   al `sitemap.xml`.
3. Borrador (`netlify deploy`), enlace a Patricio, y a producción (`--prod`) solo cuando él confirme.
   Revisa que `https://garridoitsolutions.lat/monitorred-privacidad` abra bien: es la dirección que va en
   Play Console.
4. **Firma del `.aab` para Google Play:** ver `MonitorRedAndroid/README.md` → "Firma para Google Play".
   Usa la clave de subida que ya tienes para las otras apps de Play (forma A en la PC, o forma B con los
   secretos de GitHub). La clave **no** se sube al repositorio, que es público.
5. Para enviar la app a Play Console, sigue `MonitorRedAndroid/play/FICHA-PLAY.md` con Patricio. El kit
   (`.aab`, capturas, ícono, gráfico) es el artifact `GooglePlay-MonitorRed-1.0.N` de la pestaña Actions.

---

## Tanda 1 — YA PUBLICADA el 24/10/2026: insignias en la página Proyectos

Preparado el 24/10/2026 en una sesión de Claude en la web. Desde la web **no se puede publicar** este sitio:
se publica solo desde la PC con la Netlify CLI. Te toca aplicar estos cambios en la carpeta local del sitio
y publicarlos.

## Qué pidió Patricio

1. En **Próximos lanzamientos**, cambiar las etiquetas "Próximamente en …" por las imágenes de las
   tiendas con la cinta "Coming Soon" (Google Play, App Store y Microsoft Store).
2. Agregar los proyectos nuevos de Windows con la imagen de Microsoft Store "Coming Soon":
   **Monitor de Red de Casa** y **RespaldoDrivers**. Las dos ya se enviaron a la Microsoft Store y
   están en certificación (dato del 24/10/2026).
3. Poner un **marco blanco** como el de la insignia de Google Play en todas las insignias, incluida la de
   Microsoft Store de AppRescate.

## Archivos (carpeta `archivos/`)

Se hicieron a partir de lo que estaba **publicado** el 24/10/2026:

| Archivo | Va en el sitio como | Cambio |
|---|---|---|
| `proyectos.html` | `/proyectos.html` | Insignias "Coming Soon" en Próximos lanzamientos, 2 tarjetas nuevas (Monitor de Red de Casa y RespaldoDrivers), subtítulo con "Microsoft Store", `style.css?v=37` |
| `apprescate.html` | `/apprescate.html` | Solo `style.css?v=36` → `v=37` |
| `style.css` | `/style.css` | Se agregaron 5 reglas al final (`.store-badge img`, `.soon-badges`, `.soon-badge`) |
| `img/badges/*.webp` | `/img/badges/` (carpeta nueva) | Insignias recortadas, con las esquinas transparentes |
| `img/apps/monitorred.webp`, `img/apps/respaldodrivers.webp` | `/img/apps/` | Íconos de las apps nuevas (sacados de `MonitorRed/store/` y `store/` de este repo) |

`cambios.patch` tiene las mismas diferencias en formato `diff -u`. `vista-previa/` tiene capturas de cómo se ve.

## Pasos

1. Haz `git pull` de la rama `claude/happy-albattani-7ms4ny` del repo `Patriciogg0815/moda` (o descárgala).
2. Compara tus `proyectos.html`, `apprescate.html` y `style.css` locales con lo que está publicado.
   - **Si son iguales**, copia los archivos de `archivos/` encima.
   - **Si tu copia local tiene cambios sin publicar**, no la pises: aplica a mano lo de `cambios.patch`.
   - Si `proyectos.html` sale de una plantilla o de un script que genera las páginas, haz el cambio ahí.
3. Copia `img/badges/` e `img/apps/monitorred.webp` y `img/apps/respaldodrivers.webp` a la carpeta del sitio.
4. Anota cuál es el deploy de producción actual (para volver atrás) y publica un **borrador**
   (`netlify deploy`, sin `--prod`). Pásale el enlace a Patricio. Revisa que estén bien
   `/proyectos`, `/apprescate` y también `app-ads.txt` y las políticas de privacidad.
5. Publica en producción (`--prod`) **solo cuando Patricio lo confirme**.
6. Cuando sea, cambia la insignia por la de "Disponible" con su enlace a la tienda:
   - Monitor de Red de Casa y RespaldoDrivers, cuando los aprueben en la Microsoft Store.
   - Las demás apps, a medida que se publiquen.
   Si una app pasa a estar publicada, muévela a su sección: Google Play o Programas para Windows.
