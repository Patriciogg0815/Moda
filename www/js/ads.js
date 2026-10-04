// Publicidad AdMob (solo dentro de la app Android; en el navegador no hace nada).
// Banner fijo abajo + intersticial (pantalla completa) al tocar botones o enlaces.

// IDs de los bloques de anuncios. Ahora son los IDs de PRUEBA oficiales de Google:
// muestran anuncios de ejemplo y no generan ingresos. Para ganar dinero, crea la app
// "QuéVeo" en https://admob.google.com y reemplázalos por los tuyos. El ID de la app
// (el que tiene "~") va en android/app/src/main/res/values/strings.xml.
const ADMOB = {
  banner: 'ca-app-pub-3940256099942544/9214589741',
  interstitial: 'ca-app-pub-3940256099942544/1033173712',
};

// Tiempo mínimo entre dos intersticiales. Mostrar uno en cada toque hace que la
// app sea molesta de usar y va contra las políticas de AdMob (riesgo de que
// suspendan la cuenta), así que se limita igual que en Convertir.ec.
const MIN_GAP_MS = 45_000;

export function initAds() {
  const AdMob = window.Capacitor?.Plugins?.AdMob;
  if (!AdMob || !window.Capacitor.isNativePlatform?.()) return;

  let interReady = false;
  // El primer intersticial tampoco sale apenas se abre la app.
  let lastInter = Date.now();

  const prepareInter = () => {
    interReady = false;
    AdMob.prepareInterstitial({ adId: ADMOB.interstitial })
      .then(() => { interReady = true; })
      .catch(() => {});
  };

  // Deja espacio abajo para que el banner no tape el contenido (alto en dp = px CSS).
  AdMob.addListener('bannerAdSizeChanged', ({ height }) => {
    document.documentElement.style.setProperty('--ad-h', `${height || 0}px`);
  });
  AdMob.addListener('interstitialAdDismissed', prepareInter);
  AdMob.addListener('interstitialAdFailedToShow', prepareInter);

  AdMob.initialize({}).then(() => {
    AdMob.showBanner({
      adId: ADMOB.banner,
      adSize: 'ADAPTIVE_BANNER',
      position: 'BOTTOM_CENTER',
      margin: 0,
    }).catch(() => {});
    prepareInter();
  }).catch(() => {});

  const showInterstitial = () => {
    const now = Date.now();
    if (!interReady || now - lastInter < MIN_GAP_MS) return;
    lastInter = now;
    interReady = false;
    AdMob.showInterstitial().catch(prepareInter);
  };

  // Cualquier toque en un botón o enlace puede mostrar el intersticial,
  // menos dentro de Configuración (para no interrumpir mientras se escribe la API key).
  document.addEventListener('click', (e) => {
    const target = e.target.closest?.('a, button');
    if (target && !target.closest('#settings')) showInterstitial();
  }, true);
}
