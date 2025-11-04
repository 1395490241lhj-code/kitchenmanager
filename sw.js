
const CACHE = 'kitchen-cache-v4';
const ASSETS = [
  './','./index.html','./index.html?v=4',
  './app.js','./app.js?v=4',
  './sichuan-loader.js','./sichuan-loader.js?v=4',
  './manifest.webmanifest','./manifest.webmanifest?v=4',
  './styles.css','./styles.css?v=4','./data/sichuan-recipes.json','./data/sichuan-recipes.json?v=4'
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
  if(isAsset){
    e.respondWith(caches.match(e.request).then(r => r || caches.match(url.pathname)).then(r => r || fetch(e.request)));
  }else{
    e.respondWith(fetch(e.request).then(res=>{ const copy=res.clone(); caches.open(CACHE).then(c=>c.put(e.request, copy)); return res; }).catch(()=>caches.match(e.request)));
  }
});
