// km · service worker · v16
const CACHE_NAME = 'km-v16';
const CORE = ['./','./index.html','./styles.css','./app.js','./ingredients-list-patch.v15.css','./ingredients-list-patch.v15.js','./data/sichuan-recipes.json'];
self.addEventListener('install',(e)=>{self.skipWaiting();e.waitUntil(caches.open(CACHE_NAME).then(c=>c.addAll(CORE)).catch(()=>{}));});
self.addEventListener('activate',(e)=>{e.waitUntil((async()=>{const ns=await caches.keys();await Promise.all(ns.filter(n=>n!==CACHE_NAME).map(n=>caches.delete(n)));await self.clients.claim();})());});
function isHTML(req){return req.mode==='navigate'||(req.headers.get('accept')||'').includes('text/html');}
self.addEventListener('fetch',(e)=>{const req=e.request;const url=new URL(req.url);if(url.origin!==location.origin)return;
  if(isHTML(req)){e.respondWith((async()=>{try{const net=await fetch(req);const c=await caches.open(CACHE_NAME);c.put('./index.html',net.clone());return net;}catch{const c=await caches.open(CACHE_NAME);const cached=await c.match('./index.html');return cached||new Response('<h1>Offline</h1>',{status:200,headers:{'Content-Type':'text/html'}});}})());return;}
  e.respondWith((async()=>{const c=await caches.open(CACHE_NAME);const cached=await c.match(req);const fetching=fetch(req).then(res=>{if(res&&res.ok)c.put(req,res.clone());return res;}).catch(()=>cached);return cached||fetching;})());
});