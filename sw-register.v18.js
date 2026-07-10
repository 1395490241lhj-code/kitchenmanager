(function () {
  if (!('serviceWorker' in navigator)) return;

  const VERSION = 'v18';
  const KEY = 'km-sw-' + VERSION;

  // 只负责注销脚本地址对不上当前 sw.v18.js 的旧 Service Worker 注册，不碰缓存。
  // 缓存清理完全交给 sw.v18.js 的 activate 事件独占处理（它按当前 CACHE_NAME 动态
  // 判断该删哪些旧缓存）。这里绝不能再用固定字符串保留缓存——CACHE_NAME 会随
  // scripts/stamp-version.js 升版变化，写死在这里的话，每次升版都会把刚预缓存好的
  // 当前缓存当成"旧缓存"删掉，导致离线预缓存不可靠。
  async function clearOldWorkers() {
    const regs = await navigator.serviceWorker.getRegistrations();
    for (const reg of regs) {
      const url = (reg.active && reg.active.scriptURL) || (reg.waiting && reg.waiting.scriptURL) || (reg.installing && reg.installing.scriptURL) || '';
      if (!/sw\.v18\.js/.test(url)) {
        try { await reg.unregister(); } catch (_) {}
      }
    }
  }

  async function registerFreshWorker() {
    await clearOldWorkers();
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
    clearOldWorkers().catch(() => {});
    return;
  }

  registerFreshWorker().catch(() => {});
})();
