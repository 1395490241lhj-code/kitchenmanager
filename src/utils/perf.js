/*
 * src/utils/perf.js —— 轻量性能标记（零依赖，默认完全静默）。
 *
 * 只有 URL 带 ?debugPerf=1 时才输出（如 http://localhost:3000/?debugPerf=1#today）；
 * 生产/日常使用零开销路径：未启用时 perfMeasure 直接透传调用，不取时间戳。
 */
const enabled = typeof location !== 'undefined' && /[?&]debugPerf=1/.test(location.search || '');

export function perfEnabled() { return enabled; }

// 打一个时间点标记。
export function perfMark(label) {
  if (!enabled) return;
  console.log(`[perf] ${label} @ ${performance.now().toFixed(1)}ms`);
}

// 同步测量：返回 fn() 的返回值。
export function perfMeasure(label, fn) {
  if (!enabled) return fn();
  const t0 = performance.now();
  try {
    return fn();
  } finally {
    console.log(`[perf] ${label}: ${(performance.now() - t0).toFixed(1)}ms`);
  }
}

// 异步测量：返回 await fn() 的结果。
export async function perfMeasureAsync(label, fn) {
  if (!enabled) return fn();
  const t0 = performance.now();
  try {
    return await fn();
  } finally {
    console.log(`[perf] ${label}: ${(performance.now() - t0).toFixed(1)}ms`);
  }
}

// 调用频率计数（如 loadShoppingItems / saveShoppingItems）：启用时每次调用打印累计次数。
const counters = new Map();
export function perfCount(label) {
  if (!enabled) return;
  const n = (counters.get(label) || 0) + 1;
  counters.set(label, n);
  console.log(`[perf] count ${label}: ×${n}`);
}
