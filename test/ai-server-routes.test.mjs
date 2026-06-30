import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const Module = require('node:module');
const originalLoad = Module._load;
const root = process.cwd();
const serverPath = resolve(root, 'server.js');
const originalEnv = { ...process.env };

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

function loadServerWithMocks({ axiosPost, axiosGet, dnsLookup, env = {} } = {}) {
  const expressMock = createExpressMock();
  const axiosMock = {
    post: axiosPost || (async () => ({ data: { choices: [{ message: { content: 'ok' } }] } })),
    get: axiosGet || (async () => ({ status: 200, headers: {}, data: '' }))
  };
  Module._load = function mockedLoad(request, parent, isMain) {
    if (request === 'express') return expressMock;
    if (request === 'axios') return axiosMock;
    if (request === 'dns' && dnsLookup) return { promises: { lookup: dnsLookup } };
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
  assert.equal(capturedPayloads[1].model, 'openai/gpt-oss-120b');
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
  assert.equal(res.body.extractionMode, 'link-only');
  assert.equal(res.body.hasStructuredMeta, true);
  assert.equal(res.body.hasOgDescription, true);
  assert.match(res.body.text, /藤椒鸡腿详细版教程/);
  assert.match(res.body.text, /鸡腿洗净擦干/);
  assert.doesNotMatch(res.body.text, /小苏打|双椒鸡拌面|视频号为啥不要了|段老师/);
  assert.match(res.body.rawTextPreview, /小苏打/);
});

test('/api/xhs-extract 可以从 JSON-LD 提取 name 和 description', async () => {
  const html = `<!doctype html><html><head>
    <script type="application/ld+json">{"@type":"Recipe","name":"鲜藤椒鸡腿","description":"鸡腿加入鲜藤椒和生抽调味后出锅。"}</script>
  </head><body>评论：太喜欢这道菜了</body></html>`;
  const { app } = loadServerWithMocks({
    dnsLookup: async () => [{ address: '93.184.216.34', family: 4 }],
    axiosGet: async () => ({ status: 200, headers: {}, data: html })
  });

  const res = await runGet(app, '/api/xhs-extract', { url: 'https://example.com/jsonld' });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.hasJsonLd, true);
  assert.match(res.body.text, /鲜藤椒鸡腿/);
  assert.match(res.body.text, /加入鲜藤椒和生抽调味后出锅/);
  assert.doesNotMatch(res.body.text, /太喜欢/);
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
  assert.match(res.body.text, /家常版藤椒鸡腿详细版教程/);
  assert.match(res.body.text, /腌制比例/);
  assert.doesNotMatch(res.body.text, /段老师|小苏打|双椒鸡拌面|视频号为啥不要了/);
  assert.match(res.body.rawTextPreview, /小苏打/);
  assert.ok(res.body.sourceSegmentsPreview.some(seg => seg.type === 'authorCandidate'));
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
