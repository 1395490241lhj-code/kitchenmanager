/*
 * server.js —— Kitchen Manager 全栈一体化服务器
 *
 * - 用 Express 静态托管前端（本项目无构建步骤，index.html 在仓库根目录，直接托管根目录）。
 * - /api/xhs-extract：服务端抓取小红书/网页菜谱文案，绕过浏览器 CORS。
 *     跟随 302 短链（xhslink.com → 真实长链）、伪造移动端 UA、正则提取
 *     window.__INITIAL_STATE__ / og:title / description 等文案，返回纯文本 JSON。
 *
 * 启动：npm install && npm start  （默认 http://localhost:3000）
 */
const path = require('path');
const express = require('express');
const axios = require('axios');

const app = express();
const ROOT = __dirname;
const PORT = process.env.PORT || 3000;

const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1';

// 从小红书/网页源码尽力提取菜谱文案（与原 ai.js 中逻辑一致，移植到服务端）。
function extractXhsText(html) {
  const parts = [];
  const push = (v) => { const s = String(v || '').trim(); if (s) parts.push(s); };

  const og = html.match(/<meta[^>]+(?:property|name)=["']og:title["'][^>]*content=["']([^"']+)["']/i);
  if (og) push(og[1]);
  const desc = html.match(/<meta[^>]+name=["']description["'][^>]*content=["']([^"']+)["']/i);
  if (desc) push(desc[1]);

  const state = html.match(/window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\})\s*<\/script>/);
  const blob = state ? state[1] : html;
  const fields = blob.match(/"(?:desc|title|content|noteText)":"((?:[^"\\]|\\.)*)"/g) || [];
  fields.forEach(f => push(f.replace(/^"[^"]+":"/, '').replace(/"$/, '')));

  const seen = new Set();
  return parts
    .map(s => s
      .replace(/\\u[0-9a-fA-F]{4}/g, m => String.fromCharCode(parseInt(m.slice(2), 16)))
      .replace(/\\n/g, '\n')
      .replace(/\\"/g, '"')
      .trim())
    .filter(s => s && !seen.has(s) && seen.add(s))
    .join('\n');
}

// 代理路由：抓取并返回菜谱文案。
app.get('/api/xhs-extract', async (req, res) => {
  const url = String(req.query.url || '').trim();
  if (!url) return res.status(400).json({ error: '缺少 url 参数。' });
  if (!/^https?:\/\//i.test(url)) return res.status(400).json({ error: '仅支持 http/https 链接。' });

  try {
    const resp = await axios.get(url, {
      maxRedirects: 5,                 // 跟随 302，把 xhslink.com 短链解析为真实长链
      timeout: 12000,
      responseType: 'text',
      transformResponse: r => r,       // 保留原始 HTML 字符串
      headers: {
        'User-Agent': MOBILE_UA,       // 伪造移动端 UA，避免被直接拦截
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      validateStatus: s => s >= 200 && s < 400
    });

    const html = String(resp.data || '');
    if (/验证码|滑块验证|滑动验证|安全验证|captcha/i.test(html) && !/__INITIAL_STATE__/.test(html)) {
      return res.status(502).json({ error: '链接被验证码拦截，请改用文字或截图导入。' });
    }

    const text = extractXhsText(html);
    if (!text || text.length < 6) {
      return res.status(422).json({ error: '没能从链接里提取到菜谱文案，请改用文字或截图导入。' });
    }

    const finalUrl = (resp.request && resp.request.res && resp.request.res.responseUrl) || url;
    return res.json({ text, finalUrl });
  } catch (err) {
    const status = err.response && err.response.status;
    const msg = status ? `链接抓取失败（${status}），请改用文字或截图导入。` : '链接抓取失败，请改用文字或截图导入。';
    return res.status(502).json({ error: msg });
  }
});

// 静态托管前端（仓库根目录即站点根）。
app.use(express.static(ROOT, { extensions: ['html'] }));

// 兜底：未匹配的页面请求返回首页（哈希路由由前端处理）。
app.get('*', (req, res) => {
  if (req.path.startsWith('/api/')) return res.status(404).json({ error: 'Not found' });
  res.sendFile(path.join(ROOT, 'index.html'));
});

// 绑定 0.0.0.0：Render 等云平台要求监听所有网卡，并通过 process.env.PORT 注入端口。
app.listen(PORT, '0.0.0.0', () => {
  console.log(`🍳 Kitchen Manager 全栈服务已启动，端口 ${PORT}`);
});
