
网页托管版使用说明
====================
把本文件夹直接部署到任意静态托管平台即可（支持离线缓存）：

- **Netlify**：登录 Netlify，使用「Deploy a site → Drag and Drop」，把整个文件夹拖进去即可。
- **GitHub Pages**：新建仓库，上传全部文件 → Settings → Pages → 选择 `main` / `/ (root)`，保存。几分钟后生效。
- **Cloudflare Pages**：创建项目 → 选择「Direct Upload」→ 上传整个文件夹。
- **Vercel**：New Project → Import → 选择仓库（或用「Vercel CLI」直接上传静态目录）。

注意：
1) `manifest.webmanifest` 的 `start_url` 为 `.`，支持子路径部署（如 `https://域名/你的路径/`）。
2) 这是纯前端应用，数据保存在浏览器本地（localStorage）。
3) 首次打开已内置示例食材与 5 个示例菜谱，便于体验。
