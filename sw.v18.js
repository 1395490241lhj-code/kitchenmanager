const CACHE_NAME = 'km-v236';
const CORE = [
  './',
  './index.html',
  './styles.css?v=236',
  './app.js?v=236',
  './ingredients-list-patch.v15.css?v=236',
  './ingredients-list-patch.v15.js?v=236',
  './data/sichuan-recipes.curated.json',
  './data/sichuan-recipes.json'
];

self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(CORE)).catch(() => {}));
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(name => name !== CACHE_NAME).map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

function isHtmlRequest(request) {
  return request.mode === 'navigate' || (request.headers.get('accept') || '').includes('text/html');
}

function isFreshAsset(request) {
  const url = new URL(request.url);
  return request.destination === 'script'
    || request.destination === 'style'
    || request.destination === 'worker'
    || /\.(js|css)$/.test(url.pathname);
}

// 同源 data/*.json（菜谱库 + 补全 overlay）：走 networkFirst，保证在线总是最新，
// 离线回退到上次缓存。避免 overlay 更新后被 cacheFirst 持续喂旧内容。
function isDataJson(request) {
  const url = new URL(request.url);
  return /\/data\/.*\.json$/.test(url.pathname);
}

async function networkFirst(request, fallbackKey = request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const fresh = await fetch(request);
    if (fresh && fresh.ok) cache.put(fallbackKey, fresh.clone());
    return fresh;
  } catch (error) {
    const cached = await cache.match(fallbackKey);
    if (cached) return cached;
    throw error;
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  if (cached) return cached;
  const fresh = await fetch(request);
  if (fresh && fresh.ok) cache.put(request, fresh.clone());
  return fresh;
}

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== location.origin) return;

  // API 请求永不经过缓存：否则兜底的 cacheFirst 会把 GET /api/ai-status 永久钉死
  // （fetch 的 cache:'no-store' 只绕 HTTP 缓存、绕不过 SW），而对 POST 调用
  // cache.put 会抛出未处理的 rejection（Cache API 只支持 GET）。直接放行给网络。
  if (/\/api\//.test(url.pathname)) return;

  if (isHtmlRequest(request)) {
    event.respondWith(networkFirst(request, './index.html').catch(() => new Response('<h1>Offline</h1>', {
      status: 200,
      headers: { 'Content-Type': 'text/html' }
    })));
    return;
  }

  if (isFreshAsset(request) || isDataJson(request)) {
    event.respondWith(networkFirst(request));
    return;
  }

  event.respondWith(cacheFirst(request));
});
