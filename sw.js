
const CACHE = 'kitchen-cache-v5';
const ASSETS = [
  './','./index.html','./index.html?v=5','./styles.css','./styles.css?v=5',
  './app.js','./app.js?v=5','./sichuan-loader.js','./sichuan-loader.js?v=5',
  './manifest.webmanifest','./manifest.webmanifest?v=5',
  './icons/pwa-192.png','./icons/pwa-512.png','./icons/maskable-192.png','./icons/maskable-512.png','./icons/apple-touch-180.png',
  './data/sichuan-recipes.json','./data/sichuan-recipes.json?v=5'
];
self.addEventListener('install', e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting()));
});
self.addEventListener('activate', e=>{
  e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch', e=>{
  const url = new URL(e.request.url);
  const isAsset = ASSETS.some(a => (new URL(a, location.href)).pathname === url.pathname);
  if (isAsset){
    e.respondWith(caches.match(e.request).then(r=> r || caches.match(url.pathname)).then(r=> r || fetch(e.request)));
    return;
  }
  e.respondWith(fetch(e.request).then(res=>{ const copy=res.clone(); caches.open(CACHE).then(c=>c.put(e.request, copy)); return res; }).catch(()=>caches.match(e.request)));
});
