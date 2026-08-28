const CACHE_NAME = 'cultura-gto-cache-v6-5-1';
const RECURSOS_APP = [
  './',
  './index.html',
  './admin.html',
  './manifest.json.json',
  './Logo-Gobierno-de-la-Gente-de-Guanajuato-v2.001 (1).png',
  './js/importer.js',
  './js/importer-smart.js'
];

// Instalación: Cachear archivos base
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.allSettled(RECURSOS_APP.map((recurso) => cache.add(recurso)))
    )
  );
  self.skipWaiting();
});

// Activación: Limpieza de cachés viejos
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.map((k) => {
          if (k !== CACHE_NAME) return caches.delete(k);
        })
      )
    )
  );
  self.clients.claim();
});

// Estrategia: Network-first con fallback a caché offline
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        const clon = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(e.request, clon));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
