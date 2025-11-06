// km · service worker · v16
const CACHE_NAME = 'km-v16';
const CORE = [
  './',
  './index.html',
  './styles.css',
  './app.js',
  './ingredients-list-patch.v14.css',
  './ingredients-list-patch.v14.js',
  './data/sichuan-recipes.json'
];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(
    (async () => {
      try {
        const cache = await caches.open(CACHE_NAME);
        await cache.addAll(CORE);
      } catch (err) {
        // ignore precache failures
      }
    })()
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(n => n !== CACHE_NAME).map(n => caches.delete(n)));
    await self.clients.claim();
  })());
});

function isHTML(req) {
  return req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html');
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return; // pass-through cross-origin

  if (isHTML(req)) {
    // Network-first for HTML to avoid showing a blank cached page
    e.respondWith((async () => {
      try {
        const net = await fetch(req);
        const cache = await caches.open(CACHE_NAME);
        cache.put('./index.html', net.clone());
        return net;
      } catch (err) {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match('./index.html');
        return cached || new Response('<h1>Offline</h1>', {status:200, headers:{'Content-Type':'text/html'}});
      }
    })());
    return;
  }

  // Stale-while-revalidate for assets / data
  e.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(req);
    const fetching = fetch(req).then(res => {
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    }).catch(() => cached);
    return cached || fetching;
  })());
});