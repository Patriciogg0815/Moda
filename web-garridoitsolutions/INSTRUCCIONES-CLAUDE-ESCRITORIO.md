# Para Claude de escritorio: cambios en garridoitsolutions.lat (página Proyectos)

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
