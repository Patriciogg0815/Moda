// Lógica pura (sin DOM ni red) para decidir dónde ver un título.
// Se testea con `npm test`.

// Días tras el estreno en los que consideramos que una película sigue en cines
// si todavía no aparece en ninguna plataforma.
export const CINEMA_WINDOW_DAYS = 120;

const DAY_MS = 24 * 60 * 60 * 1000;

function dedupe(list) {
  const seen = new Set();
  const out = [];
  for (const p of list) {
    if (!p || seen.has(p.provider_id)) continue;
    seen.add(p.provider_id);
    out.push(p);
  }
  return out.sort((a, b) => (a.display_priority ?? 999) - (b.display_priority ?? 999));
}

/**
 * Clasifica la disponibilidad de un título en un país.
 *
 * @param {object|undefined} regionProviders  Bloque `results[PAIS]` de /watch/providers de TMDB.
 * @param {object} info
 * @param {'movie'|'tv'} info.mediaType
 * @param {number} info.id
 * @param {string} [info.releaseDate]       Fecha de estreno (YYYY-MM-DD).
 * @param {Set<number>} [info.nowPlayingIds] Ids de películas en cartelera en el país.
 * @param {Set<number>} [info.myProviderIds] Plataformas que tiene el usuario.
 * @param {Date} [info.today]
 * @returns {{kind: 'streaming'|'rent'|'cinema'|'none', stream: object[], rent: object[], buy: object[], mine: object[], link: string|null}}
 */
export function classifyAvailability(regionProviders, info) {
  const { mediaType, id, releaseDate, nowPlayingIds = new Set(), myProviderIds = new Set(), today = new Date() } = info;
  const rp = regionProviders || {};

  const stream = dedupe([...(rp.flatrate || []), ...(rp.free || []), ...(rp.ads || [])]);
  const rent = dedupe(rp.rent || []);
  const buy = dedupe(rp.buy || []);
  const mine = stream.filter((p) => myProviderIds.has(p.provider_id));
  const link = rp.link || null;

  let kind;
  if (stream.length) kind = 'streaming';
  else if (rent.length || buy.length) kind = 'rent';
  else if (mediaType === 'movie' && isInCinemas({ id, releaseDate, nowPlayingIds, today })) kind = 'cinema';
  else kind = 'none';

  return { kind, stream, rent, buy, mine, link };
}

/** Una película se considera "en cines" si está en cartelera o se estrenó hace poco. */
export function isInCinemas({ id, releaseDate, nowPlayingIds = new Set(), today = new Date() }) {
  if (nowPlayingIds.has(id)) return true;
  if (!releaseDate) return false;
  const released = new Date(`${releaseDate}T00:00:00Z`);
  if (Number.isNaN(released.getTime())) return false;
  const diffDays = (today.getTime() - released.getTime()) / DAY_MS;
  return diffDays >= -7 && diffDays <= CINEMA_WINDOW_DAYS;
}

/** Texto corto para la etiqueta de disponibilidad. */
export function availabilityLabel(av, countryName) {
  switch (av.kind) {
    case 'streaming':
      return av.mine.length ? `En tu ${av.mine[0].provider_name}` : `En ${av.stream[0].provider_name}`;
    case 'rent':
      return 'Alquiler o compra';
    case 'cinema':
      return 'En cines';
    default:
      return `Sin plataforma en ${countryName}`;
  }
}

/** Color de la calificación (escala 0-10). */
export function ratingTone(vote) {
  if (!vote) return 'none';
  if (vote >= 7) return 'good';
  if (vote >= 5.5) return 'ok';
  return 'bad';
}

/** Mezcla un arreglo (Fisher–Yates) sin mutar el original. */
export function shuffle(list, rand = Math.random) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}
