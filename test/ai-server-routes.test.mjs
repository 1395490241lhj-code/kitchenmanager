import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const Module = require('node:module');
const originalLoad = Module._load;
const root = process.cwd();
const serverPath = resolve(root, 'server.js');
const originalEnv = { ...process.env };
const originalFetch = globalThis.fetch;

async function writeTempMediaFile(name, contents = 'audio') {
  const dir = path.join(os.tmpdir(), 'kitchenmanager-media');
  await fs.promises.mkdir(dir, { recursive: true });
  const filePath = path.join(dir, name);
  await fs.promises.writeFile(filePath, contents);
  return filePath;
}

function createExpressMock() {
  function express() {
    const routes = [];
    const app = {
      routes,
      use() {},
      get(path, handler) {
        routes.push({ method: 'GET', path, handler });
      },
      post(path, handler) {
        routes.push({ method: 'POST', path, handler });
      },
      listen() {
        return { close() {} };
      }
    };
    express.latestApp = app;
    return app;
  }
  express.json = () => (_req, _res, next) => {
    if (typeof next === 'function') next();
  };
  express.static = () => (_req, _res, next) => {
    if (typeof next === 'function') next();
  };
  return express;
}

function createRes() {
  return {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      return this;
    },
    sendFile() {
      return this;
    }
  };
}

function loadServerWithMocks({ axiosPost, axiosGet, dnsLookup, env = {}, childProcessMock, ffmpegStatic = '/mock/ffmpeg' } = {}) {
  const expressMock = createExpressMock();
  const axiosMock = {
    post: axiosPost || (async () => ({ data: { choices: [{ message: { content: 'ok' } }] } })),
    get: axiosGet || (async () => ({ status: 200, headers: {}, data: '' }))
  };
  Module._load = function mockedLoad(request, parent, isMain) {
    if (request === 'express') return expressMock;
    if (request === 'axios') return axiosMock;
    if (request === 'dns' && dnsLookup) return { promises: { lookup: dnsLookup } };
    if (request === 'ffmpeg-static') return ffmpegStatic;
    if (request === 'child_process' && childProcessMock) return childProcessMock;
    return originalLoad.call(this, request, parent, isMain);
  };

  process.env = {
    ...originalEnv,
    NODE_ENV: 'development',
    OPENAI_API_KEY: 'test-key',
    OPENAI_BASE_URL: 'https://api.groq.com/openai/v1',
    OPENAI_MODEL: 'openai/gpt-oss-120b',
    ...env
  };
  delete require.cache[serverPath];
  require(serverPath);
  return { app: expressMock.latestApp, axiosMock };
}

async function runPost(app, path, body = {}) {
  const route = app.routes.find(item => item.method === 'POST' && item.path === path);
  assert.ok(route, `${path} route should be registered`);
  const req = {
    body,
    headers: {},
    ip: '127.0.0.1',
    socket: { remoteAddress: '127.0.0.1' }
  };
  const res = createRes();
  await route.handler(req, res);
  return res;
}

async function runGet(app, path, query = {}) {
  const route = app.routes.find(item => item.method === 'GET' && item.path === path);
  assert.ok(route, `${path} route should be registered`);
  const req = { query, headers: {}, ip: '127.0.0.1', socket: { remoteAddress: '127.0.0.1' } };
  const res = createRes();
  await route.handler(req, res);
  return res;
}

afterEach(() => {
  Module._load = originalLoad;
  process.env = { ...originalEnv };
  globalThis.fetch = originalFetch;
  delete require.cache[serverPath];
});

test('/api/ai-status 配置完整时返回可用状态且不泄露 API Key', async () => {
  const { app } = loadServerWithMocks({
    env: {
      OPENAI_API_KEY: 'test-key',
      OPENAI_BASE_URL: 'https://api.groq.com/openai/v1',
      OPENAI_MODEL: 'openai/gpt-oss-120b',
      OPENAI_VISION_MODEL: 'meta-llama/llama-4-scout-17b-16e-instruct'
    }
  });

  const res = await runGet(app, '/api/ai-status');

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.available, true);
  assert.equal(res.body.mode, 'cloud');
  assert.equal(res.body.textModelConfigured, true);
  assert.equal(res.body.visionModelConfigured, true);
  assert.equal(res.body.baseUrlConfigured, true);
  assert.equal(res.body.message, '内置 AI 服务已配置');
  assert.doesNotMatch(JSON.stringify(res.body), /test-key|Authorization|Bearer/);
});

test('/api/ai-status 缺少 OPENAI_API_KEY 时返回安全 code', async () => {
  const { app } = loadServerWithMocks({
    env: {
      OPENAI_API_KEY: '',
      OPENAI_BASE_URL: 'https://api.groq.com/openai/v1',
      OPENAI_MODEL: 'openai/gpt-oss-120b',
      OPENAI_VISION_MODEL: 'meta-llama/llama-4-scout-17b-16e-instruct'
    }
  });

  const res = await runGet(app, '/api/ai-status');

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.available, false);
  assert.equal(res.body.code, 'missing_api_key');
  assert.equal(res.body.message, '内置 AI 服务未配置');
  assert.equal(res.body.textModelConfigured, false);
  assert.equal(res.body.visionModelConfigured, false);
  assert.equal(res.body.baseUrlConfigured, true);
  assert.doesNotMatch(JSON.stringify(res.body), /test-key|Authorization|Bearer/);
});

test('/api/ai-chat 图片请求默认使用 Groq 视觉模型，不回退到文本模型', async () => {
  let capturedPayload = null;
  const { app } = loadServerWithMocks({
    axiosPost: async (_url, payload) => {
      capturedPayload = payload;
      return { data: { choices: [{ message: { content: '{"ok":true}' } }] } };
    },
    env: { OPENAI_VISION_MODEL: '' }
  });

  const res = await runPost(app, '/api/ai-chat', {
    prompt: '识别小票',
    imageBase64: 'data:image/jpeg;base64,abcd',
    taskType: 'receipt'
  });

  assert.equal(res.statusCode, 200);
  assert.equal(capturedPayload.model, 'meta-llama/llama-4-scout-17b-16e-instruct');
  assert.notEqual(capturedPayload.model, 'openai/gpt-oss-120b');
});

test('/api/ai-chat 文本请求继续使用 OPENAI_MODEL', async () => {
  let capturedPayload = null;
  const { app } = loadServerWithMocks({
    axiosPost: async (_url, payload) => {
      capturedPayload = payload;
      return { data: { choices: [{ message: { content: '{"ok":true}' } }] } };
    }
  });

  const res = await runPost(app, '/api/ai-chat', {
    prompt: '推荐晚餐',
    taskType: 'recommendation'
  });

  assert.equal(res.statusCode, 200);
  assert.equal(capturedPayload.model, 'openai/gpt-oss-120b');
});

test('/api/ai-parse 图片请求也使用 OPENAI_VISION_MODEL', async () => {
  const capturedPayloads = [];
  const { app } = loadServerWithMocks({
    axiosPost: async (_url, payload) => {
      capturedPayloads.push(payload);
      if (capturedPayloads.length === 1) {
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['番茄炒蛋'],
                  observedMainIngredients: ['鸡蛋'],
                  observedSeasonings: ['盐'],
                  observedAromatics: [],
                  observedLiquids: [],
                  observedActions: [
                    { order: 1, action: '鸡蛋打散', ingredients: ['鸡蛋'], evidenceText: '鸡蛋打散', confidence: 'high' },
                    { order: 2, action: '下锅炒熟', ingredients: ['鸡蛋'], evidenceText: '下锅炒熟', confidence: 'high' }
                  ],
                  observedTimes: [],
                  observedTools: [],
                  uncertainItems: [],
                  missingInfo: [],
                  sourceConfidence: 'high'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '番茄炒蛋',
                ingredients: [{ item: '鸡蛋', qty: '2', unit: '个' }],
                seasonings: [{ item: '盐', qty: '1', unit: '适量' }],
                method: ['鸡蛋打散', '下锅炒熟']
              })
            }
          }]
        }
      };
    },
    env: { OPENAI_VISION_MODEL: 'meta-llama/llama-4-scout-17b-16e-instruct' }
  });

  const res = await runPost(app, '/api/ai-parse', {
    imageBase64: 'data:image/jpeg;base64,abcd'
  });

  assert.equal(res.statusCode, 200);
  assert.equal(capturedPayloads.length, 2);
  assert.equal(capturedPayloads[0].model, 'meta-llama/llama-4-scout-17b-16e-instruct');
  assert.match(capturedPayloads[0].messages[0].content, /证据抽取器/);
  assert.match(capturedPayloads[0].messages[0].content, /observedActions/);
  assert.match(capturedPayloads[0].messages[0].content, /有"水"不等于加水焖煮/);
  assert.equal(capturedPayloads[1].model, 'openai/gpt-oss-20b');
  assert.match(capturedPayloads[1].messages[1].content, /evidence JSON/);
  assert.match(capturedPayloads[1].messages[1].content, /sourceDiagnostics/);
  assert.equal(res.body.diagnostics.sourceConfidence, 'low');
  assert.equal(res.body.diagnostics.observedActionCount, 2);
  assert.deepEqual(res.body.debugEvidenceSummary.observedIngredients, ['鸡蛋']);
});

test('/api/xhs-extract 优先使用 og/meta 结构化字段，不让 body 评论进入 trusted text', async () => {
  const html = `<!doctype html><html><head>
    <title>页面标题不优先</title>
    <meta property="og:title" content="藤椒鸡腿详细版教程">
    <meta property="og:description" content="作者正文：鸡腿洗净擦干，加入生抽、老抽、料酒抓匀腌制。">
    <meta name="description" content="普通简介：铁锅煎至两面焦香。">
  </head><body>
    段老师这题我会 腌的时候放一丢丢小苏打 双椒鸡拌面 视频号为啥不要了
  </body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/note' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'meta');
  assert.equal(res.body.hasStructuredMeta, true);
  assert.equal(res.body.hasOgDescription, true);
  assert.match(res.body.text, /藤椒鸡腿详细版教程/);
  assert.match(res.body.text, /鸡腿洗净擦干/);
  assert.doesNotMatch(res.body.text, /小苏打|双椒鸡拌面|视频号为啥不要了|段老师/);
  assert.match(res.body.rawTextPreview, /小苏打/);
});

test('/api/xhs-extract 可以从 JSON-LD 提取 name 和 description', async () => {
  const html = `<!doctype html><html><head>
    <script type="application/ld+json">{
      "@type":"Recipe",
      "name":"鲜藤椒鸡腿",
      "description":"鸡腿加入鲜藤椒和生抽调味后出锅。",
      "recipeIngredient":["鸡腿","鲜藤椒","生抽"],
      "recipeInstructions":[
        {"@type":"HowToStep","text":"鸡腿洗净擦干。"},
        {"@type":"HowToStep","text":"加入鲜藤椒和生抽调味后出锅。"}
      ]
    }</script>
  </head><body>评论：太喜欢这道菜了</body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/jsonld' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'json-ld');
  assert.equal(res.body.hasJsonLd, true);
  assert.match(res.body.text, /鲜藤椒鸡腿/);
  assert.match(res.body.text, /鸡腿、鲜藤椒、生抽/);
  assert.match(res.body.text, /鸡腿洗净擦干/);
  assert.match(res.body.text, /加入鲜藤椒和生抽调味后出锅/);
  assert.doesNotMatch(res.body.text, /太喜欢/);
});

test('/api/xhs-extract 可以从 INITIAL_STATE 提取作者标题和正文', async () => {
  const html = `<!doctype html><html><head></head><body>
    <script>
      window.__INITIAL_STATE__ = {
        note: {
          noteDetailMap: {
            one: {
              note: {
                title: "番茄炒蛋",
                desc: "番茄切块，鸡蛋打散。锅中倒油炒鸡蛋，放入番茄翻炒，加盐调味后出锅。"
              }
            }
          }
        }
      };
    </script>
    评论：这个看起来太好吃了，求教程。
  </body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/initial' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'initial-state');
  assert.equal(res.body.hasInitialState, true);
  assert.match(res.body.text, /番茄炒蛋/);
  assert.match(res.body.text, /番茄切块/);
  assert.match(res.body.text, /加盐调味后出锅/);
  assert.doesNotMatch(res.body.text, /求教程/);
});

test('/api/xhs-extract body fallback 会按片段过滤评论和推荐文案', async () => {
  const html = `<!doctype html><html><body>
    家常版藤椒鸡腿详细版教程…… 藤椒鸡腿一道看起来就很好吃的菜，从前期处理的细节，精确到克的腌制比例，到在家怎么丝滑是运用铁锅，都一一道来
    #家常菜 #鸡腿 #藤椒鸡腿
    段老师这题我会 腌的时候放一丢丢小苏打[doge] 西安有一道菜叫双椒鸡拌面 视频号为啥不要了
  </body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/body' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'html-text');
  assert.match(res.body.text, /家常版藤椒鸡腿详细版教程/);
  assert.match(res.body.text, /腌制比例/);
  assert.doesNotMatch(res.body.text, /段老师|小苏打|双椒鸡拌面|视频号为啥不要了/);
  assert.match(res.body.rawTextPreview, /小苏打/);
  assert.ok(res.body.sourceSegmentsPreview.some(seg => seg.type === 'authorCandidate'));
});

test('/api/xhs-extract 少量标题信息也返回 text 和有用 warnings', async () => {
  const html = `<!doctype html><html><head><title>番茄炒蛋</title></head><body>点赞 收藏 评论 关注</body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/title-only' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'link-only');
  assert.match(res.body.text, /番茄炒蛋/);
  assert.ok(res.body.warnings.includes('链接可提取内容较少，可能需要人工确认。'));
  assert.ok(res.body.warnings.includes('未提取到完整做法步骤。'));
  assert.equal(res.body.media.mediaDiagnostics.hasVideo, false);
  assert.deepEqual(res.body.media.videoUrls, []);
  assert.ok(res.body.warnings.includes('未从页面中提取到可用视频地址。'));
});

test('/api/xhs-extract 支持 twitter meta description 作为可用来源', async () => {
  const html = `<!doctype html><html><head>
    <meta name="twitter:title" content="土豆丝">
    <meta name="twitter:description" content="土豆切丝冲洗，锅中热油放入土豆丝翻炒，加入醋和盐调味后出锅。">
  </head><body>相关推荐：黄金薯</body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/twitter' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.extractionMode, 'meta');
  assert.equal(res.body.hasStructuredMeta, true);
  assert.match(res.body.text, /土豆切丝冲洗/);
  assert.doesNotMatch(res.body.text, /黄金薯/);
});

test('/api/xhs-extract 会提取页面里的视频和封面 URL 但不加入正文', async () => {
  const html = `<!doctype html><html><head>
    <meta property="og:title" content="藤椒鸡腿">
    <meta property="og:description" content="鸡腿洗净擦干，加入生抽抓匀腌制。锅中煎至两面焦香，加入鲜藤椒调味后出锅。">
    <meta property="og:video" content="https://www.xiaohongshu.com/discovery/item/abc123">
    <meta property="og:video:secure_url" content="https://video.example.com/meta-play.mp4?token=1&amp;from=og">
    <meta property="og:image" content="https://img.example.com/cover-og.jpg">
  </head><body>
    <video src="https://media.example.com/video-tag.m3u8" poster="https://img.example.com/poster.webp"></video>
    <script>
      window.__INITIAL_STATE__ = {
        note: {
          video: {
            shareUrl: "https://www.xiaohongshu.com/explore/abc123",
            streamUrl: "https:\\/\\/sns-video.example.com\\/stream\\/abc.m3u8",
            h264: "https:\\/\\/sns-video.example.com\\/h264\\/abc.mp4",
            backupUrls: ["https://backup.example.com/vod/abc.mp4"]
          },
          imageList: [{ url: "https://sns-img.example.com/a.webp" }],
          cover: { url: "https://sns-img.example.com/cover.jpg" }
        }
      };
    </script>
  </body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/video-note' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.media.mediaDiagnostics.hasVideo, true);
  assert.ok(res.body.media.mediaDiagnostics.videoUrlCount >= 4);
  assert.equal(res.body.media.videoUrls[0], 'https://sns-video.example.com/stream/abc.m3u8');
  assert.ok(res.body.media.mediaDiagnostics.rejectedVideoUrlCount >= 1);
  assert.ok(res.body.media.mediaDiagnostics.rejectedVideoUrlHosts.includes('www.xiaohongshu.com'));
  assert.ok(res.body.media.videoUrls.includes('https://video.example.com/meta-play.mp4?token=1&from=og'));
  assert.ok(res.body.media.videoUrls.includes('https://sns-video.example.com/h264/abc.mp4'));
  assert.ok(res.body.media.videoUrls.includes('https://sns-video.example.com/stream/abc.m3u8'));
  assert.ok(!res.body.media.videoUrls.some(url => /www\.xiaohongshu\.com\/(?:discovery\/item|explore)/.test(url)));
  assert.ok(res.body.media.coverUrls.includes('https://img.example.com/cover-og.jpg'));
  assert.ok(res.body.media.coverUrls.includes('https://img.example.com/poster.webp'));
  assert.ok(res.body.media.imageUrls.includes('https://sns-img.example.com/a.webp'));
  assert.ok(res.body.media.mediaDiagnostics.extractionHints.includes('meta-video'));
  assert.ok(!res.body.warnings.includes('未从页面中提取到可用视频地址。'));
  assert.doesNotMatch(res.body.text, /meta-play\.mp4|h264\/abc\.mp4|stream\/abc\.m3u8/);
});

test('/api/xhs-extract 会过滤脚本中的内网媒体 URL', async () => {
  const html = `<!doctype html><html><head>
    <meta property="og:title" content="番茄炒蛋">
    <meta property="og:description" content="番茄切块，鸡蛋打散。锅中炒鸡蛋，放入番茄翻炒，加盐调味后出锅。">
  </head><body>
    <script>
      window.__INITIAL_STATE__ = {
        video: {
          streamUrl: "http://127.0.0.1/private.mp4",
          backupUrls: ["https://public.example.com/sns-video/ok.mp4"]
        }
      };
    </script>
  </body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/video-filter' });

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body.media.videoUrls, ['https://public.example.com/sns-video/ok.mp4']);
  assert.doesNotMatch(JSON.stringify(res.body.media), /127\.0\.0\.1/);
});

test('/api/media/extract-audio 下载视频到临时文件并调用 ffmpeg 提取 m4a', async () => {
  const videoBytes = Buffer.from('fake-video-bytes');
  const audioBytes = Buffer.from('fake-audio-bytes');
  const requestedUrls = [];
  const spawnCalls = [];
  const childProcessMock = {
    spawn(bin, args, options) {
      spawnCalls.push({ bin, args, options });
      const inputPath = args[args.indexOf('-i') + 1];
      const outputPath = args[args.length - 1];
      assert.equal(bin, '/mock/ffmpeg');
      assert.ok(fs.existsSync(inputPath));
      assert.match(outputPath, /\.m4a$/);
      assert.equal(options.shell, undefined);
      fs.writeFileSync(outputPath, audioBytes);
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        child.stderr.emit('data', 'Duration: 00:00:03.50, start: 0.000000');
        child.emit('close', 0);
      });
      return child;
    }
  };
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      requestedUrls.push(url);
      assert.equal(options.responseType, 'stream');
      assert.equal(options.maxRedirects, 0);
      return {
        status: 200,
        headers: { 'content-length': String(videoBytes.length) },
        data: Readable.from([videoBytes])
      };
    }
  });

  const res = await runPost(app, '/api/media/extract-audio', { videoUrl: 'https://video.example.com/play.mp4' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.match(res.body.audioPath, /^[0-9a-f-]+\.m4a$/i);
  assert.match(res.body.videoId, /^[0-9a-f-]+\.video$/i);
  assert.doesNotMatch(res.body.audioPath, /\//);
  assert.doesNotMatch(res.body.videoId, /\//);
  assert.equal(res.body.durationSeconds, 3.5);
  assert.equal(res.body.bytes, audioBytes.length);
  assert.equal(res.body.videoBytes, videoBytes.length);
  assert.deepEqual(requestedUrls, ['https://video.example.com/play.mp4']);
  assert.equal(spawnCalls.length, 1);
  assert.deepEqual(spawnCalls[0].args.slice(0, 2), ['-y', '-i']);
  assert.ok(spawnCalls[0].args.includes('-vn'));
  assert.ok(spawnCalls[0].args.includes('16000'));
});

test('/api/media/extract-audio 视频文件过大返回 413', async () => {
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({
      status: 200,
      headers: { 'content-length': String(80 * 1024 * 1024 + 1) },
      data: Readable.from([])
    })
  });

  const res = await runPost(app, '/api/media/extract-audio', { videoUrl: 'https://video.example.com/large.mp4' });

  assert.equal(res.statusCode, 413);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.message, '视频文件过大，暂不支持导入。');
});

test('/api/media/extract-audio 拒绝内网视频地址且不下载', async () => {
  let axiosCalled = false;
  const { app } = loadServerWithMocks({
    axiosGet: async () => {
      axiosCalled = true;
      throw new Error('should not download private url');
    }
  });

  const res = await runPost(app, '/api/media/extract-audio', { videoUrl: 'http://127.0.0.1/private.mp4' });

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.message, '不支持的视频地址。');
  assert.equal(axiosCalled, false);
});

test('/api/media/extract-audio ffmpeg 失败返回友好错误', async () => {
  const childProcessMock = {
    spawn() {
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => child.emit('close', 1));
      return child;
    }
  };
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({
      status: 200,
      headers: { 'content-length': '5' },
      data: Readable.from([Buffer.from('video')])
    })
  });

  const res = await runPost(app, '/api/media/extract-audio', { videoUrl: 'https://video.example.com/fail.mp4' });

  assert.equal(res.statusCode, 502);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.message, '音频提取失败，请稍后重试。');
});

test('/api/media/extract-frames 从临时视频抽取关键帧并返回 frameIds', async () => {
  await writeTempMediaFile('frames-source.video', Buffer.from('fake-video'));
  const spawnCalls = [];
  const childProcessMock = {
    spawn(bin, args, options) {
      spawnCalls.push({ bin, args, options });
      assert.equal(bin, '/mock/ffmpeg');
      assert.equal(options.shell, undefined);
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        if (args.includes('-hide_banner')) {
          child.stderr.emit('data', 'Duration: 00:00:12.00, start: 0.000000');
          child.emit('close', 1);
          return;
        }
        const outputPath = args[args.length - 1];
        fs.writeFileSync(outputPath, Buffer.from('fake-jpg'));
        child.emit('close', 0);
      });
      return child;
    }
  };
  const { app } = loadServerWithMocks({ childProcessMock });

  const res = await runPost(app, '/api/media/extract-frames', { videoId: 'frames-source.video', maxFrames: 3 });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.durationSeconds, 12);
  assert.deepEqual(res.body.frameIds, ['frames-source-frame-01.jpg', 'frames-source-frame-02.jpg', 'frames-source-frame-03.jpg']);
  assert.equal(res.body.frames.length, 3);
  assert.ok(res.body.frames.every(frame => frame.bytes === Buffer.byteLength('fake-jpg')));
  assert.equal(spawnCalls.length, 4);
  assert.ok(spawnCalls[0].args.includes('-hide_banner'));
  assert.ok(spawnCalls.slice(1).every(call => call.args.includes('scale=512:-2')));
  assert.ok(spawnCalls.slice(1).every(call => {
    const qIndex = call.args.indexOf('-q:v');
    return qIndex >= 0 && call.args[qIndex + 1] === '10';
  }));
  assert.ok(spawnCalls.slice(1).every(call => call.args.includes('-frames:v')));
});

test('/api/media/extract-frames 拒绝非法或不存在的 videoId', async () => {
  const { app } = loadServerWithMocks();

  const invalid = await runPost(app, '/api/media/extract-frames', { videoId: '../secret.video' });
  assert.equal(invalid.statusCode, 400);
  assert.equal(invalid.body.message, '视频文件标识不合法。');

  const missing = await runPost(app, '/api/media/extract-frames', { videoId: 'missing.video' });
  assert.equal(missing.statusCode, 404);
  assert.equal(missing.body.message, '视频文件不存在。');
});

test('/api/media/ocr-frames 使用视觉模型提取帧中文字且不生成菜谱', async () => {
  await writeTempMediaFile('ocr-frame-01.jpg', Buffer.from('fake-jpg-1'));
  await writeTempMediaFile('ocr-frame-02.jpg', Buffer.from('fake-jpg-2'));
  const capturedPayloads = [];
  const { app } = loadServerWithMocks({
    axiosPost: async (url, payload, options) => {
      capturedPayloads.push({ url, payload, options });
      assert.equal(url, 'https://api.groq.com/openai/v1/chat/completions');
      assert.equal(options.headers.Authorization, 'Bearer test-key');
      assert.equal(payload.model, 'meta-llama/llama-4-scout-17b-16e-instruct');
      const userContent = payload.messages[1].content;
      assert.match(userContent[0].text, /只提取画面中清晰可见/);
      assert.match(userContent[0].text, /不要根据画面猜完整做法/);
      assert.match(userContent[1].image_url.url, /^data:image\/jpeg;base64,/);
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({ text: '鸡腿 2 个\n生抽 1 勺', confidence: 'high' })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/media/ocr-frames', { frameIds: ['ocr-frame-01.jpg', 'ocr-frame-02.jpg'] });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.match(res.body.ocrText, /鸡腿 2 个/);
  assert.equal(res.body.frames.length, 2);
  assert.equal(res.body.frames[0].confidence, 'high');
  assert.equal(capturedPayloads.length, 2);
});

test('/api/media/ocr-frames 最多处理 3 帧并拒绝非法 frameId', async () => {
  for (let i = 1; i <= 5; i++) {
    await writeTempMediaFile(`cap-frame-${String(i).padStart(2, '0')}.jpg`, Buffer.from(`jpg-${i}`));
  }
  let calls = 0;
  const { app } = loadServerWithMocks({
    axiosPost: async () => {
      calls += 1;
      return {
        data: {
          choices: [{
            message: { content: JSON.stringify({ text: '字幕', confidence: 'medium' }) }
          }]
        }
      };
    }
  });

  const frameIds = Array.from({ length: 5 }, (_, index) => `cap-frame-${String(index + 1).padStart(2, '0')}.jpg`);
  const capped = await runPost(app, '/api/media/ocr-frames', { frameIds });
  assert.equal(capped.statusCode, 200);
  assert.equal(capped.body.frames.length, 3);
  assert.equal(calls, 3);

  const invalid = await runPost(app, '/api/media/ocr-frames', { frameIds: ['../secret.jpg'] });
  assert.equal(invalid.statusCode, 400);
  assert.equal(invalid.body.message, '图片帧标识不合法。');
});

test('/api/media/ocr-frames 跳过超过大小限制的帧而不请求视觉模型', async () => {
  await writeTempMediaFile('ocr-large.jpg', Buffer.alloc(800 * 1024, 1));
  let calls = 0;
  const { app } = loadServerWithMocks({
    axiosPost: async () => {
      calls += 1;
      throw new Error('Vision should not be called for oversized frame');
    }
  });

  const res = await runPost(app, '/api/media/ocr-frames', { frameIds: ['ocr-large.jpg'] });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.ocrText, '');
  assert.equal(res.body.frames.length, 1);
  assert.equal(res.body.frames[0].skipped, true);
  assert.equal(res.body.frames[0].reason, 'frame_too_large');
  assert.equal(res.body.skippedFrameCount, 1);
  assert.equal(calls, 0);
});

test('/api/media/ocr-frames 缺少密钥或上游失败时返回友好错误', async () => {
  await writeTempMediaFile('ocr-fail.jpg', Buffer.from('fake-jpg'));
  const noKeyApp = loadServerWithMocks({ env: { OPENAI_API_KEY: '' } }).app;
  const noKey = await runPost(noKeyApp, '/api/media/ocr-frames', { frameIds: ['ocr-fail.jpg'] });
  assert.equal(noKey.statusCode, 503);
  assert.equal(noKey.body.message, '后端未配置 AI 密钥。');

  delete require.cache[serverPath];
  const failApp = loadServerWithMocks({
    axiosPost: async () => {
      throw new Error('vision failed');
    }
  }).app;
  const failed = await runPost(failApp, '/api/media/ocr-frames', { frameIds: ['ocr-fail.jpg'] });
  assert.equal(failed.statusCode, 502);
  assert.equal(failed.body.message, '画面文字识别失败，请稍后重试。');
});

test('/api/media/transcribe 调用 OpenAI audio transcriptions 并返回 transcript', async () => {
  await writeTempMediaFile('transcribe-success.m4a', Buffer.from('fake-audio'));
  let capturedUrl = '';
  let capturedOptions = null;
  globalThis.fetch = async (url, options) => {
    capturedUrl = String(url);
    capturedOptions = options;
    assert.equal(options.method, 'POST');
    assert.equal(options.headers.Authorization, 'Bearer test-key');
    assert.equal(options.body.get('model'), 'gpt-4o-mini-transcribe');
    assert.equal(options.body.get('response_format'), 'json');
    assert.equal(options.body.get('language'), 'zh');
    assert.ok(options.body.get('file'));
    return {
      ok: true,
      status: 200,
      async json() {
        return { text: '鸡腿先腌制，然后下锅煎香。' };
      }
    };
  };
  const { app } = loadServerWithMocks();

  const res = await runPost(app, '/api/media/transcribe', { audioPath: 'transcribe-success.m4a' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.transcript, '鸡腿先腌制，然后下锅煎香。');
  assert.equal(res.body.model, 'gpt-4o-mini-transcribe');
  assert.equal(res.body.transcriptLength, 13);
  assert.equal(capturedUrl, 'https://api.groq.com/openai/v1/audio/transcriptions');
  assert.ok(capturedOptions.body);
});

test('/api/media/transcribe 支持通过 OPENAI_TRANSCRIBE_MODEL 覆盖模型', async () => {
  await writeTempMediaFile('transcribe-model.m4a', Buffer.from('fake-audio'));
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.body.get('model'), 'custom-transcribe-model');
    return {
      ok: true,
      status: 200,
      async json() {
        return { text: '测试转录文本' };
      }
    };
  };
  const { app } = loadServerWithMocks({
    env: { OPENAI_TRANSCRIBE_MODEL: 'custom-transcribe-model' }
  });

  const res = await runPost(app, '/api/media/transcribe', { audioPath: 'transcribe-model.m4a' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.model, 'custom-transcribe-model');
});

test('/api/media/transcribe 拒绝非法 audioPath', async () => {
  const { app } = loadServerWithMocks();

  const res = await runPost(app, '/api/media/transcribe', { audioPath: '../secret.m4a' });

  assert.equal(res.statusCode, 400);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.message, '音频文件标识不合法。');
});

test('/api/media/transcribe 音频文件不存在返回 404', async () => {
  const { app } = loadServerWithMocks();

  const res = await runPost(app, '/api/media/transcribe', { audioPath: 'missing-audio.m4a' });

  assert.equal(res.statusCode, 404);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.message, '音频文件不存在。');
});

test('/api/media/transcribe 缺少 OPENAI_API_KEY 返回 503 且不调用上游', async () => {
  await writeTempMediaFile('transcribe-no-key.m4a', Buffer.from('fake-audio'));
  let fetchCalled = false;
  globalThis.fetch = async () => {
    fetchCalled = true;
    throw new Error('should not call upstream without key');
  };
  const { app } = loadServerWithMocks({ env: { OPENAI_API_KEY: '' } });

  const res = await runPost(app, '/api/media/transcribe', { audioPath: 'transcribe-no-key.m4a' });

  assert.equal(res.statusCode, 503);
  assert.equal(res.body.ok, false);
  assert.equal(fetchCalled, false);
});

test('/api/media/transcribe 上游失败或空 transcript 返回 502', async () => {
  await writeTempMediaFile('transcribe-upstream.m4a', Buffer.from('fake-audio'));
  globalThis.fetch = async () => ({
    ok: false,
    status: 429,
    async json() {
      return { error: { message: 'rate limited' } };
    }
  });
  const failedApp = loadServerWithMocks().app;
  const failed = await runPost(failedApp, '/api/media/transcribe', { audioPath: 'transcribe-upstream.m4a' });
  assert.equal(failed.statusCode, 502);
  assert.equal(failed.body.message, '音频转录失败，请稍后重试。');

  delete require.cache[serverPath];
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    async json() {
      return { text: '' };
    }
  });
  const emptyApp = loadServerWithMocks().app;
  const empty = await runPost(emptyApp, '/api/media/transcribe', { audioPath: 'transcribe-upstream.m4a' });
  assert.equal(empty.statusCode, 502);
  assert.equal(empty.body.message, '音频转录结果为空，请稍后重试。');
});

test('/api/recipe-import-from-url 合并页面文字、视频转录、抽帧 OCR 和用户补充后生成草稿', async () => {
  const videoBytes = Buffer.from('fake-video');
  const audioBytes = Buffer.from('fake-audio');
  const longPageText = `页面文字：藤椒鸡腿，鸡腿和鲜藤椒。${'页'.repeat(1200)}PAGE_SENTINEL`;
  const longTranscript = `鸡腿洗净擦干，加入生抽抓匀腌制。锅中煎至两面金黄。${'转录'.repeat(2500)}TRANSCRIPT_SENTINEL`;
  const longOcrText = `字幕：加入鲜藤椒和生抽调味，翻炒后出锅。${'画面'.repeat(900)}OCR_SENTINEL`;
  const longUserText = `用户补充：少油。${'补充'.repeat(1200)}USER_SENTINEL`;
  const capturedAiPayloads = [];
  let visionCallCount = 0;
  const childProcessMock = {
    spawn(_bin, args) {
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        if (args.includes('-hide_banner')) {
          child.stderr.emit('data', 'Duration: 00:00:09.00, start: 0.000000');
          child.emit('close', 1);
          return;
        }
        const outputPath = args[args.length - 1];
        if (/\.m4a$/i.test(outputPath)) fs.writeFileSync(outputPath, audioBytes);
        else fs.writeFileSync(outputPath, Buffer.from('fake-jpg'));
        child.emit('close', 0);
      });
      return child;
    }
  };
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.body.get('model'), 'gpt-4o-mini-transcribe');
    return {
      ok: true,
      status: 200,
      async json() {
        return { text: longTranscript };
      }
    };
  };
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      if (options.responseType === 'stream') {
        assert.equal(url, 'https://sns-video-abc.xhscdn.com/stream/recipe.m3u8');
        return {
          status: 200,
          headers: { 'content-length': String(videoBytes.length) },
          data: Readable.from([videoBytes])
        };
      }
      return {
        status: 200,
        headers: {},
        data: `
          <html><head>
            <meta property="og:title" content="藤椒鸡腿">
            <meta property="og:description" content="${longPageText}">
            <meta property="og:video" content="https://www.xiaohongshu.com/discovery/item/not-video">
            <script>
              window.__INITIAL_STATE__ = {
                note: {
                  video: {
                    shareUrl: "https://www.xiaohongshu.com/explore/not-video",
                    streamUrl: "https://sns-video-abc.xhscdn.com/stream/recipe.m3u8",
                    h264: "https://sns-video-abc.xhscdn.com/h264/recipe.mp4"
                  }
                }
              };
            </script>
          </head><body></body></html>
        `
      };
    },
    axiosPost: async (_url, payload) => {
      capturedAiPayloads.push(payload);
      if (payload.model === 'meta-llama/llama-4-scout-17b-16e-instruct') {
        visionCallCount += 1;
        if (visionCallCount === 1) {
          const err = new Error('vision upstream failed test-key');
          err.response = {
            status: 429,
            data: { error: { code: 'rate_limit', message: 'vision rate limited test-key' } }
          };
          throw err;
        }
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({ text: longOcrText, confidence: 'high' })
              }
            }]
          }
        };
      }
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        assert.equal(payload.model, 'openai/gpt-oss-20b');
        const prompt = payload.messages[1].content;
        assert.match(prompt, /页面文字：藤椒鸡腿/);
        assert.match(prompt, /加入生抽抓匀腌制/);
        assert.match(prompt, /加入鲜藤椒和生抽调味/);
        assert.doesNotMatch(prompt, /PAGE_SENTINEL/);
        assert.doesNotMatch(prompt, /TRANSCRIPT_SENTINEL/);
        assert.doesNotMatch(prompt, /OCR_SENTINEL/);
        assert.doesNotMatch(prompt, /USER_SENTINEL/);
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['藤椒鸡腿'],
                  observedMainIngredients: ['鸡腿'],
                  observedSeasonings: ['生抽'],
                  observedAromatics: ['鲜藤椒'],
                  observedLiquids: [],
                  observedActions: [
                    { order: 1, action: '鸡腿洗净擦干并腌制', ingredients: ['鸡腿', '生抽'], evidenceText: '加入生抽抓匀腌制', confidence: 'high' },
                    { order: 2, action: '煎至两面金黄', ingredients: ['鸡腿'], evidenceText: '煎至两面金黄', confidence: 'high' },
                    { order: 3, action: '加入鲜藤椒调味后出锅', ingredients: ['鲜藤椒'], evidenceText: '加入鲜藤椒和生抽调味，翻炒后出锅', confidence: 'high' }
                  ],
                  sourceConfidence: 'high'
                })
              }
            }]
          }
        };
      }
      assert.equal(payload.model, 'openai/gpt-oss-20b');
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '藤椒鸡腿',
                tags: ['AI草稿'],
                ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
                seasonings: [{ item: '鲜藤椒', qty: '1', unit: '把' }, { item: '生抽', qty: '1', unit: '勺' }],
                method: ['鸡腿洗净擦干，加入生抽抓匀腌制。', '煎至两面金黄。', '加入鲜藤椒和生抽调味，翻炒后出锅。']
              })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', {
    url: 'http://xhslink.com/o/example',
    userText: longUserText
  });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.recipe.name, '藤椒鸡腿');
  assert.equal(res.body.mediaDiagnostics.hasVideo, true);
  assert.equal(res.body.mediaDiagnostics.selectedVideoHost, 'sns-video-abc.xhscdn.com');
  assert.equal(res.body.mediaDiagnostics.selectedVideoPathPreview, '/stream/recipe.m3u8');
  assert.equal(res.body.mediaDiagnostics.selectedVideoUrlRanked, true);
  assert.ok(res.body.mediaDiagnostics.rejectedVideoUrlCount >= 1);
  assert.ok(res.body.mediaDiagnostics.rejectedVideoUrlHosts.includes('www.xiaohongshu.com'));
  assert.ok(res.body.mediaDiagnostics.transcriptLength > 0);
  assert.equal(res.body.mediaDiagnostics.asrAttempted, true);
  assert.equal(res.body.mediaDiagnostics.asrOk, true);
  assert.equal(res.body.mediaDiagnostics.asrEndpointHost, 'api.groq.com');
  assert.equal(res.body.mediaDiagnostics.asrModel, 'gpt-4o-mini-transcribe');
  assert.equal(res.body.mediaDiagnostics.audioBytes, audioBytes.length);
  assert.equal(res.body.mediaDiagnostics.audioMimeType, 'audio/mp4');
  assert.ok(res.body.mediaDiagnostics.framesExtracted > 0);
  assert.equal(res.body.mediaDiagnostics.ocrAttempted, true);
  assert.equal(res.body.mediaDiagnostics.ocrOk, true);
  assert.equal(res.body.mediaDiagnostics.failedFrameCount, 1);
  assert.equal(res.body.mediaDiagnostics.visionUpstreamStatus, 429);
  assert.equal(res.body.mediaDiagnostics.visionUpstreamCode, 'rate_limit');
  assert.doesNotMatch(res.body.mediaDiagnostics.visionErrorPreview, /test-key/);
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /部分视频画面文字识别失败/);
  assert.match(res.body.recipe.method.join('\n'), /鲜藤椒/);
  assert.ok(capturedAiPayloads.some(payload => payload.model === 'meta-llama/llama-4-scout-17b-16e-instruct'));
});

test('/api/recipe-import-from-url 遇到 ASR/OCR 上游 413 仍返回草稿和诊断', async () => {
  const videoBytes = Buffer.from('fake-video');
  const audioBytes = Buffer.from('fake-audio');
  const childProcessMock = {
    spawn(_bin, args) {
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        if (args.includes('-hide_banner')) {
          child.stderr.emit('data', 'Duration: 00:00:09.00, start: 0.000000');
          child.emit('close', 1);
          return;
        }
        const outputPath = args[args.length - 1];
        if (/\.m4a$/i.test(outputPath)) fs.writeFileSync(outputPath, audioBytes);
        else fs.writeFileSync(outputPath, Buffer.from('fake-jpg'));
        child.emit('close', 0);
      });
      return child;
    }
  };
  globalThis.fetch = async () => ({
    ok: false,
    status: 413,
    async text() {
      return JSON.stringify({ error: { code: 'rate_limit_exceeded', message: 'ASR rate limit test-key' } });
    }
  });
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      if (options.responseType === 'stream') {
        return {
          status: 200,
          headers: { 'content-length': String(videoBytes.length) },
          data: Readable.from([videoBytes])
        };
      }
      return {
        status: 200,
        headers: {},
        data: `
          <meta property="og:title" content="藤椒鸡腿">
          <meta property="og:description" content="页面文字：藤椒鸡腿，鸡腿切块。">
          <meta property="og:video" content="https://sns-video-abc.xhscdn.com/stream/recipe.m3u8">
        `
      };
    },
    axiosPost: async (_url, payload) => {
      if (payload.model === 'meta-llama/llama-4-scout-17b-16e-instruct') {
        const err = new Error('vision payload too large test-key');
        err.response = {
          status: 413,
          data: { error: { code: 'rate_limit_exceeded', message: 'Vision rate limit test-key' } }
        };
        throw err;
      }
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['藤椒鸡腿'],
                  observedMainIngredients: ['鸡腿'],
                  observedSeasonings: [],
                  observedActions: [
                    { order: 1, action: '鸡腿切块', ingredients: ['鸡腿'], evidenceText: '鸡腿切块', confidence: 'low' }
                  ],
                  sourceConfidence: 'low'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '藤椒鸡腿',
                tags: ['AI草稿'],
                ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
                seasonings: [],
                method: ['鸡腿切块。']
              })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/asr-fails' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.mediaDiagnostics.audioExtracted, true);
  assert.equal(res.body.mediaDiagnostics.asrAttempted, true);
  assert.equal(res.body.mediaDiagnostics.asrOk, false);
  assert.equal(res.body.mediaDiagnostics.asrEndpointHost, 'api.groq.com');
  assert.equal(res.body.mediaDiagnostics.asrModel, 'gpt-4o-mini-transcribe');
  assert.equal(res.body.mediaDiagnostics.asrUpstreamStatus, 413);
  assert.equal(res.body.mediaDiagnostics.asrUpstreamCode, 'rate_limit_exceeded');
  assert.doesNotMatch(res.body.mediaDiagnostics.asrErrorPreview, /test-key/);
  assert.equal(res.body.mediaDiagnostics.audioBytes, audioBytes.length);
  assert.equal(res.body.mediaDiagnostics.audioMimeType, 'audio/mp4');
  assert.ok(res.body.mediaDiagnostics.framesExtracted > 0);
  assert.equal(res.body.mediaDiagnostics.ocrAttempted, true);
  assert.equal(res.body.mediaDiagnostics.ocrOk, false);
  assert.equal(res.body.mediaDiagnostics.ocrFrameCount, 0);
  assert.equal(res.body.mediaDiagnostics.failedFrameCount, res.body.mediaDiagnostics.framesExtracted);
  assert.equal(res.body.mediaDiagnostics.skippedFrameCount, 0);
  assert.equal(res.body.mediaDiagnostics.visionEndpointHost, 'api.groq.com');
  assert.equal(res.body.mediaDiagnostics.visionModel, 'meta-llama/llama-4-scout-17b-16e-instruct');
  assert.equal(res.body.mediaDiagnostics.visionUpstreamStatus, 413);
  assert.equal(res.body.mediaDiagnostics.visionUpstreamCode, 'rate_limit_exceeded');
  assert.doesNotMatch(res.body.mediaDiagnostics.visionErrorPreview, /test-key/);
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /口播转录触发限流，已跳过口播转录/);
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /画面文字识别触发限流，已跳过部分帧/);
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /视频抽帧成功，但画面文字识别失败/);
});

test('/api/recipe-import-from-url 跳过过大的视频帧且不请求 Vision', async () => {
  const videoBytes = Buffer.from('fake-video');
  const audioBytes = Buffer.from('fake-audio');
  let visionCalls = 0;
  const childProcessMock = {
    spawn(_bin, args) {
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        if (args.includes('-hide_banner')) {
          child.stderr.emit('data', 'Duration: 00:00:09.00, start: 0.000000');
          child.emit('close', 1);
          return;
        }
        const outputPath = args[args.length - 1];
        if (/\.m4a$/i.test(outputPath)) fs.writeFileSync(outputPath, audioBytes);
        else fs.writeFileSync(outputPath, Buffer.alloc(800 * 1024, 1));
        child.emit('close', 0);
      });
      return child;
    }
  };
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    async json() {
      return { text: '鸡腿加入生抽抓匀腌制，煎香后出锅。' };
    }
  });
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      if (options.responseType === 'stream') {
        return {
          status: 200,
          headers: { 'content-length': String(videoBytes.length) },
          data: Readable.from([videoBytes])
        };
      }
      return {
        status: 200,
        headers: {},
        data: `
          <meta property="og:title" content="藤椒鸡腿">
          <meta property="og:description" content="页面文字：藤椒鸡腿，鸡腿切块。">
          <meta property="og:video" content="https://sns-video-abc.xhscdn.com/stream/recipe.m3u8">
        `
      };
    },
    axiosPost: async (_url, payload) => {
      if (payload.model === 'meta-llama/llama-4-scout-17b-16e-instruct') {
        visionCalls += 1;
        throw new Error('Vision should not be called for oversized frames');
      }
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['藤椒鸡腿'],
                  observedMainIngredients: ['鸡腿'],
                  observedSeasonings: ['生抽'],
                  observedActions: [
                    { order: 1, action: '加入生抽抓匀腌制', ingredients: ['鸡腿', '生抽'], evidenceText: '加入生抽抓匀腌制', confidence: 'medium' }
                  ],
                  sourceConfidence: 'medium'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '藤椒鸡腿',
                tags: ['AI草稿'],
                ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
                seasonings: [{ item: '生抽', qty: '1', unit: '勺' }],
                method: ['鸡腿加入生抽抓匀腌制。']
              })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/large-frames' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.mediaDiagnostics.asrOk, true);
  assert.ok(res.body.mediaDiagnostics.transcriptLength > 0);
  assert.equal(res.body.mediaDiagnostics.ocrAttempted, true);
  assert.equal(res.body.mediaDiagnostics.ocrOk, false);
  assert.equal(res.body.mediaDiagnostics.failedFrameCount, 0);
  assert.equal(res.body.mediaDiagnostics.skippedFrameCount, res.body.mediaDiagnostics.framesExtracted);
  assert.equal(res.body.mediaDiagnostics.ocrFrameCount, 0);
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /frame_too_large_skipped/);
  assert.equal(visionCalls, 0);
});

test('/api/recipe-import-from-url 最终结构化限流时返回中间结果并复用视频文字缓存', async () => {
  const videoBytes = Buffer.from('fake-video');
  const audioBytes = Buffer.from('fake-audio');
  const aiPayloads = [];
  let asrCalls = 0;
  let visionCalls = 0;
  const childProcessMock = {
    spawn(_bin, args) {
      const child = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setImmediate(() => {
        if (args.includes('-hide_banner')) {
          child.stderr.emit('data', 'Duration: 00:00:09.00, start: 0.000000');
          child.emit('close', 1);
          return;
        }
        const outputPath = args[args.length - 1];
        if (/\.m4a$/i.test(outputPath)) fs.writeFileSync(outputPath, audioBytes);
        else fs.writeFileSync(outputPath, Buffer.from('fake-jpg'));
        child.emit('close', 0);
      });
      return child;
    }
  };
  globalThis.fetch = async () => {
    asrCalls += 1;
    return {
      ok: true,
      status: 200,
      async json() {
        return { text: '鸡腿洗净擦干，加入生抽抓匀腌制。锅中煎至两面金黄。' };
      }
    };
  };
  const { app } = loadServerWithMocks({
    childProcessMock,
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      if (options.responseType === 'stream') {
        assert.equal(url, 'https://sns-video-cache.xhscdn.com/stream/cache-test.m3u8');
        return {
          status: 200,
          headers: { 'content-length': String(videoBytes.length) },
          data: Readable.from([videoBytes])
        };
      }
      return {
        status: 200,
        headers: {},
        data: `
          <meta property="og:description" content="页面文字：藤椒鸡腿，鸡腿和鲜藤椒。">
          <meta property="og:video" content="https://sns-video-cache.xhscdn.com/stream/cache-test.m3u8">
        `
      };
    },
    axiosPost: async (_url, payload) => {
      aiPayloads.push(payload);
      if (payload.model === 'meta-llama/llama-4-scout-17b-16e-instruct') {
        visionCalls += 1;
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({ text: '字幕：加入鲜藤椒调味后出锅。', confidence: 'high' })
              }
            }]
          }
        };
      }
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        assert.equal(payload.model, 'openai/gpt-oss-20b');
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['藤椒鸡腿'],
                  observedMainIngredients: ['鸡腿'],
                  observedSeasonings: ['生抽'],
                  observedAromatics: ['鲜藤椒'],
                  observedActions: [
                    { order: 1, action: '鸡腿腌制', ingredients: ['鸡腿', '生抽'], evidenceText: '加入生抽抓匀腌制', confidence: 'medium' },
                    { order: 2, action: '加入鲜藤椒出锅', ingredients: ['鲜藤椒'], evidenceText: '加入鲜藤椒调味后出锅', confidence: 'medium' }
                  ],
                  sourceConfidence: 'medium'
                })
              }
            }]
          }
        };
      }
      assert.equal(payload.model, 'openai/gpt-oss-20b');
      const err = new Error('Groq rate limit');
      err.response = {
        status: 413,
        data: { error: { code: 'rate_limit_exceeded', message: 'tokens per minute exceeded test-key' } }
      };
      throw err;
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/rate-limit-cache' });

  assert.equal(res.statusCode, 429);
  assert.equal(res.body.code, 'rate_limit_exceeded');
  assert.equal(res.body.error, 'AI 服务请求过于频繁，请稍后再试。');
  assert.equal(res.body.upstreamStatus, 413);
  assert.equal(res.body.upstreamCode, 'rate_limit_exceeded');
  assert.equal(res.body.importTextReady, true);
  assert.match(res.body.transcriptPreview, /加入生抽抓匀腌制/);
  assert.match(res.body.ocrPreview, /鲜藤椒/);
  assert.match(res.body.pageTextPreview, /藤椒鸡腿/);
  assert.equal(res.body.mediaDiagnostics.hasVideo, true);
  assert.equal(res.body.mediaDiagnostics.cacheHit, false);
  assert.equal(res.body.mediaDiagnostics.asrOk, true);
  assert.equal(res.body.mediaDiagnostics.ocrOk, true);
  assert.ok(res.body.mediaDiagnostics.pageTextLength > 0);
  assert.equal(asrCalls, 1);
  assert.equal(visionCalls, 3);

  const retry = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/rate-limit-cache' });

  assert.equal(retry.statusCode, 429);
  assert.equal(retry.body.importTextReady, true);
  assert.equal(retry.body.mediaDiagnostics.cacheHit, true);
  assert.equal(retry.body.mediaDiagnostics.asrOk, true);
  assert.equal(retry.body.mediaDiagnostics.ocrOk, true);
  assert.equal(asrCalls, 1);
  assert.equal(visionCalls, 3);
  assert.equal(aiPayloads.filter(payload => /菜谱证据抽取器/.test(payload.messages?.[0]?.content || '')).length, 2);
});

test('/api/recipe-import-from-url 视频处理失败时使用页面文字继续生成草稿', async () => {
  const aiPayloads = [];
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async (url, options) => {
      if (options.responseType === 'stream') throw new Error('download failed');
      return {
        status: 200,
        headers: {},
        data: `
          <meta property="og:description" content="页面文字：番茄炒蛋，番茄切块，鸡蛋炒散。">
          <meta property="og:video" content="https://video.example.com/broken.mp4">
        `
      };
    },
    axiosPost: async (_url, payload) => {
      aiPayloads.push(payload);
      assert.notEqual(payload.model, 'meta-llama/llama-4-scout-17b-16e-instruct');
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        assert.match(payload.messages[1].content, /页面文字：番茄炒蛋/);
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['番茄炒蛋'],
                  observedMainIngredients: ['番茄', '鸡蛋'],
                  observedSeasonings: [],
                  observedActions: [
                    { order: 1, action: '番茄切块', ingredients: ['番茄'], evidenceText: '番茄切块', confidence: 'medium' }
                  ],
                  sourceConfidence: 'low'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '番茄炒蛋',
                tags: ['AI草稿'],
                ingredients: [{ item: '番茄', qty: '1', unit: '个' }, { item: '鸡蛋', qty: '2', unit: '个' }],
                seasonings: [],
                method: ['番茄切块。']
              })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/broken' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.recipe.name, '番茄炒蛋');
  assert.match(res.body.mediaDiagnostics.warnings.join('\n'), /已找到视频地址，但视频下载失败，仅使用页面文字生成草稿/);
  assert.match(res.body.recipe.warnings.join('\n'), /链接可提取信息较少/);
  assert.equal(aiPayloads.length, 2);
});

test('/api/recipe-import-from-url 没有视频地址时继续使用页面文字生成草稿', async () => {
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({
      status: 200,
      headers: {},
      data: '<meta property="og:description" content="页面文字：葱油拌面，面条煮熟，加入葱油拌匀。">'
    }),
    axiosPost: async (_url, payload) => {
      if (/菜谱证据抽取器/.test(payload.messages[0].content)) {
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['葱油拌面'],
                  observedMainIngredients: ['面条'],
                  observedSeasonings: ['葱油'],
                  observedActions: [
                    { order: 1, action: '面条煮熟', ingredients: ['面条'], evidenceText: '面条煮熟', confidence: 'medium' },
                    { order: 2, action: '加入葱油拌匀', ingredients: ['葱油'], evidenceText: '加入葱油拌匀', confidence: 'medium' }
                  ],
                  sourceConfidence: 'medium'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '葱油拌面',
                tags: ['AI草稿'],
                ingredients: [{ item: '面条', qty: '1', unit: '份' }],
                seasonings: [{ item: '葱油', qty: '1', unit: '勺' }],
                method: ['面条煮熟。', '加入葱油拌匀。']
              })
            }
          }]
        }
      };
    }
  });

  const res = await runPost(app, '/api/recipe-import-from-url', { url: 'http://xhslink.com/o/no-video' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.mediaDiagnostics.hasVideo, false);
  assert.equal(res.body.mediaDiagnostics.videoUrlCount, 0);
  assert.equal(res.body.recipe.name, '葱油拌面');
});

test('/api/ai-parse 会过滤评论和社交噪声后再抽取 evidence', async () => {
  const capturedPayloads = [];
  const { app } = loadServerWithMocks({
    axiosPost: async (_url, payload) => {
      capturedPayloads.push(payload);
      if (capturedPayloads.length === 1) {
        return {
          data: {
            choices: [{
              message: {
                content: JSON.stringify({
                  dishNameCandidates: ['藤椒鸡腿'],
                  observedMainIngredients: ['鸡腿'],
                  observedSeasonings: [],
                  observedAromatics: ['藤椒'],
                  observedLiquids: [],
                  observedActions: [],
                  observedTimes: [],
                  observedTools: [],
                  uncertainItems: [],
                  missingInfo: ['可提取菜谱正文较少'],
                  sourceConfidence: 'low'
                })
              }
            }]
          }
        };
      }
      return {
        data: {
          choices: [{
            message: {
              content: JSON.stringify({
                name: '藤椒鸡腿',
                ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
                seasonings: [{ item: '藤椒', qty: '1', unit: '把' }],
                method: ['根据已识别内容整理为草稿']
              })
            }
          }]
        }
      };
    }
  });
  const socialText = [
    '🔥 家常版藤椒鸡腿详细版教程……',
    '藤椒鸡腿一道看起来就很好吃的菜，从前期处理的细节，精确到克的腌制比例，到在家怎么丝滑是运用铁锅，都一一道来',
    '#家常菜 #鸡腿 #藤椒鸡腿',
    '藤椒鸡腿一道看起来就很好吃的菜 #家常菜 #鸡腿 #藤椒鸡腿',
    '段老师这题我会',
    '黄金薯R',
    '双椒鸡拌面',
    '腌的时候放一丢丢小苏打',
    '视频号为啥不要了',
    '一次性解决所有铁锅粘锅问题'
  ].join('\n');

  const res = await runPost(app, '/api/ai-parse', {
    text: socialText,
    sourceType: 'xiaohongshu',
    sourceMetadata: {
      url: 'http://xhslink.com/o/example',
      finalUrl: 'https://www.xiaohongshu.com/explore/example',
      extractionMode: 'link-only',
      hasHtml: true,
      hasStructuredMeta: true,
      trustedTextLength: socialText.length,
      trustedTextPreview: socialText.slice(0, 80),
      rawTextLength: socialText.length + 20,
      rawTextPreview: `${socialText} raw tail`,
      warnings: ['当前链接只能解析到部分页面文字，平台可能限制了视频内容读取，菜谱可能需要人工确认。']
    }
  });

  assert.equal(res.statusCode, 200);
  assert.equal(capturedPayloads.length, 1);
  const evidencePrompt = capturedPayloads[0].messages[1].content;
  assert.match(evidencePrompt, /家常版藤椒鸡腿详细版教程/);
  assert.match(evidencePrompt, /腌制比例/);
  assert.match(evidencePrompt, /铁锅/);
  assert.doesNotMatch(evidencePrompt, /小苏打|段老师|视频号|双椒鸡拌面|黄金薯/);
  assert.doesNotMatch(JSON.stringify(res.body.recipe), /小苏打/);
  assert.deepEqual(res.body.recipe.method, []);
  assert.match(res.body.diagnostics.rawTextPreview, /小苏打/);
  assert.equal(res.body.diagnostics.extractionMode, 'link-only');
  assert.equal(res.body.diagnostics.finalUrl, 'https://www.xiaohongshu.com/explore/example');
  assert.match(res.body.diagnostics.trustedTextPreview, /家常版藤椒鸡腿/);
  assert.match(res.body.diagnostics.authorCandidateTextPreview, /家常版藤椒鸡腿详细版教程/);
  assert.doesNotMatch(res.body.diagnostics.cleanedTextPreview, /小苏打/);
  assert.match(res.body.diagnostics.excludedSocialTextPreview, /小苏打/);
  assert.ok(Array.isArray(res.body.diagnostics.sourceSegmentsPreview));
  assert.ok(res.body.diagnostics.sourceSegmentsPreview.some(seg => seg.type === 'authorCandidate'));
  assert.match(res.body.recipe.warnings.join('\n'), /链接可提取信息较少/);
});

test('后端上游错误响应保留 status/code，并且不泄露 API Key', async () => {
  const { app } = loadServerWithMocks({
    axiosPost: async () => {
      const err = new Error('request failed');
      err.response = {
        status: 404,
        data: {
          error: {
            code: 'model_not_found',
            message: 'bad model for test-key'
          }
        }
      };
      throw err;
    }
  });

  const res = await runPost(app, '/api/ai-chat', {
    prompt: '识别小票',
    imageBase64: 'data:image/jpeg;base64,abcd',
    taskType: 'receipt'
  });

  assert.equal(res.statusCode, 404);
  assert.equal(res.body.status, 404);
  assert.equal(res.body.code, 'model_not_found');
  assert.equal(res.body.upstreamStatus, 404);
  assert.equal(res.body.upstreamCode, 'model_not_found');
  assert.doesNotMatch(JSON.stringify(res.body), /test-key/);
});
