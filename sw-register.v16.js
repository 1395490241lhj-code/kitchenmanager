// Force-register the v16 SW once and reload
(function(){
  if(!('serviceWorker' in navigator)) return;
  const VERSION='v16';
  const KEY='km-sw-'+VERSION;

  if (location.hash.includes('sw=off')) {
    navigator.serviceWorker.getRegistrations().then(regs => regs.forEach(r=>r.unregister()));
    if (window.caches && caches.keys) caches.keys().then(keys => keys.forEach(k=>caches.delete(k)));
    console.log('[SW] disabled via #sw=off');
    return;
  }

  navigator.serviceWorker.getRegistrations().then(async regs => {
    for (const r of regs) {
      const url = (r.active && r.active.scriptURL) || '';
      if (!/sw\.v16\.js/.test(url)) { try{ await r.unregister(); }catch(_){} }
    }
    try{
      const reg = await navigator.serviceWorker.register('./sw.v16.js?v='+VERSION, {scope:'./'});
      if (!localStorage.getItem(KEY)) {
        let reloaded = false;
        const listen = (w) => {
          if (!w) return;
          w.addEventListener('statechange', () => {
            if (w.state === 'activated' && !reloaded) {
              reloaded = true;
              localStorage.setItem(KEY,'1');
              location.reload();
            }
          });
        };
        if (reg.installing) listen(reg.installing);
        reg.addEventListener('updatefound', () => listen(reg.installing));
        setTimeout(()=>localStorage.setItem(KEY,'1'), 4000);
      }
    }catch(e){ console.warn('[SW] register failed', e); }
  });
})();