const CACHE_NAME = 'cultura-gto-cache-v1';
const RECURSOS_APP = [
  './',
  './index.html',
  './admin.html',
  './manifest.json',
  './Logo-Gobierno-de-la-Gente-de-Guanajuato-v2.001 (1).png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js',
  'https://cdn.jsdelivr.net/npm/chart.js',
  'https://cdn.jsdelivr.net/npm/sweetalert2@11',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
  'https://fonts.googleapis.com/css2?family=Vollkorn:wght@600;700;900&family=Inter:wght@400;500;600;700&display=swap'
];

// Instalación: Cachear archivos base
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(RECURSOS_APP))
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