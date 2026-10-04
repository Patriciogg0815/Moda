// Cliente mínimo para la API de TMDB (https://developer.themoviedb.org).
// Los datos de "dónde ver" que entrega TMDB provienen de JustWatch.

const API = 'https://api.themoviedb.org/3';
export const IMG = 'https://image.tmdb.org/t/p/';

export function img(path, size = 'w342') {
  return path ? `${IMG}${size}${path}` : null;
}

export class TmdbError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

/**
 * @param {object} opts
 * @param {string} opts.key      API key v3 (32 caracteres) o token de lectura v4 (empieza con "eyJ").
 * @param {string} opts.language Ej. "es-MX".
 * @param {string} opts.region   Código ISO del país, ej. "CL".
 */
export function createClient({ key, language, region }) {
  const isBearer = key.startsWith('eyJ');
  const cache = new Map();

  async function get(path, params = {}) {
    const url = new URL(API + path);
    const all = { language, ...params };
    if (!isBearer) all.api_key = key;
    for (const [k, v] of Object.entries(all)) {
      if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, v);
    }
    const cacheKey = url.toString();
    if (cache.has(cacheKey)) return cache.get(cacheKey);

    const headers = { accept: 'application/json' };
    if (isBearer) headers.Authorization = `Bearer ${key}`;

    const promise = fetch(url, { headers }).then(async (res) => {
      if (!res.ok) {
        let msg = `TMDB respondió ${res.status}`;
        try {
          const body = await res.json();
          if (body.status_message) msg = body.status_message;
        } catch { /* sin cuerpo JSON */ }
        throw new TmdbError(msg, res.status);
      }
      return res.json();
    });
    cache.set(cacheKey, promise);
    promise.catch(() => cache.delete(cacheKey));
    return promise;
  }

  const today = new Date().toISOString().slice(0, 10);

  return {
    region,
    validate: () => get('/configuration'),

    /** Plataformas disponibles en el país, ordenadas por relevancia. */
    async providers(type = 'movie') {
      const data = await get(`/watch/providers/${type}`, { watch_region: region });
      return (data.results || []).sort(
        (a, b) => (a.display_priorities?.[region] ?? a.display_priority ?? 999) -
                  (b.display_priorities?.[region] ?? b.display_priority ?? 999),
      );
    },

    /**
     * Descubre títulos según filtros.
     * @param {'movie'|'tv'} type
     * @param {object} f
     * @param {string} [f.genres]      Ids separados por "|" (OR).
     * @param {number[]} [f.providers] Ids de plataformas (OR).
     * @param {number} [f.minRating]
     * @param {number} [f.page]
     */
    discover(type, { genres, providers, minRating = 0, years, page = 1 } = {}) {
      const params = {
        sort_by: 'popularity.desc',
        include_adult: false,
        page,
        with_genres: genres,
        'vote_average.gte': minRating || undefined,
        'vote_count.gte': type === 'movie' ? 150 : 80,
      };
      // Fecha de estreno (películas) o del primer episodio (series), dentro del rango de años.
      const dateField = type === 'movie' ? 'primary_release_date' : 'first_air_date';
      const to = years?.to ? `${years.to}-12-31` : today;
      params[`${dateField}.lte`] = to < today ? to : today;
      if (years?.from) {
        params[`${dateField}.gte`] = `${years.from}-01-01`;
        // Los estrenos recientes todavía tienen pocos votos.
        if (years.from >= new Date().getFullYear() - 1) params['vote_count.gte'] = 20;
      }
      if (providers?.length) {
        params.with_watch_providers = providers.join('|');
        params.watch_region = region;
        params.with_watch_monetization_types = 'flatrate|free|ads';
      }
      return get(`/discover/${type}`, params);
    },

    trending: (type = 'all', page = 1) => get(`/trending/${type}/week`, { page }),
    nowPlaying: (page = 1) => get('/movie/now_playing', { region, page }),
    search: (query, page = 1) => get('/search/multi', { query, page, include_adult: false }),

    /** Detalle + proveedores + videos en una sola llamada. */
    details: (type, id) =>
      get(`/${type}/${id}`, {
        append_to_response: 'watch/providers,videos',
        include_video_language: `${language.slice(0, 2)},en`,
      }),

    /** Bloque de proveedores del país configurado (o undefined). */
    async watchProviders(type, id) {
      const data = await get(`/${type}/${id}/watch/providers`);
      return data.results?.[region];
    },
  };
}
