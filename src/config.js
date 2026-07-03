export const CUSTOM_AI = {
  URL: 'https://api.groq.com/openai/v1/chat/completions',
  KEY: '',
  MODEL: 'qwen/qwen3-32b',
  VISION_MODEL: 'meta-llama/llama-4-scout-17b-16e-instruct'
};

// ── 后端 API 基址 ──────────────────────────────────────────────────────────
// 同源部署（Render 全栈 / 本地 node server.js）：留空，走相对路径。
// GitHub Pages 等纯静态托管没有 /api 后端：自动指向 Render 服务，
// 由 server.js 的 CORS 白名单放行 github.io 来源。
const RENDER_API_BASE = 'https://kitchenmanager-b8px.onrender.com';

export const API_BASE = (typeof location !== 'undefined' && /\.github\.io$/i.test(location.hostname))
  ? RENDER_API_BASE
  : '';

// 统一拼接 API 地址：所有前端 /api 调用都必须经过这里，别再写裸的 fetch('/api/...')。
export function apiUrl(path) {
  return `${API_BASE}${path}`;
}
