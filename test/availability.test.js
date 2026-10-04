import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyAvailability, isInCinemas, availabilityLabel, ratingTone, shuffle } from '../js/availability.js';

const netflix = { provider_id: 8, provider_name: 'Netflix', display_priority: 1 };
const prime = { provider_id: 119, provider_name: 'Amazon Prime Video', display_priority: 2 };
const apple = { provider_id: 2, provider_name: 'Apple TV', display_priority: 3 };
const today = new Date('2026-10-04T12:00:00Z');

test('streaming: detecta plataformas de suscripción y las del usuario', () => {
  const av = classifyAvailability(
    { link: 'https://x', flatrate: [prime, netflix], buy: [apple] },
    { mediaType: 'movie', id: 1, today, myProviderIds: new Set([119]) },
  );
  assert.equal(av.kind, 'streaming');
  assert.deepEqual(av.stream.map((p) => p.provider_id), [8, 119]); // ordenadas por prioridad
  assert.deepEqual(av.mine.map((p) => p.provider_id), [119]);
  assert.equal(av.link, 'https://x');
  assert.equal(availabilityLabel(av, 'Chile'), 'En tu Amazon Prime Video');
});

test('streaming: elimina duplicados entre flatrate, free y ads', () => {
  const av = classifyAvailability({ flatrate: [netflix], ads: [netflix] }, { mediaType: 'tv', id: 2, today });
  assert.equal(av.stream.length, 1);
});

test('solo alquiler/compra', () => {
  const av = classifyAvailability({ rent: [apple] }, { mediaType: 'movie', id: 3, today });
  assert.equal(av.kind, 'rent');
});

test('película sin plataformas y en cartelera → cine', () => {
  const av = classifyAvailability(undefined, { mediaType: 'movie', id: 4, today, nowPlayingIds: new Set([4]) });
  assert.equal(av.kind, 'cinema');
  assert.equal(availabilityLabel(av, 'Chile'), 'En cines');
});

test('película sin plataformas estrenada hace poco → cine', () => {
  const av = classifyAvailability({}, { mediaType: 'movie', id: 5, releaseDate: '2026-09-01', today });
  assert.equal(av.kind, 'cinema');
});

test('película antigua sin plataformas → sin plataforma', () => {
  const av = classifyAvailability({}, { mediaType: 'movie', id: 6, releaseDate: '1999-01-01', today });
  assert.equal(av.kind, 'none');
  assert.equal(availabilityLabel(av, 'Chile'), 'Sin plataforma en Chile');
});

test('una serie nunca se marca como "en cines"', () => {
  const av = classifyAvailability({}, { mediaType: 'tv', id: 7, releaseDate: '2026-09-20', today, nowPlayingIds: new Set([7]) });
  assert.equal(av.kind, 'none');
});

test('isInCinemas maneja fechas vacías o inválidas', () => {
  assert.equal(isInCinemas({ id: 1, releaseDate: '', today }), false);
  assert.equal(isInCinemas({ id: 1, releaseDate: 'xx', today }), false);
  assert.equal(isInCinemas({ id: 1, releaseDate: '2026-10-08', today }), true); // preestreno
  assert.equal(isInCinemas({ id: 1, releaseDate: '2027-01-01', today }), false);
});

test('ratingTone', () => {
  assert.equal(ratingTone(0), 'none');
  assert.equal(ratingTone(8.1), 'good');
  assert.equal(ratingTone(6), 'ok');
  assert.equal(ratingTone(4.2), 'bad');
});

test('shuffle no muta y conserva elementos', () => {
  const src = [1, 2, 3, 4, 5];
  const out = shuffle(src, () => 0);
  assert.deepEqual(src, [1, 2, 3, 4, 5]);
  assert.deepEqual([...out].sort(), src);
});
