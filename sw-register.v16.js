(function () {
  if (!('serviceWorker' in navigator)) return;

  const VERSION = 'v16';
  const KEY = 'km-sw-' + VERSION;

  if (location.hash.includes('sw=off')) {
    navigator.serviceWorker.getRegistrations().then(regs => regs.forEach(reg => reg.unregister()));
    if (window.caches && caches.keys) caches.keys().then(keys => keys.forEach(key => caches.delete(key)));
    return;
  }

  navigator.serviceWorker.getRegistrations().then(async regs => {
    for (const reg of regs) {
      const url = (reg.active && reg.active.scriptURL) || '';
      if (!/sw\.v16\.js/.test(url)) {
        try { await reg.unregister(); } catch (_) {}
      }
    }

    try {
      const reg = await navigator.serviceWorker.register('./sw.v16.js?v=' + VERSION, { scope: './' });
      if (localStorage.getItem(KEY)) return;

      let reloaded = false;
      const reloadAfterActivate = worker => {
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'activated' && !reloaded) {
            reloaded = true;
            localStorage.setItem(KEY, '1');
            location.reload();
          }
        });
      };

      if (reg.installing) reloadAfterActivate(reg.installing);
      reg.addEventListener('updatefound', () => reloadAfterActivate(reg.installing));
      setTimeout(() => localStorage.setItem(KEY, '1'), 4000);
    } catch (e) {}
  });
})();
