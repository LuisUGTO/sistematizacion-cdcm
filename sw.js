const CACHE_VERSION = "vinculacion-cultural-7-7-8b-1";
const STATIC_CACHE = `${CACHE_VERSION}-static`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;

// Esta versión protege el trabajo que ya está abierto. No almacena sesiones,
// contraseñas, llamadas a la base institucional ni evidencias.
const REQUIRED_SHELL = [
  "./index.html",
  "./offline.html",
  "./manifest.webmanifest",
  "./assets/pwa/icon-180.png",
  "./assets/pwa/icon-192.png",
  "./assets/pwa/icon-512.png",
  "./assets/pwa/icon-maskable-512.png",
  "./js/auth.js",
  "./js/config.js",
  "./js/supabase-client.js",
  "./js/permissions.js",
  "./js/capture.js",
  "./js/catalogs.js",
  "./js/evidence.js",
  "./js/bitacora.js",
  "./js/draft-editor.js",
  "./js/validation.js",
  "./js/dashboard.js",
  "./js/home-content.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then((cache) => cache.addAll(REQUIRED_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key.startsWith("vinculacion-cultural-") && ![STATIC_CACHE, RUNTIME_CACHE].includes(key))
          .map((key) => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

async function cachedIgnoringVersion(request) {
  const staticCache = await caches.open(STATIC_CACHE);
  const runtimeCache = await caches.open(RUNTIME_CACHE);

  return (await staticCache.match(request, { ignoreSearch: true })) ||
    runtimeCache.match(request, { ignoreSearch: true });
}

async function networkFirst(request) {
  const cache = await caches.open(RUNTIME_CACHE);

  try {
    const response = await fetch(request);
    if (response.ok) cache.put(request, response.clone());
    return response;
  } catch (error) {
    const cached = await cachedIgnoringVersion(request);
    if (cached) return cached;
    throw error;
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(RUNTIME_CACHE);
  const cached = await cachedIgnoringVersion(request);
  const fresh = fetch(request)
    .then((response) => {
      if (response.ok) cache.put(request, response.clone());
      return response;
    })
    .catch(() => null);

  return cached || fresh;
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(
      networkFirst(request).catch(() => caches.match("./offline.html"))
    );
    return;
  }

  const isStaticAsset = ["image", "font", "style", "script"].includes(request.destination) ||
    url.pathname.includes("/assets/") ||
    url.pathname.endsWith(".webmanifest");

  event.respondWith(
    isStaticAsset ? staleWhileRevalidate(request) : networkFirst(request)
  );
});
