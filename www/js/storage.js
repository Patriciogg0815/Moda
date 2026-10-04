// Preferencias y listas del usuario guardadas en el navegador.

const KEY = 'moda.v1';

// API key de TMDB incluida en la app (el usuario ya no tiene que ingresarla).
export const TMDB_KEY = 'd38933f8d1484a8e572354ca6cf8c205';

const COUNTRIES = {
  AR: 'Argentina', BO: 'Bolivia', CL: 'Chile', CO: 'Colombia', CR: 'Costa Rica',
  DO: 'Rep. Dominicana', EC: 'Ecuador', ES: 'España', GT: 'Guatemala', HN: 'Honduras',
  MX: 'México', PA: 'Panamá', PE: 'Perú', PY: 'Paraguay', SV: 'El Salvador',
  US: 'Estados Unidos', UY: 'Uruguay', VE: 'Venezuela',
};
export { COUNTRIES };

function defaultCountry() {
  const lang = (navigator.languages || [navigator.language || ''])
    .map((l) => l.split('-')[1]?.toUpperCase())
    .find((c) => c && COUNTRIES[c]);
  return lang || 'MX';
}

const defaults = () => ({
  country: defaultCountry(),
  myProviders: [],    // ids de plataformas que tiene el usuario
  watchlist: [],      // [{id, media_type, title, poster_path, vote_average, date}]
  seen: [],           // claves "movie:123" vistas
  dismissed: [],      // claves "tv:456" descartadas
  filters: { type: 'all', mood: null, minRating: 6, year: 'any', sort: 'random', onlyMine: false },
  tutorialSeen: false, // ya vio el tutorial de bienvenida
});

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return defaults();
    const saved = JSON.parse(raw);
    delete saved.apiKey; // versiones anteriores guardaban la key del usuario
    return { ...defaults(), ...saved, filters: { ...defaults().filters, ...saved.filters } };
  } catch {
    return defaults();
  }
}

export const state = load();

export function save() {
  try {
    localStorage.setItem(KEY, JSON.stringify(state));
  } catch { /* almacenamiento no disponible: la app sigue funcionando en memoria */ }
}

export const itemKey = (item) => `${item.media_type}:${item.id}`;

export function languageFor(country) {
  return country === 'ES' ? 'es-ES' : 'es-MX';
}

export const language = () => languageFor(state.country);

export function toggleIn(listName, key) {
  const list = state[listName];
  const i = list.indexOf(key);
  if (i >= 0) list.splice(i, 1);
  else list.push(key);
  save();
  return i < 0;
}

export function inWatchlist(item) {
  return state.watchlist.some((w) => itemKey(w) === itemKey(item));
}

export function toggleWatchlist(item) {
  const k = itemKey(item);
  const i = state.watchlist.findIndex((w) => itemKey(w) === k);
  if (i >= 0) state.watchlist.splice(i, 1);
  else {
    state.watchlist.unshift({
      id: item.id,
      media_type: item.media_type,
      title: item.title,
      original_title: item.original_title,
      poster_path: item.poster_path,
      overview: item.overview,
      vote_average: item.vote_average,
      date: item.date,
    });
  }
  save();
  return i < 0;
}
