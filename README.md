# 🍿 Moda · ¿Qué veo hoy?

Una app web que te **recomienda qué película o serie ver** cuando tienes tantas plataformas que no sabes por dónde empezar. Al estilo de [JustWatch](https://www.justwatch.com/), cada título muestra:

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

## Cómo usarla

La app no necesita servidor propio ni dependencias: es HTML, CSS y JavaScript que corre en el navegador. Los datos vienen de la **API gratuita de [TMDB](https://www.themoviedb.org/)**. TMDB obtiene la información de disponibilidad de JustWatch.

1. **Consigue una API key gratis**: crea una cuenta en [themoviedb.org](https://www.themoviedb.org/signup), entra a [Ajustes → API](https://www.themoviedb.org/settings/api) y copia tu *API Key* (v3) o tu *token de lectura* (v4).
2. **Abre la app** con cualquier servidor estático:
   ```bash
   npm start            # o: python3 -m http.server 5173
   ```
   y entra a <http://localhost:5173>.
3. En **⚙️ Configuración** pega tu API key, elige tu **país** y marca **tus plataformas**.

> La API key, tus plataformas y tus listas se guardan solo en tu navegador (localStorage), no en ningún servidor.

### Publicarla gratis con GitHub Pages

En el repositorio de GitHub: **Settings → Pages → Build and deployment → Deploy from a branch**, elige `main` y la carpeta `/ (root)`. En un par de minutos queda en `https://<tu-usuario>.github.io/Moda/` y la puedes abrir desde el celular.

## Cómo decide "plataforma" o "cine"

La lógica está en [`js/availability.js`](js/availability.js):

1. Si está incluida en una **suscripción** (o gratis/con anuncios) en tu país → muestra los logos de las plataformas, con las tuyas primero y marcadas con ✓.
2. Si solo se puede **alquilar o comprar** → "Alquiler / compra".
3. Si es una **película** sin plataformas y está en cartelera, o se estrenó hace menos de 120 días → **🎬 En cines**.
4. Si no hay ninguna de las anteriores → "Sin plataforma en tu país". Así no aparece como "en cines" una película antigua.

## Estructura

```
index.html            Interfaz
css/styles.css        Estilos (tema oscuro, responsive)
js/app.js             Lógica de la interfaz
js/tmdb.js            Cliente de la API de TMDB
js/availability.js    Reglas de disponibilidad (plataforma / alquiler / cine)
js/storage.js         Preferencias y listas en localStorage
test/                 Tests (node --test)
```

## Tests

```bash
npm test
```

## Ideas para seguir

- Calificaciones de IMDb o Rotten Tomatoes (por ejemplo con la API de OMDb)
- Recomendaciones basadas en lo que marcaste como visto ("porque viste…")
- Instalarla como app en el celular (PWA)
- Filtros por año, duración o idioma

---

Datos e imágenes de [TMDB](https://www.themoviedb.org/). Disponibilidad en plataformas por [JustWatch](https://www.justwatch.com/). Este producto usa la API de TMDB pero no está avalado ni certificado por TMDB.
