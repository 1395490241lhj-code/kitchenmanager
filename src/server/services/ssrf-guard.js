/*
 * src/server/services/ssrf-guard.js —— 出站抓取的 SSRF 加固（安全关键，勿放宽）：私网/元数据网段硬拒绝、DNS 钉死、逐跳重定向校验。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */
const net = require('net');
const http = require('http');
const https = require('https');
const dns = require('dns').promises;
const axios = require('axios');
const {
  MOBILE_UA
} = require('../config');

// ── SSRF 加固：阻止抓取 localhost / 私网 / 链路本地 / 云元数据，含 DNS 解析与逐跳重定向校验 ──
const SSRF_ERROR = new Error('BLOCKED_URL'); // 统一对外泛化文案，不泄露内部细节

// 从用户输入里抽出一个 http(s) URL（兼容整段分享语）。
function extractHttpUrl(input) {
  const raw = String(input || '').trim();
  const m = raw.match(/https?:\/\/[^\s]+/i);
  const candidate = m ? m[0].replace(/[，。、,.;；]+$/, '') : raw;
  if (!/^https?:\/\//i.test(candidate)) return null;
  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u;
  } catch (_) { return null; }
}

// 主机名层面的硬拒绝（localhost 及其子域）。
function isBlockedHostname(hostname) {
  const h = String(hostname || '').trim().toLowerCase().replace(/\.$/, '');
  if (!h) return true;
  if (h === 'localhost' || h.endsWith('.localhost')) return true;
  return false;
}

// 归一化 IP：去掉 IPv6 方括号 / zone id，IPv4-mapped IPv6（::ffff:a.b.c.d）拆出内嵌 v4。
function normalizeIp(ip) {
  let s = String(ip || '').trim().replace(/^\[/, '').replace(/\]$/, '');
  const pct = s.indexOf('%'); // 去掉 zone id（fe80::1%eth0）
  if (pct >= 0) s = s.slice(0, pct);
  // IPv4-mapped IPv6（点分形式）：::ffff:127.0.0.1 → 127.0.0.1
  const mappedDotted = s.match(/^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i);
  if (mappedDotted) return mappedDotted[1];
  // IPv4-mapped IPv6（十六进制形式，URL 解析后常见）：::ffff:7f00:1 → 127.0.0.1
  const mappedHex = s.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i);
  if (mappedHex) {
    const hi = parseInt(mappedHex[1], 16), lo = parseInt(mappedHex[2], 16);
    return [(hi >> 8) & 255, hi & 255, (lo >> 8) & 255, lo & 255].join('.');
  }
  return s;
}

// 判定 IP 是否落在被禁网段（环回 / 私网 / 链路本地 / CGNAT / 云元数据 / ULA 等）。
function isBlockedIp(rawIp) {
  const ip = normalizeIp(rawIp);
  const fam = net.isIP(ip);
  if (fam === 4) {
    const p = ip.split('.').map(Number);
    if (p.length !== 4 || p.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return true;
    const [a, b] = p;
    if (a === 0) return true;                         // 0.0.0.0/8（含 unspecified）
    if (a === 127) return true;                       // 127.0.0.0/8 环回
    if (a === 10) return true;                        // 10.0.0.0/8
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a === 192 && b === 168) return true;          // 192.168.0.0/16
    if (a === 169 && b === 254) return true;          // 169.254.0.0/16（含 169.254.169.254 / .170.2）
    if (a === 100 && b >= 64 && b <= 127) return true;// 100.64.0.0/10 CGNAT
    if (a === 192 && b === 0) return true;            // 192.0.0.0/24 + 192.0.2.0/24（保留/文档）
    if (a === 198 && (b === 18 || b === 19)) return true; // 198.18.0.0/15 基准测试
    if (a >= 224) return true;                        // 224/4 组播 + 240/4 保留
    return false;
  }
  if (fam === 6) {
    const s = ip.toLowerCase();
    if (s === '::1' || s === '::') return true;        // 环回 / unspecified
    if (s.startsWith('fe8') || s.startsWith('fe9') || s.startsWith('fea') || s.startsWith('feb')) return true; // fe80::/10 链路本地
    if (s.startsWith('fc') || s.startsWith('fd')) return true; // fc00::/7 ULA
    if (s.startsWith('ff')) return true;               // ff00::/8 组播
    return false;
  }
  return true; // 非法 / 无法识别 → 一律拒绝
}

// 解析并校验一个 URL 是否为「可抓取的公网地址」；返回已校验的 { hostname, ip, family }。
// host 本身是 IP → 直接判定，不做 DNS；否则解析全部 A/AAAA，任一被禁即拒绝。
async function resolveAndValidatePublicUrl(urlObj) {
  if (urlObj.protocol !== 'http:' && urlObj.protocol !== 'https:') throw SSRF_ERROR;
  const hostname = urlObj.hostname;
  if (isBlockedHostname(hostname)) throw SSRF_ERROR;

  const literal = net.isIP(normalizeIp(hostname));
  if (literal) {
    if (isBlockedIp(hostname)) throw SSRF_ERROR;
    return { hostname, ip: normalizeIp(hostname), family: literal };
  }

  let records = [];
  try { records = await dns.lookup(hostname, { all: true }); }
  catch (_) { throw SSRF_ERROR; }
  if (!records.length) throw SSRF_ERROR;
  for (const r of records) { if (isBlockedIp(r.address)) throw SSRF_ERROR; }

  // 钉死其中一个已校验地址用于实际连接，规避 DNS rebinding。
  const chosen = records[0];
  return { hostname, ip: normalizeIp(chosen.address), family: chosen.family };
}

// 自定义 lookup：始终返回已校验过的 IP，让连接钉在该 IP（仍保留原 hostname → Host/SNI 不变）。
function createPinnedLookup(ip, family) {
  return function pinnedLookup(_hostname, options, callback) {
    const cb = typeof options === 'function' ? options : callback;
    if (options && typeof options === 'object' && options.all) return cb(null, [{ address: ip, family }]);
    return cb(null, ip, family);
  };
}

// 手动逐跳跟随重定向（最多 maxHops 跳），每跳都重新做 URL/DNS/IP 校验并钉死 IP。
async function fetchFollowingRedirectsSafely(startUrl, maxHops = 5) {
  let current = startUrl;
  for (let hop = 0; hop <= maxHops; hop++) {
    const validated = await resolveAndValidatePublicUrl(current);
    const lookup = createPinnedLookup(validated.ip, validated.family);
    const agent = current.protocol === 'https:'
      ? new https.Agent({ lookup, keepAlive: false })
      : new http.Agent({ lookup, keepAlive: false });

    const resp = await axios.get(current.href, {
      maxRedirects: 0,                 // 禁用自动重定向，手动逐跳校验
      timeout: 12000,
      responseType: 'text',
      transformResponse: r => r,
      maxContentLength: 5 * 1024 * 1024,
      maxBodyLength: 5 * 1024 * 1024,
      httpAgent: agent,
      httpsAgent: agent,
      headers: {
        'User-Agent': MOBILE_UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      validateStatus: s => s >= 200 && s < 400
    });

    if (resp.status >= 300 && resp.status < 400) {
      const loc = resp.headers && resp.headers.location;
      if (!loc) throw SSRF_ERROR;
      let next;
      try { next = new URL(loc, current); } catch (_) { throw SSRF_ERROR; } // 支持相对 Location
      if (next.protocol !== 'http:' && next.protocol !== 'https:') throw SSRF_ERROR;
      current = next;
      continue;
    }
    return { resp, finalUrl: current.href };
  }
  throw SSRF_ERROR; // 超过最大跳数
}

module.exports = {
  SSRF_ERROR,
  createPinnedLookup,
  extractHttpUrl,
  fetchFollowingRedirectsSafely,
  isBlockedHostname,
  isBlockedIp,
  normalizeIp,
  resolveAndValidatePublicUrl
};
