(function () {
  if (!('serviceWorker' in navigator)) return;

  const VERSION = 'v18';
  const KEY = 'km-sw-' + VERSION;

  async function clearOldWorkersAndCaches() {
    const regs = await navigator.serviceWorker.getRegistrations();
    for (const reg of regs) {
      const url = (reg.active && reg.active.scriptURL) || (reg.waiting && reg.waiting.scriptURL) || (reg.installing && reg.installing.scriptURL) || '';
      if (!/sw\.v18\.js/.test(url)) {
        try { await reg.unregister(); } catch (_) {}
      }
    }
    if (window.caches && caches.keys) {
      const keys = await caches.keys();
      await Promise.all(keys.filter(key => key !== 'km-v18').map(key => caches.delete(key)));
    }
  }

  async function registerFreshWorker() {
    await clearOldWorkersAndCaches();
    const reg = await navigator.serviceWorker.register('./sw.v18.js?v=' + VERSION, { scope: './' });
    reg.update().catch(() => {});

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
    if (reg.waiting && !reloaded) {
      localStorage.setItem(KEY, '1');
      location.reload();
      return;
    }
    reg.addEventListener('updatefound', () => reloadAfterActivate(reg.installing));
    setTimeout(() => localStorage.setItem(KEY, '1'), 4000);
  }

  if (location.hash.includes('sw=off')) {
    clearOldWorkersAndCaches().catch(() => {});
    return;
  }

  registerFreshWorker().catch(() => {});
})();
