// test/helpers/localstorage-stub.mjs
// 内存版 localStorage，仅供 node:test 使用。安装到 globalThis.localStorage，
// 让 src/storage.js 的 S.save/S.load 在 Node 环境下可运行。零依赖、零真实存储。
//
// 用法：
//   import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
//   beforeEach(() => { installLocalStorageStub(); resetLocalStorage(); });

const store = new Map();

export const memoryLocalStorage = {
  getItem(key) {
    const k = String(key);
    return store.has(k) ? store.get(k) : null; // 缺失 key 返回 null
  },
  setItem(key, value) {
    store.set(String(key), String(value)); // 统一转字符串（与浏览器一致）
  },
  removeItem(key) {
    store.delete(String(key));
  },
  clear() {
    store.clear();
  },
  key(index) {
    const keys = Array.from(store.keys());
    return index >= 0 && index < keys.length ? keys[index] : null;
  },
  get length() {
    return store.size;
  }
};

// 安装到全局，让 src 代码里的裸 `localStorage` 引用生效。
export function installLocalStorageStub() {
  globalThis.localStorage = memoryLocalStorage;
  return memoryLocalStorage;
}

// 清空内存（每个用例前调用，避免相互污染）。
export function resetLocalStorage() {
  store.clear();
}

// 可选：直接灌入键值（对象会 JSON 序列化，模拟 S.save 写入的字符串形态）。
export function seed(map) {
  for (const [k, v] of Object.entries(map || {})) {
    store.set(String(k), typeof v === 'string' ? v : JSON.stringify(v));
  }
}

// 可选：导出当前内存快照（调试用）。
export function dump() {
  return Object.fromEntries(store);
}
