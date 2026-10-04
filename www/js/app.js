import { createClient, img } from './tmdb.js';
import { initAds } from './ads.js';
import { classifyAvailability, ratingTone, shuffle } from './availability.js';
import {
  state, save, itemKey, language, languageFor, toggleIn, inWatchlist, toggleWatchlist, COUNTRIES, TMDB_KEY,
} from './storage.js';

// Estados de ánimo → géneros de TMDB por tipo ("|" = cualquiera de ellos).
// null = no hay un género equivalente para ese tipo.
const MOODS = [
  { id: 'reir', label: '😂 Comedia', movie: '35', tv: '35' },
  { id: 'adrenalina', label: '💥 Adrenalina', movie: '28|53|12', tv: '10759' },
  { id: 'intriga', label: '🕵️ Intriga', movie: '9648|80', tv: '9648|80' },
  { id: 'miedo', label: '😱 Miedo', movie: '27', tv: null },
  { id: 'romance', label: '💕 Romance', movie: '10749', tv: null },
  { id: 'emocion', label: '🎭 Emocionarme', movie: '18', tv: '18' },
  { id: 'mundos', label: '🚀 Otros mundos', movie: '878|14', tv: '10765' },
  { id: 'familia', label: '👨‍👩‍👧 En familia', movie: '10751|16', tv: '10751|10762' },
  { id: 'real', label: '📚 Historias reales', movie: '99|36', tv: '99' },
];

// Filtro por año de estreno (en series: año del primer episodio).
const THIS_YEAR = new Date().getFullYear();
const YEARS = [
  { id: 'any', label: 'Cualquiera' },
  { id: 'this', label: `Este año (${THIS_YEAR})`, from: THIS_YEAR },
  { id: 'last3', label: `Últimos 3 años (${THIS_YEAR - 2}+)`, from: THIS_YEAR - 2 },
  { id: '2020', label: '2020 en adelante', from: 2020 },
  { id: '2010', label: '2010 – 2019', from: 2010, to: 2019 },
  { id: '2000', label: '2000 – 2009', from: 2000, to: 2009 },
  { id: '1990', label: '1990 – 1999', from: 1990, to: 1999 },
  { id: 'old', label: 'Antes de 1990', to: 1989 },
];

const RATINGS = [
  { id: 0, label: 'Cualquiera' },
  { id: 6, label: '★ 6+' },
  { id: 7, label: '★ 7+' },
  { id: 8, label: '★ 8+' },
];

// Tutorial de bienvenida (se abre la primera vez y con el botón ❓).
const TUTORIAL = [
  { icon: '👋', title: 'Bienvenido a QuéVeo',
    text: 'Te ayudo a decidir qué ver en <b>4 pasos</b>. Te tomará unos segundos.' },
  { icon: '🎬', title: '1. Elige qué quieres ver',
    text: 'Toca <b>Película</b>, <b>Serie</b> o <b>Lo que sea</b>.' },
  { icon: '😂', title: '2. Elige un género (opcional)',
    text: 'Toca uno, como <b>Comedia</b>, <b>Adrenalina</b> o <b>Miedo</b>. Tócalo otra vez para quitarlo. Si no eliges ninguno, te recomiendo de todo.' },
  { icon: '📅', title: '3. Ajusta si quieres (opcional)',
    text: 'Elige la <b>calificación mínima</b>, el <b>año de estreno</b> y si quieres <b>solo títulos de tus plataformas</b> (al tocarla te muestro las plataformas para marcar las tuyas).' },
  { icon: '🎲', title: '4. Toca «¡Recomiéndame algo!»',
    text: 'Es el <b>botón amarillo</b>. Te muestro un título destacado y <b>muchas opciones más</b>, que puedes filtrar por <b>año</b> y <b>calificación</b> u ordenar. ¿No te convence? Toca <b>🎲 Otra</b>. Toca un póster para ver el resumen, el tráiler y <b>dónde verla</b>.' },
  { icon: '🔎', title: '¿Ya sabes qué buscas?',
    text: 'Ve a la pestaña <b>🔎 Buscar</b> y escribe el nombre. En cada título puedes tocar <b>♥</b> para guardarlo en Mi lista, <b>✓</b> si ya la viste o <b>✕</b> si no te interesa.' },
];

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s = '') =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

let client = null;
let nowPlayingIds = new Set();
let pool = [];               // candidatos de la recomendación actual
let currentTab = 'recomienda';
const registry = new Map();  // "movie:123" → item normalizado
const availCache = new Map(); // "movie:123" → Promise<disponibilidad>

const countryName = () => COUNTRIES[state.country] || state.country;

// ---------- Utilidades ----------

/** Limita las peticiones concurrentes a TMDB. */
const queue = [];
let active = 0;
function limit(fn) {
  return new Promise((resolve, reject) => {
    queue.push({ fn, resolve, reject });
    pump();
  });
}
function pump() {
  while (active < 6 && queue.length) {
    const { fn, resolve, reject } = queue.shift();
    active++;
    fn().then(resolve, reject).finally(() => {
      active--;
      pump();
    });
  }
}

function errorText(e) {
  if (e?.status === 401) return 'Tu API key de TMDB no es válida. Revísala en Configuración.';
  if (e instanceof TypeError) return 'No se pudo conectar con TMDB. Revisa tu conexión.';
  return e?.message || 'Algo salió mal.';
}

let toastTimer;
function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

function normalize(raw, fallbackType) {
  const media_type = raw.media_type || fallbackType;
  if (media_type !== 'movie' && media_type !== 'tv') return null;
  return {
    id: raw.id,
    media_type,
    title: raw.title || raw.name || '',
    original_title: raw.original_title || raw.original_name || '',
    poster_path: raw.poster_path,
    backdrop_path: raw.backdrop_path,
    overview: raw.overview || '',
    vote_average: raw.vote_average || 0,
    vote_count: raw.vote_count || 0,
    date: raw.release_date || raw.first_air_date || '',
  };
}

// TMDB no traduce algunos géneros de series al español.
const GENRE_ES = {
  'Action & Adventure': 'Acción y aventura', 'Sci-Fi & Fantasy': 'Ciencia ficción y fantasía',
  'War & Politics': 'Bélica y política', Kids: 'Infantil', News: 'Noticias', Soap: 'Telenovela', Talk: 'Entrevistas',
};
const genreNames = (d, max) => (d.genres || []).slice(0, max).map((g) => GENRE_ES[g.name] || g.name).join(', ');

const year = (item) => item.date?.slice(0, 4) || '';
const kindLabel = (item) => (item.media_type === 'tv' ? 'Serie' : 'Película');

// ---------- Disponibilidad ----------

function classify(regionProviders, item) {
  return classifyAvailability(regionProviders, {
    mediaType: item.media_type,
    id: item.id,
    releaseDate: item.date,
    nowPlayingIds,
    myProviderIds: new Set(state.myProviders),
  });
}

function getAvailability(item) {
  const key = itemKey(item);
  if (!availCache.has(key)) {
    const p = limit(() => client.watchProviders(item.media_type, item.id)).then((rp) => classify(rp, item));
    p.catch(() => availCache.delete(key));
    availCache.set(key, p);
  }
  return availCache.get(key);
}

function logoHTML(p, mine) {
  return `<img class="plogo${mine ? ' mine' : ''}" src="${img(p.logo_path, 'w92')}" alt="${esc(p.provider_name)}" title="${esc(p.provider_name)}" loading="lazy">`;
}

function availHTML(av) {
  if (av.kind === 'cinema') return '<span class="badge cinema">🎬 En cines</span>';
  if (av.kind === 'none') return `<span class="badge none">Sin plataforma en ${esc(countryName())}</span>`;

  const mineIds = new Set(state.myProviders);
  let list;
  if (av.kind === 'streaming') {
    list = [...av.mine, ...av.stream.filter((p) => !mineIds.has(p.provider_id))];
  } else {
    const byId = new Map([...av.rent, ...av.buy].map((p) => [p.provider_id, p]));
    list = [...byId.values()];
  }
  const shown = list.slice(0, 4).map((p) => logoHTML(p, mineIds.has(p.provider_id))).join('');
  const more = list.length > 4 ? `<span class="pmore">+${list.length - 4}</span>` : '';
  let badge = '';
  if (av.kind === 'rent') badge = '<span class="badge rent">Alquiler / compra</span>';
  else if (av.mine.length) badge = '<span class="badge mine">✓ En tus plataformas</span>';
  return `<span class="plogos">${shown}${more}</span>${badge}`;
}

function fillAvailability(item) {
  const key = itemKey(item);
  getAvailability(item)
    .then((av) => $$(`[data-avail="${key}"]`).forEach((el) => { el.innerHTML = availHTML(av); }))
    .catch(() => $$(`[data-avail="${key}"]`).forEach((el) => { el.innerHTML = '<span class="badge none">—</span>'; }));
}

// ---------- Tarjetas ----------

function ratingHTML(vote, big = false) {
  return `<span class="rating ${ratingTone(vote)}${big ? ' big' : ''}" title="Calificación TMDB">${vote ? vote.toFixed(1) : '–'}</span>`;
}

function actionsHTML(item) {
  const k = itemKey(item);
  const on = (cond) => (cond ? ' active' : '');
  return `<div class="actions">
    <button type="button" data-action="watchlist" class="icon${on(inWatchlist(item))}" title="Mi lista" aria-label="Agregar a mi lista">♥</button>
    <button type="button" data-action="seen" class="icon${on(state.seen.includes(k))}" title="Ya la vi" aria-label="Ya la vi">✓</button>
    <button type="button" data-action="dismiss" class="icon${on(state.dismissed.includes(k))}" title="No me interesa" aria-label="No me interesa">✕</button>
  </div>`;
}

function posterHTML(item, size = 'w342') {
  const src = img(item.poster_path, size);
  return src
    ? `<img src="${src}" alt="Póster de ${esc(item.title)}" loading="lazy">`
    : `<div class="noposter">${esc(item.title)}</div>`;
}

function cardHTML(item) {
  const key = itemKey(item);
  registry.set(key, item);
  const dim = state.seen.includes(key) || state.dismissed.includes(key) ? ' dim' : '';
  return `<article class="card${dim}" data-key="${key}">
    <button type="button" class="poster" data-action="open" aria-label="Ver detalles de ${esc(item.title)}">
      ${posterHTML(item)}
      ${ratingHTML(item.vote_average)}
      <span class="kind">${kindLabel(item)}</span>
    </button>
    <div class="card-body">
      <h3 title="${esc(item.title)}">${esc(item.title)}</h3>
      <p class="meta">${year(item)}</p>
      <div class="avail" data-avail="${key}"><span class="skeleton"></span></div>
      <p class="overview">${esc(item.overview || 'Sin resumen disponible.')}</p>
      ${actionsHTML(item)}
    </div>
  </article>`;
}

function renderGrid(grid, items, append = false) {
  const html = items.map(cardHTML).join('');
  if (append) grid.insertAdjacentHTML('beforeend', html);
  else grid.innerHTML = html;
  items.forEach(fillAvailability);
}

/** Sincroniza los botones ♥ ✓ ✕ de un título en toda la página. */
function syncButtons(item) {
  const k = itemKey(item);
  $$(`[data-key="${k}"]`).forEach((root) => {
    $(`[data-action="watchlist"]`, root)?.classList.toggle('active', inWatchlist(item));
    $(`[data-action="seen"]`, root)?.classList.toggle('active', state.seen.includes(k));
    $(`[data-action="dismiss"]`, root)?.classList.toggle('active', state.dismissed.includes(k));
    if (root.classList.contains('card')) {
      root.classList.toggle('dim', state.seen.includes(k) || state.dismissed.includes(k));
    }
  });
}

// ---------- Listas paginadas (tendencias, cines, búsqueda) ----------

function pagedList(section, loader, fallbackType) {
  const grid = $('.grid', section);
  const more = $('.more-btn', section);
  const status = $('.status', section);
  let page = 0;
  let total = 1;
  let token = 0;

  async function next() {
    if (page >= total) return;
    const my = token;
    more.hidden = true;
    status.textContent = 'Cargando…';
    try {
      const data = await loader(page + 1);
      if (my !== token) return; // se reinició mientras cargaba
      page = data.page;
      total = Math.min(data.total_pages || 1, 500);
      const items = data.results.map((r) => normalize(r, fallbackType)).filter(Boolean);
      renderGrid(grid, items, true);
      status.textContent = grid.children.length ? '' : 'No hay resultados.';
      more.hidden = page >= total;
    } catch (e) {
      if (my === token) status.textContent = errorText(e);
    }
  }

  function reset() {
    token++;
    page = 0;
    total = 1;
    grid.innerHTML = '';
    status.textContent = '';
    more.hidden = true;
  }

  more.addEventListener('click', next);
  return {
    load() { reset(); return next(); },
    reset,
    get loaded() { return page > 0; },
  };
}

const lists = {
  tendencias: pagedList($('#tab-tendencias'), (p) => client.trending('all', p)),
  cines: pagedList($('#tab-cines'), (p) => client.nowPlaying(p), 'movie'),
};
let searchQuery = '';
const searchList = pagedList($('#tab-buscar'), (p) => client.search(searchQuery, p));

// ---------- Recomendación ----------

async function fetchCandidates() {
  const f = state.filters;
  const mood = MOODS.find((m) => m.id === f.mood);
  const types = (f.type === 'all' ? ['movie', 'tv'] : [f.type]).filter((t) => !mood || mood[t]);
  if (!types.length) throw new Error('Ese género solo aplica a películas. Prueba con "Película" o "Lo que sea".');

  const providers = f.onlyMine && state.myProviders.length ? state.myProviders : undefined;
  const excluded = new Set([...state.seen, ...state.dismissed]);

  const batches = await Promise.all(types.map(async (t) => {
    const years = YEARS.find((y) => y.id === f.year);
    const opts = { genres: mood?.[t], providers, minRating: f.minRating, years };
    const first = await client.discover(t, { ...opts, page: 1 });
    const maxPage = Math.min(first.total_pages || 1, 10);
    // Además de la primera página, hasta dos páginas al azar para tener variedad.
    const pages = shuffle(Array.from({ length: maxPage - 1 }, (_, i) => i + 2)).slice(0, 2);
    const more = await Promise.all(pages.map((page) => client.discover(t, { ...opts, page })));
    return [...more.flatMap((d) => d.results), ...first.results].map((r) => normalize(r, t));
  }));

  const seen = new Set();
  return shuffle(batches.flat().filter((i) => {
    if (!i || !i.poster_path) return false;
    const k = itemKey(i);
    if (excluded.has(k) || seen.has(k)) return false;
    seen.add(k);
    return true;
  }));
}

async function recommend() {
  if (!client) return openSettings();
  const btn = $('#recommend-btn');
  const out = $('#rec-result');
  btn.disabled = true;
  out.innerHTML = '<p class="status">Buscando algo para ti…</p>';
  try {
    pool = await fetchCandidates();
    shownOptions = OPTIONS_PAGE;
    renderRecommendation();
  } catch (e) {
    out.innerHTML = `<p class="status error">${esc(errorText(e))}</p>`;
  } finally {
    btn.disabled = false;
  }
}

function heroHTML(item) {
  const key = itemKey(item);
  registry.set(key, item);
  const backdrop = img(item.backdrop_path, 'w1280');
  return `<article class="hero" data-key="${key}" ${backdrop ? `style="--backdrop:url('${backdrop}')"` : ''}>
    <button type="button" class="poster" data-action="open" aria-label="Ver detalles">${posterHTML(item, 'w500')}</button>
    <div class="hero-info">
      <p class="eyebrow">Te recomendamos</p>
      <h2>${esc(item.title)}</h2>
      <p class="meta">${kindLabel(item)} · ${year(item)} <span id="hero-extra"></span></p>
      <div class="hero-rating">${ratingHTML(item.vote_average, true)}<small>${item.vote_count.toLocaleString('es')} votos en TMDB</small></div>
      <div class="avail" data-avail="${key}"><span class="skeleton"></span></div>
      <p class="overview full">${esc(item.overview || 'Sin resumen disponible.')}</p>
      <div class="hero-actions">
        <button type="button" class="primary" data-action="reroll">🎲 Otra</button>
        <button type="button" class="ghost" data-action="open">Ver detalles</button>
        ${actionsHTML(item)}
      </div>
    </div>
  </article>`;
}

function renderRecommendation() {
  const out = $('#rec-result');
  if (!pool.length) {
    out.innerHTML = '<p class="status">No encontramos nada con esos filtros. Prueba bajar la calificación mínima, cambiar el año o el género, o desactivar "Solo en mis plataformas".</p>';
    return;
  }
  const [hero, ...rest] = pool;
  const sorted = sortOptions(rest);
  const others = sorted.slice(0, shownOptions);
  out.innerHTML = heroHTML(hero) + `
    <div class="rec-options">
      <h2 class="section-title">Más opciones <small>(${rest.length})</small></h2>
      ${recToolbarHTML()}
      ${others.length ? `<div class="grid">${others.map(cardHTML).join('')}</div>` : '<p class="status">No hay más opciones con estos filtros.</p>'}
      ${sorted.length > shownOptions ? `<button type="button" class="ghost more-btn" data-action="more-options">Ver más opciones (${sorted.length - shownOptions})</button>` : ''}
    </div>`;
  [hero, ...others].forEach(fillAvailability);
  loadHeroExtras(hero);
}

const OPTIONS_PAGE = 20;     // opciones que se muestran de una vez
let shownOptions = OPTIONS_PAGE;

const SORTS = [
  { id: 'random', label: 'Al azar' },
  { id: 'rating', label: 'Mejor nota' },
  { id: 'recent', label: 'Recientes' },
  { id: 'oldest', label: 'Antiguas' },
];

function sortOptions(items) {
  const list = [...items];
  const sort = state.filters.sort;
  if (sort === 'rating') list.sort((a, b) => b.vote_average - a.vote_average);
  else if (sort === 'recent') list.sort((a, b) => b.date.localeCompare(a.date));
  else if (sort === 'oldest') list.sort((a, b) => a.date.localeCompare(b.date));
  return list;
}

// Barra para filtrar las opciones por año y calificación (vuelve a buscar) u ordenarlas.
function recToolbarHTML() {
  const f = state.filters;
  const opts = (list, current) => list.map((o) =>
    `<option value="${o.id}"${String(o.id) === String(current) ? ' selected' : ''}>${o.label}</option>`).join('');
  return `<div class="rec-toolbar">
    <label>📅 Año<select data-rec="year">${opts(YEARS, f.year)}</select></label>
    <label>⭐ Calificación<select data-rec="minRating">${opts(RATINGS, f.minRating)}</select></label>
    <label>↕ Ordenar<select data-rec="sort">${opts(SORTS, f.sort)}</select></label>
    <label class="switch rec-mine"><input type="checkbox" data-rec="onlyMine"${f.onlyMine && state.myProviders.length ? ' checked' : ''}>
      <span>📺 Solo en mis plataformas</span></label>
  </div>`;
}

async function onRecToolbarChange(e) {
  const sel = e.target.closest('[data-rec]');
  if (!sel) return;
  const field = sel.dataset.rec;
  if (field === 'onlyMine') {
    setOnlyMine(sel.checked);
    $('.rec-options')?.scrollIntoView({ block: 'start' });
    return;
  }
  if (field === 'sort') {
    state.filters.sort = sel.value;
    save();
    shownOptions = OPTIONS_PAGE;
    renderRecommendation();
    $('.rec-options')?.scrollIntoView({ block: 'start' });
    return;
  }
  // Año y calificación cambian la búsqueda: se piden nuevos títulos a TMDB.
  state.filters[field] = field === 'minRating' ? Number(sel.value) : sel.value;
  save();
  renderFilters();
  await recommend();
  $('.rec-options')?.scrollIntoView({ block: 'start' });
}

async function loadHeroExtras(item) {
  try {
    const d = await client.details(item.media_type, item.id);
    const el = $('#hero-extra');
    if (!el || pool[0] !== item) return;
    const parts = [durationText(d), genreNames(d, 3)].filter(Boolean);
    el.textContent = parts.length ? ` · ${parts.join(' · ')}` : '';
    const trailer = trailerUrl(d);
    if (trailer) {
      $('.hero-actions [data-action="open"]')?.insertAdjacentHTML('afterend',
        `<a class="ghost btn" href="${esc(trailer)}" target="_blank" rel="noopener">▶ Tráiler</a>`);
    }
  } catch { /* los extras son opcionales */ }
}

function reroll() {
  pool.shift();
  if (pool.length < 2) recommend();
  else renderRecommendation();
  $('#rec-result').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

/** Quita un título descartado/visto de la recomendación actual. */
function removeFromPool(item) {
  const k = itemKey(item);
  const i = pool.findIndex((p) => itemKey(p) === k);
  if (i === 0) reroll();
  else if (i > 0) {
    pool.splice(i, 1);
    renderRecommendation();
  }
}

// ---------- Detalle ----------

function durationText(d) {
  if (d.runtime) {
    const h = Math.floor(d.runtime / 60);
    const m = d.runtime % 60;
    return h ? `${h} h ${m} min` : `${m} min`;
  }
  if (d.number_of_seasons) return `${d.number_of_seasons} temporada${d.number_of_seasons > 1 ? 's' : ''}`;
  return '';
}

function trailerUrl(d) {
  const videos = d.videos?.results || [];
  const v = videos.find((x) => x.site === 'YouTube' && x.type === 'Trailer') ||
            videos.find((x) => x.site === 'YouTube');
  return v ? `https://www.youtube.com/watch?v=${encodeURIComponent(v.key)}` : null;
}

function providersHTML(av) {
  const mine = new Set(state.myProviders);
  const group = (title, list) => (list.length
    ? `<div class="pgroup"><h4>${title}</h4><div class="plist">${list.map((p) =>
      `<span class="prov${mine.has(p.provider_id) ? ' mine' : ''}">${logoHTML(p)}<span>${esc(p.provider_name)}${mine.has(p.provider_id) ? ' ✓' : ''}</span></span>`).join('')}</div></div>`
    : '');

  let html = '';
  if (av.kind === 'cinema') html += `<div class="notice cinema">🎬 <strong>En cines.</strong> Aún no está en plataformas de ${esc(countryName())}.</div>`;
  else if (av.kind === 'none') html += `<div class="notice">Por ahora no está disponible en plataformas de ${esc(countryName())}.</div>`;
  else if (av.kind === 'streaming' && state.myProviders.length && !av.mine.length) {
    html += '<div class="notice">No está en tus plataformas, pero sí en estas:</div>';
  }
  html += group('Incluido en suscripción', av.stream) + group('Alquiler', av.rent) + group('Compra', av.buy);
  if (av.link) html += `<a class="link" href="${esc(av.link)}" target="_blank" rel="noopener">Ver todas las opciones ↗</a>`;
  return `<section class="where"><h3>Dónde ver en ${esc(countryName())}</h3>${html}</section>`;
}

function detailHTML(item, d, av) {
  const backdrop = img(d.backdrop_path, 'w1280');
  const trailer = trailerUrl(d);
  const genres = genreNames(d);
  const meta = [kindLabel(item), year(item), durationText(d), genres].filter(Boolean).join(' · ');
  const original = item.original_title && item.original_title !== item.title
    ? `<p class="original">${esc(item.original_title)}</p>` : '';
  return `
    ${backdrop ? `<div class="detail-backdrop" style="background-image:url('${backdrop}')"></div>` : ''}
    <div class="detail-main">
      <div class="detail-poster">${posterHTML(item, 'w500')}</div>
      <div class="detail-info">
        <h2>${esc(item.title)}</h2>
        ${original}
        <p class="meta">${esc(meta)}</p>
        <div class="hero-rating">${ratingHTML(d.vote_average, true)}<small>${(d.vote_count || 0).toLocaleString('es')} votos en TMDB</small></div>
        ${d.tagline ? `<p class="tagline">“${esc(d.tagline)}”</p>` : ''}
        <p class="overview full">${esc(d.overview || item.overview || 'Sin resumen disponible.')}</p>
        <div class="hero-actions">
          ${trailer ? `<a class="primary btn" href="${esc(trailer)}" target="_blank" rel="noopener">▶ Ver tráiler</a>` : ''}
          ${actionsHTML(item)}
        </div>
      </div>
    </div>
    ${providersHTML(av)}`;
}

async function openDetail(item) {
  const dlg = $('#detail');
  const body = $('#detail-body');
  body.dataset.key = itemKey(item);
  body.innerHTML = '<p class="status">Cargando…</p>';
  if (!dlg.open) dlg.showModal();
  try {
    const d = await client.details(item.media_type, item.id);
    if (body.dataset.key !== itemKey(item)) return;
    const av = classify(d['watch/providers']?.results?.[state.country], item);
    body.innerHTML = detailHTML(item, d, av);
  } catch (e) {
    body.innerHTML = `<p class="status error">${esc(errorText(e))}</p>`;
  }
}

// ---------- Mi lista ----------

function renderWatchlist() {
  const section = $('#tab-lista');
  const grid = $('.grid', section);
  renderGrid(grid, state.watchlist);
  $('.status', section).textContent = state.watchlist.length
    ? ''
    : 'Tu lista está vacía. Toca ♥ en cualquier título para guardarlo aquí.';
}

// ---------- Pestañas y filtros ----------

function showTab(name) {
  currentTab = name;
  $$('.tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  $$('.tab').forEach((s) => s.classList.toggle('active', s.id === `tab-${name}`));
  if (!client) return;
  if (lists[name] && !lists[name].loaded) lists[name].load();
  if (name === 'lista') renderWatchlist();
  if (name === 'buscar') $('#search-input').focus();
}

function renderFilters() {
  const f = state.filters;
  $('#moods').innerHTML = MOODS.map((m) =>
    `<button type="button" class="chip${f.mood === m.id ? ' active' : ''}" data-mood="${m.id}">${m.label}</button>`).join('');
  $$('[data-type]').forEach((b) => b.classList.toggle('active', b.dataset.type === f.type));
  $('#min-rating').value = String(f.minRating);
  $('#year').value = YEARS.some((y) => y.id === f.year) ? f.year : 'any';
  const hasMine = state.myProviders.length > 0;
  $('#only-mine').checked = f.onlyMine && hasMine;
  $('#only-mine-hint').innerHTML = hasMine
    ? `${state.myProviders.length} plataforma(s) elegida(s) · <button type="button" class="link" data-pick-providers>cambiar</button>`
    : 'Aún no eliges tus plataformas · <button type="button" class="link" data-pick-providers>elegirlas</button>';
}

// "Solo en mis plataformas": si todavía no eligió plataformas, se muestran para elegirlas.
function setOnlyMine(on) {
  if (on && !state.myProviders.length) {
    renderFilters(); // desmarca la casilla hasta que elija plataformas
    $$('[data-rec="onlyMine"]').forEach((c) => { c.checked = false; });
    openPlatforms(true);
    return;
  }
  setFilter({ onlyMine: on });
}

// Selector rápido de plataformas.
let platformsEnableOnlyMine = false;

function openPlatforms(enableOnlyMine = false) {
  platformsEnableOnlyMine = enableOnlyMine;
  $('#platforms .providers-filter').value = '';
  $('#platforms').showModal();
  renderProviderChoices($('#platforms-grid'), state.country, new Set(state.myProviders));
}

function savePlatforms(e) {
  e.preventDefault();
  state.myProviders = [...$('#platforms-grid').selected];
  const hasMine = state.myProviders.length > 0;
  const turnedOn = hasMine && (platformsEnableOnlyMine || state.filters.onlyMine);
  state.filters.onlyMine = turnedOn;
  save();
  $('#platforms').close();
  renderFilters();
  availCache.clear(); // los logos "✓ tuyas" dependen de tus plataformas
  if (turnedOn) toast(`Listo: solo verás títulos de tus ${state.myProviders.length} plataforma(s)`);
  else toast(hasMine ? 'Plataformas guardadas' : 'No marcaste ninguna plataforma');
  if (turnedOn || pool.length) recommend();
}

function setFilter(patch) {
  Object.assign(state.filters, patch);
  save();
  renderFilters();
  // Si ya hay una recomendación en pantalla, se actualiza sola con el nuevo filtro.
  if (pool.length) recommend();
  else nudgeRecommend();
}

// Después de elegir un filtro, indica el siguiente paso: tocar el botón amarillo.
function nudgeRecommend() {
  const btn = $('#recommend-btn');
  btn.classList.remove('pulse');
  void btn.offsetWidth; // reinicia la animación
  btn.classList.add('pulse');
  btn.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  if (!$('#rec-result').children.length) toast('Ahora toca 🎲 ¡Recomiéndame algo!');
}

// ---------- Tutorial ----------

let tutorialStep = 0;

function openTutorial() {
  tutorialStep = 0;
  renderTutorial();
  const dlg = $('#tutorial');
  if (!dlg.open) dlg.showModal();
}

function renderTutorial() {
  const step = TUTORIAL[tutorialStep];
  const last = tutorialStep === TUTORIAL.length - 1;
  $('#tutorial-icon').textContent = step.icon;
  $('#tutorial-title').textContent = step.title;
  $('#tutorial-text').innerHTML = step.text;
  $('#tutorial-dots').innerHTML = TUTORIAL.map((_, i) => `<span class="${i === tutorialStep ? 'on' : ''}"></span>`).join('');
  $('#tutorial-prev').hidden = tutorialStep === 0;
  $('#tutorial-next').textContent = last ? '¡Empezar!' : 'Siguiente';
}

function tutorialNext() {
  if (tutorialStep < TUTORIAL.length - 1) {
    tutorialStep++;
    renderTutorial();
    return;
  }
  $('#tutorial').close();
  showTab('recomienda');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// ---------- Configuración ----------

function openSettings() {
  $('#country').value = state.country;
  $('#settings-error').textContent = '';
  $('#settings .providers-filter').value = '';
  $('#settings').showModal();
  renderProviderChoices($('#providers-grid'), state.country, new Set(state.myProviders));
}

/** Muestra las plataformas del país para marcarlas; lo marcado queda en grid.selected. */
async function renderProviderChoices(grid, country, selected) {
  grid.selected = selected;
  const err = grid.id === 'providers-grid' ? $('#settings-error') : null;
  if (err) err.textContent = '';
  grid.innerHTML = '<p class="hint">Cargando plataformas…</p>';
  try {
    const c = createClient({ key: TMDB_KEY, language: languageFor(country), region: country });
    const [m, t] = await Promise.all([c.providers('movie'), c.providers('tv')]);
    if (grid.selected !== selected) return; // se volvió a abrir mientras cargaba
    const byId = new Map();
    [...m, ...t].forEach((p) => { if (!byId.has(p.provider_id)) byId.set(p.provider_id, p); });
    grid.innerHTML = [...byId.values()].map((p) => `
      <label class="pchoice" data-name="${esc(p.provider_name.toLowerCase())}">
        <input type="checkbox" value="${p.provider_id}" ${selected.has(p.provider_id) ? 'checked' : ''}>
        <img src="${img(p.logo_path, 'w92')}" alt="" loading="lazy">
        <span>${esc(p.provider_name)}</span>
      </label>`).join('') || '<p class="hint">No hay plataformas para este país.</p>';
  } catch (e) {
    grid.innerHTML = `<p class="status error">${esc(errorText(e))}</p>`;
  }
}

async function saveSettings(e) {
  e.preventDefault();
  state.country = $('#country').value;
  state.myProviders = [...$('#providers-grid').selected];
  if (!state.myProviders.length) state.filters.onlyMine = false;
  save();
  $('#settings').close();
  toast('Configuración guardada');
  await initClient();
}

// ---------- Inicio ----------

async function initClient() {
  availCache.clear();
  Object.values(lists).forEach((l) => l.reset());
  searchList.reset();
  $('#country-label').textContent = state.country;
  $$('[data-country-name]').forEach((el) => { el.textContent = countryName(); });
  renderFilters();

  client = createClient({ key: TMDB_KEY, language: language(), region: state.country });
  try {
    const pages = await Promise.all([client.nowPlaying(1), client.nowPlaying(2)]);
    nowPlayingIds = new Set(pages.flatMap((d) => d.results.map((r) => r.id)));
  } catch {
    nowPlayingIds = new Set();
  }
  $('#rec-result').innerHTML = '';
  pool = [];
  showTab(currentTab);
}

function bindEvents() {
  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-open-settings], #open-settings')) return openSettings();
    if (e.target.closest('[data-open-help], #open-help')) return openTutorial();
    if (e.target.closest('[data-pick-providers]')) return openPlatforms();
    const closeBtn = e.target.closest('[data-close]');
    if (closeBtn) return closeBtn.closest('dialog').close();

    const tab = e.target.closest('[data-tab]');
    if (tab) return showTab(tab.dataset.tab);

    const typeBtn = e.target.closest('[data-type]');
    if (typeBtn) return setFilter({ type: typeBtn.dataset.type });

    const moodBtn = e.target.closest('[data-mood]');
    if (moodBtn) return setFilter({ mood: state.filters.mood === moodBtn.dataset.mood ? null : moodBtn.dataset.mood });

    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const holder = btn.closest('[data-key]');
    const item = holder && registry.get(holder.dataset.key);
    const action = btn.dataset.action;
    if (action === 'reroll') return reroll();
    if (action === 'more-options') {
      shownOptions += OPTIONS_PAGE;
      return renderRecommendation();
    }
    if (!item) return;

    if (action === 'open') {
      openDetail(item);
    } else if (action === 'watchlist') {
      const added = toggleWatchlist(item);
      syncButtons(item);
      toast(added ? 'Agregada a Mi lista ♥' : 'Quitada de Mi lista');
      if (currentTab === 'lista') renderWatchlist();
    } else if (action === 'seen' || action === 'dismiss') {
      const added = toggleIn(action === 'seen' ? 'seen' : 'dismissed', itemKey(item));
      syncButtons(item);
      if (added) {
        toast(action === 'seen' ? 'Marcada como vista: no la volveremos a recomendar' : 'Descartada: no la volveremos a recomendar');
        if (holder.closest('#detail')) $('#detail').close();
        removeFromPool(item);
      }
    }
  });

  // Cerrar diálogos al tocar fuera
  $$('dialog').forEach((dlg) => dlg.addEventListener('click', (e) => { if (e.target === dlg) dlg.close(); }));

  $('#recommend-btn').addEventListener('click', recommend);
  $('#rec-result').addEventListener('change', onRecToolbarChange);
  $('#min-rating').addEventListener('change', (e) => setFilter({ minRating: Number(e.target.value) }));
  $('#year').innerHTML = YEARS.map((y) => `<option value="${y.id}">${y.label}</option>`).join('');
  $('#year').addEventListener('change', (e) => setFilter({ year: e.target.value }));
  $('#only-mine').addEventListener('change', (e) => setOnlyMine(e.target.checked));

  let searchTimer;
  $('#search-input').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      searchQuery = e.target.value.trim();
      if (searchQuery.length >= 2) searchList.load();
      else searchList.reset();
    }, 350);
  });

  // Configuración
  $('#country').innerHTML = Object.entries(COUNTRIES)
    .sort((a, b) => a[1].localeCompare(b[1], 'es'))
    .map(([code, name]) => `<option value="${code}">${name}</option>`).join('');
  $('#settings-form').addEventListener('submit', saveSettings);
  $('#country').addEventListener('change', (e) =>
    renderProviderChoices($('#providers-grid'), e.target.value, $('#providers-grid').selected));
  $('#platforms-form').addEventListener('submit', savePlatforms);
  // Casillas de plataformas (en Configuración y en el selector rápido).
  $$('.providers-grid').forEach((grid) => grid.addEventListener('change', (e) => {
    const id = Number(e.target.value);
    if (e.target.checked) grid.selected.add(id);
    else grid.selected.delete(id);
  }));
  $$('.providers-filter').forEach((input) => input.addEventListener('input', () => {
    const q = input.value.trim().toLowerCase();
    $$('.pchoice', $(`#${input.dataset.filterFor}`)).forEach((el) => { el.hidden = q && !el.dataset.name.includes(q); });
  }));

  // Tutorial
  $('#tutorial-next').addEventListener('click', tutorialNext);
  $('#tutorial-prev').addEventListener('click', () => {
    tutorialStep = Math.max(0, tutorialStep - 1);
    renderTutorial();
  });
  // Se marca como visto al cerrarlo de cualquier forma (✕, atrás, ¡Empezar!).
  $('#tutorial').addEventListener('close', () => {
    if (!state.tutorialSeen) {
      state.tutorialSeen = true;
      save();
    }
  });

  $('#reset-lists').addEventListener('click', () => {
    state.seen = [];
    state.dismissed = [];
    save();
    toast('Listo: se olvidaron las vistas y descartadas');
  });
}

// Botón "atrás" de Android (solo existe dentro de la app nativa).
function bindAndroidBack() {
  const nativeApp = window.Capacitor?.Plugins?.App;
  if (!nativeApp?.addListener) return;
  nativeApp.addListener('backButton', () => {
    const open = $$('dialog[open]').pop();
    if (open) open.close();
    else if (currentTab !== 'recomienda') showTab('recomienda');
    else nativeApp.exitApp();
  });
}

// Alto del encabezado fijo, para que la barra de opciones quede justo debajo.
function measureTopbar() {
  document.documentElement.style.setProperty('--topbar-h', `${$('.topbar').offsetHeight}px`);
}

bindEvents();
bindAndroidBack();
measureTopbar();
window.addEventListener('resize', measureTopbar);
initAds();
initClient().then(() => {
  if (!state.tutorialSeen) openTutorial();
});
