import test, { afterEach, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  callAiSearchRecipe,
  formatAiErrorMessage,
  getAiConfig
} from '../src/ai.js';
import { S } from '../src/storage.js';

const root = process.cwd();
const oldLocalStorage = global.localStorage;
const oldFetch = global.fetch;

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

function createStorage() {
  const data = new Map();
  return {
    getItem(key) {
      return data.has(key) ? data.get(key) : null;
    },
    setItem(key, value) {
      data.set(key, String(value));
    },
    removeItem(key) {
      data.delete(key);
    },
    clear() {
      data.clear();
    }
  };
}

function recipeContent(name = '番茄炒蛋') {
  return JSON.stringify({
    name,
    ingredients: [{ item: '鸡蛋', qty: '', unit: '' }],
    method: '1. 鸡蛋打散\n2. 下锅炒熟'
  });
}

beforeEach(() => {
  global.localStorage = createStorage();
});

afterEach(() => {
  global.fetch = oldFetch;
  global.localStorage = oldLocalStorage;
});

test('默认 AI 配置使用 cloud 模式，不需要本地 API Key', () => {
  const conf = getAiConfig();
  assert.equal(conf.mode, 'cloud');
  assert.equal(conf.apiUrl, '/api/ai-chat');
  assert.equal(conf.apiKey, undefined);
});

test('cloud 模式调用同源 /api/ai-chat，并带 taskType', async () => {
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, options, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({ content: recipeContent() })
    };
  };

  const out = await callAiSearchRecipe('番茄炒蛋', '鸡蛋、番茄');
  assert.equal(out.name, '番茄炒蛋');
  assert.equal(request.url, '/api/ai-chat');
  assert.equal(request.options.headers.Authorization, undefined);
  assert.equal(request.body.taskType, 'recipe-search');
  assert.match(request.body.prompt, /番茄炒蛋/);
});

test('BYOK 模式继续使用用户配置的 apiUrl / apiKey / model', async () => {
  S.save(S.keys.settings, {
    aiProviderMode: 'byok',
    apiUrl: 'https://example.test/v1/chat/completions',
    apiKey: 'user-test-key',
    model: 'user-model'
  });
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, options, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({ choices: [{ message: { content: recipeContent('咖喱鸡') } }] })
    };
  };

  const out = await callAiSearchRecipe('咖喱鸡', '鸡肉、土豆');
  assert.equal(out.name, '咖喱鸡');
  assert.equal(request.url, 'https://example.test/v1/chat/completions');
  assert.equal(request.options.headers.Authorization, 'Bearer user-test-key');
  assert.equal(request.body.model, 'user-model');
});

test('BYOK 缺少 API Key 时给出原有友好错误', async () => {
  S.save(S.keys.settings, { aiProviderMode: 'byok', apiKey: '' });

  await assert.rejects(
    () => callAiSearchRecipe('番茄炒蛋', '鸡蛋、番茄'),
    /还没有配置 API Key/
  );
  assert.equal(
    formatAiErrorMessage(new Error('AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。')),
    'AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。'
  );
});

test('设置页默认展示内置 AI 服务，并只在 BYOK 区域展示高级字段', () => {
  const settings = read('src/views/settings-view.js');

  assert.match(settings, /使用内置 AI 服务（推荐）/);
  assert.match(settings, /使用自己的 API Key（高级）/);
  assert.match(settings, /const aiProviderMode = s\.aiProviderMode === 'byok' \? 'byok' : 'cloud';/);
  assert.match(settings, /id="cloudAiBox"/);
  assert.match(settings, /id="byokAiBox"/);
  assert.match(settings, /byokAiBox\.hidden = !isByok;/);
  assert.match(settings, /aiProviderMode: 'byok'/);
});

test('后端 AI 代理不暴露密钥，并包含长度限制与限流', () => {
  const server = read('server.js');
  const aiChatRoute = server.slice(
    server.indexOf("app.post('/api/ai-chat'"),
    server.indexOf('// AI 解析路由')
  );

  assert.match(server, /app\.post\('\/api\/ai-chat'/);
  assert.match(server, /OPENAI_API_KEY/);
  assert.match(server, /OPENAI_VISION_MODEL/);
  assert.match(server, /AI_PROMPT_MAX_CHARS = 12000/);
  assert.match(server, /AI_IMAGE_MAX_BYTES = 8 \* 1024 \* 1024/);
  assert.match(server, /AI_RATE_LIMIT_MAX = 30/);
  assert.match(server, /x-forwarded-for/);
  assert.match(server, /res\.json\(\{ content \}\)/);
  assert.doesNotMatch(aiChatRoute, /OPENAI_API_KEY[^\n]*res\.json|res\.json\([^)]*OPENAI_API_KEY/);
  assert.doesNotMatch(aiChatRoute, /err\.response\.data/);
});
