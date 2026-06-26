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

function loadServerWithMocks({ axiosPost, env = {} } = {}) {
  const expressMock = createExpressMock();
  const axiosMock = { post: axiosPost || (async () => ({ data: { choices: [{ message: { content: 'ok' } }] } })) };
  Module._load = function mockedLoad(request, parent, isMain) {
    if (request === 'express') return expressMock;
    if (request === 'axios') return axiosMock;
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

async function runGet(app, path) {
  const route = app.routes.find(item => item.method === 'GET' && item.path === path);
  assert.ok(route, `${path} route should be registered`);
  const req = { headers: {}, ip: '127.0.0.1', socket: { remoteAddress: '127.0.0.1' } };
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
  let capturedPayload = null;
  const { app } = loadServerWithMocks({
    axiosPost: async (_url, payload) => {
      capturedPayload = payload;
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
  assert.equal(capturedPayload.model, 'meta-llama/llama-4-scout-17b-16e-instruct');
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
